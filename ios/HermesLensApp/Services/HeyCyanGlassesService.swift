import CoreBluetooth
import Foundation
import HermesLensCore
import Observation

/// HeyCyan camera glasses (AM01 family: L802, M01) over Bluetooth LE, beta.
///
/// The glasses do not advertise their services, so a scan lists every named device (`M01…`,
/// `L 802…` names first) and the user picks one. Once connected, the app subscribes to the
/// big-data channel and can only send the allowlisted `HeyCyanCommand`s: take a photo (it is
/// stored on the glasses) and count the media on the glasses.
///
/// Foreground only: nothing here scans or reconnects in the background, and there is no state
/// restoration. The app reconnects to the remembered glasses when it becomes active.
///
/// Privacy: trace lines carry states, commands and counts only. Device names, identifiers,
/// addresses, audio frames and photo bytes are never logged.
@MainActor
@Observable
final class HeyCyanGlassesService: NSObject {
    enum LinkState: Equatable {
        case disconnected
        case connecting
        case connected
        /// Bluetooth is off, not allowed for Luna, or missing.
        case unavailable(String)

        var displayName: String {
            switch self {
            case .disconnected: "Not connected"
            case .connecting: "Connecting"
            case .connected: "Connected"
            case .unavailable(let reason): reason
            }
        }
    }

    /// A named Bluetooth device seen in the last scan.
    struct FoundDevice: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
        /// The name looks like HeyCyan glasses (`HeyCyanDeviceName`).
        var likely: Bool
    }

    struct PhotoResult: Equatable {
        var before: HeyCyanMediaCount
        var after: HeyCyanMediaCount
        /// The photo count on the glasses went up.
        var confirmed: Bool { after.photos > before.photos }
    }

    private(set) var state: LinkState = .disconnected
    private(set) var isScanning = false
    private(set) var found: [FoundDevice] = []
    /// Percent, as the glasses last reported it (they send it every so often, not on request).
    private(set) var batteryPercent: Int?
    private(set) var connectedID: UUID?
    private(set) var connectedName: String?
    private(set) var isTakingPhoto = false
    private(set) var lastMediaCount: HeyCyanMediaCount?

    static let scanSeconds: Double = 15
    static let connectTimeout: Duration = .seconds(15)
    static let replyTimeout: Duration = .seconds(3)
    private static let maximumListed = 30

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var seen: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeCharacteristic: CBCharacteristic?
    @ObservationIgnored private var parser = HeyCyanFrameParser()
    @ObservationIgnored private var scanStop: Task<Void, Never>?
    @ObservationIgnored private var connectWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var connectDeadline: Task<Void, Never>?
    @ObservationIgnored private var countWaiters: [UUID: CheckedContinuation<HeyCyanMediaCount, Error>] = [:]
    @ObservationIgnored private var buttonListeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    @ObservationIgnored private var audioFrames = 0
    @ObservationIgnored private var buttonFilter = HeyCyanAssistantButtonFilter()

    private let serviceUUID = CBUUID(string: HeyCyanUUID.bigDataService)
    private let notifyUUID = CBUUID(string: HeyCyanUUID.bigDataNotify)
    private let writeUUID = CBUUID(string: HeyCyanUUID.bigDataWrite)

    var isConnected: Bool { state == .connected }

    // MARK: Scan

    /// Lists named nearby devices for `seconds`, then stops. The first scan asks for Bluetooth
    /// permission.
    func scan(seconds: Double = HeyCyanGlassesService.scanSeconds) async {
        stopScan()
        found.removeAll()
        do { try await waitForPowerOn() } catch { return }
        guard let central else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        trace("heycyan.scan", "started")
        scanStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.stopScan()
        }
    }

    func stopScan() {
        scanStop?.cancel()
        scanStop = nil
        guard isScanning else { return }
        central?.stopScan()
        isScanning = false
        trace("heycyan.scan", "stopped found=\(found.count) likely=\(found.filter(\.likely).count)")
    }

    // MARK: Connect

    /// Connects to the glasses with this identifier (from a scan, or remembered from an earlier
    /// connection) and subscribes to their big-data channel.
    func connect(to id: UUID) async throws {
        if state == .connected, connectedID == id { return }
        if state == .connecting { throw HeyCyanError.busy }
        stopScan()
        dropLink()
        state = .connecting  // set before the first wait, so a second connect is refused as busy
        do {
            try await waitForPowerOn()
        } catch {
            if state == .connecting { state = .disconnected }
            throw error
        }
        guard let central,
              let target = seen[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            state = .disconnected
            throw HeyCyanError.unknownGlasses
        }
        seen[id] = target
        peripheral = target
        target.delegate = self
        trace("heycyan.connect", "started")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectWaiter = continuation
            central.connect(target)
            connectDeadline = Task { [weak self] in
                try? await Task.sleep(for: Self.connectTimeout)
                guard !Task.isCancelled else { return }
                self?.failConnect(.timedOut)
            }
        }
        connectedID = id
        connectedName = target.name ?? found.first { $0.id == id }?.name
    }

    /// Back in the foreground: reconnects to the remembered glasses, quietly.
    func reconnect(to id: UUID?) {
        guard let id, state == .disconnected, CBManager.authorization == .allowedAlways else { return }
        Task { try? await connect(to: id) }
    }

    func disconnect() {
        stopScan()
        dropLink()
        trace("heycyan.connect", "closed")
    }

    // MARK: Commands

    /// How many photos, videos and recordings are on the glasses.
    func mediaCount() async throws -> HeyCyanMediaCount {
        let id = UUID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HeyCyanMediaCount, Error>) in
            do { try send(.mediaCount) } catch { continuation.resume(throwing: error); return }
            countWaiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: Self.replyTimeout)
                self?.countWaiters.removeValue(forKey: id)?.resume(throwing: HeyCyanError.timedOut)
            }
        }
    }

    /// Takes one photo on the glasses and confirms it the way the Mac test tool did: the photo
    /// count before, the command, then the count again until it goes up (about 3 to 9 s).
    /// The photo stays on the glasses; bringing it to the phone is a later step.
    func takePhoto() async throws -> PhotoResult {
        guard !isTakingPhoto else { throw HeyCyanError.busy }
        isTakingPhoto = true
        defer { isTakingPhoto = false }
        let before = try await mediaCount()
        try send(.takePhoto)
        try await Task.sleep(for: .seconds(3))
        var after = before
        for attempt in 1...4 {
            if let count = try? await mediaCount() {
                after = count
                if count.photos > before.photos { break }
            }
            if attempt < 4 { try await Task.sleep(for: .milliseconds(1500)) }
        }
        let result = PhotoResult(before: before, after: after)
        trace("heycyan.photo", "confirmed=\(result.confirmed) photos_before=\(before.photos) photos_after=\(after.photos)")
        return result
    }

    /// One element for every press of the assistant button (the glasses report "mic started"),
    /// for as long as the caller iterates. A mic start within 10 s of the app's own photo
    /// command is left out (`HeyCyanAssistantButtonFilter`).
    func assistantButtonPresses() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        buttonListeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.buttonListeners[id] = nil }
        }
        return stream
    }

    // MARK: Internals

    private func send(_ command: HeyCyanCommand) throws {
        guard state == .connected, let peripheral, let writeCharacteristic else { throw HeyCyanError.notConnected }
        let type: CBCharacteristicWriteType = writeCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        if command == .takePhoto { buttonFilter.photoCommandSent(at: .now) }
        peripheral.writeValue(Data(command.bytes), for: writeCharacteristic, type: type)
        trace("heycyan.send", command.label)
    }

    private func ensureCentral() -> CBCentralManager {
        if let central { return central }
        // Main queue: every delegate callback arrives on the main actor.
        let made = CBCentralManager(delegate: self, queue: nil)
        central = made
        return made
    }

    /// Waits for Bluetooth to be ready (the first time includes the permission prompt).
    private func waitForPowerOn() async throws {
        let central = ensureCentral()
        var waited = 0
        while central.state == .unknown || central.state == .resetting, waited < 600 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard central.state == .poweredOn else {
            let reason = Self.unavailableReason(central.state)
            state = .unavailable(reason)
            throw HeyCyanError.bluetoothUnavailable(reason)
        }
        if case .unavailable = state { state = .disconnected }
    }

    private static func unavailableReason(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth not allowed for Luna"
        case .unsupported: "Bluetooth not available"
        default: "Bluetooth not ready"
        }
    }

    private func failConnect(_ error: HeyCyanError) {
        guard let waiter = connectWaiter else { return }
        connectWaiter = nil
        trace("heycyan.connect", "failed reason=\(error.traceLabel)")
        dropLink()
        waiter.resume(throwing: error)
    }

    private func finishConnect() {
        connectDeadline?.cancel()
        connectDeadline = nil
        state = .connected
        trace("heycyan.connect", "ok")
        connectWaiter?.resume()
        connectWaiter = nil
    }

    /// Closes the link (if any) and clears everything learned over it.
    private func dropLink() {
        connectDeadline?.cancel()
        connectDeadline = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral?.delegate = nil
        peripheral = nil
        writeCharacteristic = nil
        parser.reset()
        if case .unavailable = state {} else { state = .disconnected }
        connectedID = nil
        connectedName = nil
        batteryPercent = nil
        let waiters = countWaiters
        countWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(throwing: HeyCyanError.notConnected) }
        connectWaiter?.resume(throwing: HeyCyanError.notConnected)
        connectWaiter = nil
    }

    private func handle(_ event: HeyCyanEvent) {
        switch event {
        case .battery(let percent):
            if batteryPercent.map({ $0 / 10 }) != percent / 10 { trace("heycyan.battery", "level=\(percent / 10 * 10)") }
            batteryPercent = percent
        case .micStarted:
            audioFrames = 0
            // A photo also starts the glasses' own listening (seen on the M01): not a button press.
            let pressed = buttonFilter.isButtonPress(micStartedAt: .now)
            trace("heycyan.event", "mic_started button=\(pressed) listeners=\(buttonListeners.count)")
            if pressed { for listener in buttonListeners.values { listener.yield() } }
        case .micStopped:
            trace("heycyan.event", "mic_stopped audio_frames=\(audioFrames)")
        case .micAudio:
            audioFrames += 1  // the content is ignored in this version
        case .mediaCount(let count):
            lastMediaCount = count
            let waiters = countWaiters
            countWaiters.removeAll()
            for waiter in waiters.values { waiter.resume(returning: count) }
        case .photoReply:
            trace("heycyan.event", "photo_reply")
        case .volume, .state, .otherEvent, .controlReply, .unknown:
            break
        }
    }

    private func trace(_ event: String, _ detail: String) {
        VoiceDiagnosticLog.record(event, detail)
    }
}

extension HeyCyanGlassesService: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        trace("heycyan.bluetooth", "state=\(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            if case .unavailable = state { state = .disconnected }
        case .unknown, .resetting:
            break
        default:
            // Bluetooth went off or was refused: every link is gone without a disconnect callback.
            isScanning = false
            scanStop?.cancel()
            failConnect(.bluetoothUnavailable(Self.unavailableReason(central.state)))
            dropLink()
            state = .unavailable(Self.unavailableReason(central.state))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = (advertised ?? peripheral.name)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return  // unnamed beacons and phones
        }
        seen[peripheral.identifier] = peripheral
        let rssi = RSSI.intValue == 127 ? -127 : RSSI.intValue
        let device = FoundDevice(id: peripheral.identifier, name: name, rssi: rssi,
                                 likely: HeyCyanDeviceName.looksLikeHeyCyan(name))
        if let index = found.firstIndex(where: { $0.id == device.id }) {
            found[index] = device
        } else if found.count < Self.maximumListed || device.likely {
            found.append(device)
        }
        found.sort { ($0.likely ? 1 : 0, $0.rssi) > ($1.likely ? 1 : 0, $1.rssi) }
        if found.count > Self.maximumListed { found.removeLast(found.count - Self.maximumListed) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        failConnect(.connectFailed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        if connectWaiter != nil {
            failConnect(.connectFailed)
        } else {
            trace("heycyan.connect", "lost")
            dropLink()
        }
    }
}

extension HeyCyanGlassesService: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            failConnect(.notHeyCyan)
            return
        }
        peripheral.discoverCharacteristics([notifyUUID, writeUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == self.peripheral else { return }
        let characteristics = service.characteristics ?? []
        guard error == nil,
              let notify = characteristics.first(where: { $0.uuid == notifyUUID }),
              let write = characteristics.first(where: { $0.uuid == writeUUID }) else {
            failConnect(.notHeyCyan)
            return
        }
        writeCharacteristic = write
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == notifyUUID, connectWaiter != nil else { return }
        if error == nil, characteristic.isNotifying {
            finishConnect()
        } else {
            failConnect(.connectFailed)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == notifyUUID, error == nil,
              let value = characteristic.value else { return }
        for frame in parser.push(value) { handle(HeyCyanEvent(frame)) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil { trace("heycyan.send", "result=failed") }
    }
}

enum HeyCyanError: Error, LocalizedError, Equatable {
    case bluetoothUnavailable(String)
    case unknownGlasses
    case connectFailed
    case notHeyCyan
    case notConnected
    case timedOut
    case busy

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let reason): "\(reason). Check Bluetooth in iPhone Settings."
        case .unknownGlasses: "Those glasses aren't nearby. Scan again and pick them from the list."
        case .connectFailed: "The glasses didn't accept the connection. Make sure they're on and not connected to another phone."
        case .notHeyCyan: "That device isn't HeyCyan glasses."
        case .notConnected: "The HeyCyan glasses aren't connected."
        case .timedOut: "The glasses didn't answer in time. Make sure they're on and close by."
        case .busy: "The glasses are busy. Try again in a moment."
        }
    }

    var traceLabel: String {
        switch self {
        case .bluetoothUnavailable: "bluetooth"
        case .unknownGlasses: "unknown"
        case .connectFailed: "connect_failed"
        case .notHeyCyan: "not_heycyan"
        case .notConnected: "not_connected"
        case .timedOut: "timeout"
        case .busy: "busy"
        }
    }
}
