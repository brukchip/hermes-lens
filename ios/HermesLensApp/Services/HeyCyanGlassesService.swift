import CoreBluetooth
import Foundation
import HermesLensCore
import Observation
import UIKit

/// HeyCyan camera glasses (AM01 family: L802, M01) over Bluetooth LE, beta.
///
/// The glasses do not advertise their services, so a scan lists every named device (`M01…`,
/// `L 802…` names first) and the user picks one. Once connected, the app subscribes to the
/// big-data channel and can only send the allowlisted `HeyCyanCommand`s: take a photo (it is
/// stored on the glasses), take an "AI photo" and pull its small JPEG over Bluetooth
/// (`captureAIPhoto`, a call's look), count the media on the glasses, ask for the battery
/// level, and open and close the glasses' own Wi-Fi for one photo download
/// (`HeyCyanPhotoTransfer`).
///
/// Foreground only: nothing here scans or reconnects in the background, and there is no state
/// restoration. The app reconnects to the remembered glasses when it becomes active.
///
/// Privacy: trace lines carry states, commands and counts only. Device names, identifiers,
/// Bluetooth addresses, Wi-Fi names and passwords, audio frames and photo bytes are never
/// logged. The glasses' private Wi-Fi IP address during a transfer is logged.
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
    /// Percent, from the battery request (on connect, then every minute in the foreground) or
    /// the glasses' own occasional report. Nil when the glasses did not answer and the last
    /// value is too old to show.
    private(set) var batteryPercent: Int?
    /// Whether the glasses are charging, when the battery request answered.
    private(set) var batteryCharging: Bool?
    private(set) var connectedID: UUID?
    private(set) var connectedName: String?
    private(set) var isTakingPhoto = false
    private(set) var lastMediaCount: HeyCyanMediaCount?

    static let scanSeconds: Double = 15
    static let connectTimeout: Duration = .seconds(15)
    static let replyTimeout: Duration = .seconds(3)
    static let batteryPollInterval: Duration = .seconds(60)
    static let batteryReplyTimeout: Duration = .seconds(5)
    /// A battery value older than this is not shown when a request goes unanswered.
    static let batteryStaleSeconds: TimeInterval = 90
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
    /// After a mic start that followed the app's own photo command: traces when no mic stop
    /// comes within `micStopWait` (the M01 listens by itself after a photo).
    @ObservationIgnored private var micStopWatch: Task<Void, Never>?
    @ObservationIgnored private var batteryPoll: Task<Void, Never>?
    @ObservationIgnored private var batteryUpdatedAt: Date?
    @ObservationIgnored private var batteryRequestedAt: Date?
    @ObservationIgnored private var batteryReplyTraced = false
    @ObservationIgnored private var batteryNoReplyTraced = false
    @ObservationIgnored private var credentialWaiters: [UUID: CheckedContinuation<HeyCyanWiFiCredentials, Error>] = [:]
    @ObservationIgnored private var addressWaiters: [UUID: CheckedContinuation<String?, Never>] = [:]
    /// The Wi-Fi address the glasses reported since the last `enterTransferMode` (event 0x73/08).
    @ObservationIgnored private(set) var reportedWiFiAddress: String?
    /// When `reportedWiFiAddress` arrived (for the `stage=wifi_ip` trace).
    @ObservationIgnored private(set) var reportedWiFiAddressAt: ContinuousClock.Instant?
    /// The AI photo being pulled (`captureAIPhoto`), and the one wait on it.
    @ObservationIgnored private var aiPhoto: AIPhotoPull?
    @ObservationIgnored private var aiPhotoWaiter: (id: UUID, continuation: CheckedContinuation<Void, Never>)?
    @ObservationIgnored private var aiPhotoWoken = false

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

    /// Back in the foreground: reconnects to the remembered glasses, quietly, or refreshes the
    /// battery when they are still connected.
    func reconnect(to id: UUID?) {
        if isConnected {
            if batteryRequestedAt.map({ Date.now.timeIntervalSince($0) >= 60 }) ?? true {
                Task { await refreshBattery() }
            }
            return
        }
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
    /// The photo is stored on the glasses; `HeyCyanPhotoTransfer` brings it to the phone.
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

    /// Asks the glasses for their battery level (only while connected and Luna is on screen).
    /// The reply arrives as a 0x42 frame; with no answer within `batteryReplyTimeout`, a value
    /// older than `batteryStaleSeconds` is cleared rather than shown stale.
    func refreshBattery() async {
        guard isConnected, UIApplication.shared.applicationState == .active else { return }
        let asked = Date.now
        batteryRequestedAt = asked
        do { try send(.batteryLevel) } catch { return }
        try? await Task.sleep(for: Self.batteryReplyTimeout)
        guard !Task.isCancelled, isConnected else { return }
        if let updated = batteryUpdatedAt, updated >= asked { return }
        if !batteryNoReplyTraced {
            batteryNoReplyTraced = true
            trace("heycyan.battery", "result=no_reply")
        }
        if batteryUpdatedAt.map({ Date.now.timeIntervalSince($0) > Self.batteryStaleSeconds }) ?? true {
            batteryPercent = nil
            batteryCharging = nil
        }
    }

    // MARK: AI photo (a small JPEG over Bluetooth, for a call's look)

    private struct AIPhotoPull {
        var assembler = HeyCyanAIPhotoAssembler()
        /// The chunk count from the "shot done" event: one byte, only a first time budget
        /// until the first chunk brings the 16-bit total.
        var announcedChunks: Int?
    }

    /// The shot event normally comes about 2.5 s after the trigger.
    static let aiPhotoShotWait: Duration = .seconds(6)
    static let aiPhotoChunkTimeout: Duration = .seconds(3)
    static let aiPhotoChunkRetries = 3
    /// How long a mic start after the app's own photo may go without a mic stop before
    /// `heycyan.mic result=no_stop_event` is traced.
    static let micStopWait: Duration = .seconds(10)

    /// Takes an AI photo (`HeyCyanCommand.takeAIPhoto`) and pulls its JPEG chunk by chunk over
    /// Bluetooth, no Wi-Fi: about 4 s at size 2. Waits up to 6 s for the "shot done" event
    /// (without it, chunk 0 is still asked for once), then asks for each chunk with a 3 s
    /// timeout and up to 3 repeats of the same index. The whole pull may take 3 s plus 0.25 s
    /// per chunk from when the count is first known (the shot event's one-byte count, replaced
    /// by the chunk replies' 16-bit total once the first chunk is in), and never more than 20 s
    /// from the trigger. After the last chunk, bytes without a JPEG end are a failure. Shares
    /// the one-photo-at-a-time guard with `takePhoto`; cancelling the calling task stops it.
    func captureAIPhoto() async throws(HeyCyanAIPhotoFailure) -> Data {
        let clock = ContinuousClock()
        let started = clock.now
        func ms() -> Int { Int((clock.now - started) / .milliseconds(1)) }
        func failed(_ failure: HeyCyanAIPhotoFailure) -> HeyCyanAIPhotoFailure {
            let pull = aiPhoto?.assembler
            trace("heycyan.aiphoto", "stage=fail result=\(failure.traceLabel) chunks=\(pull?.received ?? 0)/"
                + "\(pull?.total.map(String.init) ?? "?") bytes=\(pull?.byteCount ?? 0) ms=\(ms())")
            return failure
        }
        guard isConnected else { throw failed(.notConnected) }
        guard !isTakingPhoto else { throw failed(.busy) }
        isTakingPhoto = true
        aiPhoto = AIPhotoPull()
        aiPhotoWoken = false
        defer {
            isTakingPhoto = false
            aiPhoto = nil
            // The glasses may start their own listening after the photo, not only after the trigger.
            buttonFilter.photoCommandSent(at: .now)
        }
        let hardDeadline = started + .seconds(HeyCyanAIPhoto.maximumSeconds)
        var deadline = hardDeadline
        /// When a chunk count was first known: the pull budget counts from here.
        var countKnownAt: ContinuousClock.Instant?
        func check() throws(HeyCyanAIPhotoFailure) {
            if Task.isCancelled { throw failed(.cancelled) }
            guard isConnected, aiPhoto != nil else { throw failed(.disconnected) }
            // The 16-bit total from the chunks wins over the shot event's one-byte count.
            if let count = aiPhoto?.assembler.total ?? aiPhoto?.announcedChunks {
                let anchor = countKnownAt ?? clock.now
                countKnownAt = anchor
                deadline = min(hardDeadline, anchor + .seconds(HeyCyanAIPhoto.pullSeconds(chunkCount: count)))
            }
            guard clock.now < deadline else { throw failed(.outOfTime) }
        }

        do { try send(.takeAIPhoto) } catch { throw failed(.notConnected) }
        trace("heycyan.aiphoto", "stage=trigger result=sent size=\(HeyCyanAIPhoto.size) ms=0")

        let shotDeadline = min(deadline, started + Self.aiPhotoShotWait)
        while aiPhoto?.announcedChunks == nil, clock.now < shotDeadline {
            await waitForAIPhoto(until: shotDeadline)
            if Task.isCancelled || !isConnected { break }
        }
        try check()
        let announced = aiPhoto?.announcedChunks
        trace("heycyan.aiphoto", "stage=shot result=\(announced == nil ? "no_event" : "ok") "
            + "chunks=0/\(announced.map(String.init) ?? "?") bytes=0 ms=\(ms())")

        var index = 0
        var repeats = 0
        func request(_ index: Int) throws(HeyCyanAIPhotoFailure) -> ContinuousClock.Instant {
            do { try send(.requestAIPhotoChunk(index: UInt16(index))) } catch { throw failed(.disconnected) }
            return min(deadline, clock.now + Self.aiPhotoChunkTimeout)
        }
        var chunkDeadline = try request(index)
        while true {
            try check()
            guard let assembler = aiPhoto?.assembler else { throw failed(.disconnected) }
            if assembler.isComplete { break }
            if assembler.received > index {
                if index == 0 {
                    trace("heycyan.aiphoto", "stage=chunk result=first chunks=1/\(assembler.total ?? 0) "
                        + "bytes=\(assembler.byteCount) ms=\(ms())")
                }
                index = assembler.received
                repeats = 0
                chunkDeadline = try request(index)
                continue
            }
            if clock.now >= chunkDeadline {
                // Without the shot event, chunk 0 is asked for once only.
                let allowed = aiPhoto?.announcedChunks != nil || index > 0 ? Self.aiPhotoChunkRetries : 0
                guard repeats < allowed else { throw failed(.noReply) }
                repeats += 1
                trace("heycyan.aiphoto", "stage=chunk result=repeat index=\(index) attempt=\(repeats + 1) "
                    + "chunks=\(assembler.received)/\(assembler.total.map(String.init) ?? "?") ms=\(ms())")
                chunkDeadline = try request(index)
                continue
            }
            await waitForAIPhoto(until: chunkDeadline)
        }

        guard let assembler = aiPhoto?.assembler, let jpeg = assembler.jpeg else { throw failed(.notAPhoto) }
        trace("heycyan.aiphoto", "stage=done result=ok chunks=\(assembler.received)/\(assembler.total ?? 0) "
            + "bytes=\(jpeg.count) ms=\(ms())")
        return jpeg
    }

    /// Returns when the AI photo pull changed (an event, a chunk, a disconnect), at
    /// `deadline`, or when the calling task is cancelled.
    private func waitForAIPhoto(until deadline: ContinuousClock.Instant) async {
        if aiPhotoWoken {
            aiPhotoWoken = false
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { continuation.resume(); return }
                aiPhotoWaiter = (id, continuation)
                Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    self?.resumeAIPhotoWaiter(id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeAIPhotoWaiter(id) }
        }
    }

    private func resumeAIPhotoWaiter(_ id: UUID) {
        guard let waiter = aiPhotoWaiter, waiter.id == id else { return }
        aiPhotoWaiter = nil
        waiter.continuation.resume()
    }

    /// The pull changed: wakes its wait, or the next one returns at once.
    private func wakeAIPhoto() {
        if let waiter = aiPhotoWaiter {
            aiPhotoWaiter = nil
            waiter.continuation.resume()
        } else {
            aiPhotoWoken = true
        }
    }

    private func handleAIPhotoChunk(_ chunk: HeyCyanAIPhotoChunk) {
        guard aiPhoto != nil else { return }  // a late reply after the pull ended
        _ = aiPhoto?.assembler.accept(chunk)
        wakeAIPhoto()
    }

    // MARK: Transfer mode (the glasses' own Wi-Fi, for one photo download)

    /// Asks the glasses to open their Wi-Fi and returns its name and password. Throws
    /// `timedOut` when no reply comes, `transferRefused` when the reply has no credentials.
    func enterTransferMode(timeout: Duration) async throws -> HeyCyanWiFiCredentials {
        reportedWiFiAddress = nil
        reportedWiFiAddressAt = nil
        let id = UUID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HeyCyanWiFiCredentials, Error>) in
            do { try send(.enterTransferMode) } catch { continuation.resume(throwing: error); return }
            credentialWaiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.credentialWaiters.removeValue(forKey: id)?.resume(throwing: HeyCyanError.timedOut)
            }
        }
    }

    /// Closes the glasses' Wi-Fi. Never throws: it runs on every path after a transfer attempt.
    func exitTransferMode() {
        do { try send(.exitTransferMode) } catch { trace("heycyan.transfer", "event=exit_not_sent reason=not_connected") }
    }

    /// The glasses' Wi-Fi address, once they report it, or nil after `timeout`.
    func waitForWiFiAddress(timeout: Duration) async -> String? {
        if let reportedWiFiAddress { return reportedWiFiAddress }
        guard isConnected else { return nil }
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            addressWaiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.addressWaiters.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    /// Right after connecting, then every `batteryPollInterval` while connected.
    private func startBatteryPoll() {
        batteryPoll?.cancel()
        batteryReplyTraced = false
        batteryNoReplyTraced = false
        batteryPoll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshBattery()
                try? await Task.sleep(for: Self.batteryPollInterval)
            }
        }
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
        let properties = writeCharacteristic.properties
        let type: CBCharacteristicWriteType
        if case .requestAIPhotoChunk = command, properties.contains(.writeWithoutResponse) {
            type = .withoutResponse  // as on the Mac test tool
        } else {
            type = properties.contains(.write) ? .withResponse : .withoutResponse
        }
        if command == .takePhoto || command == .takeAIPhoto { buttonFilter.photoCommandSent(at: .now) }
        peripheral.writeValue(Data(command.bytes), for: writeCharacteristic, type: type)
        // The minute-by-minute battery request is traced by its result, chunk requests by
        // `heycyan.aiphoto`.
        switch command {
        case .batteryLevel, .requestAIPhotoChunk: break
        default: trace("heycyan.send", command.label)
        }
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
        startBatteryPoll()
    }

    /// Closes the link (if any) and clears everything learned over it.
    private func dropLink() {
        connectDeadline?.cancel()
        connectDeadline = nil
        batteryPoll?.cancel()
        batteryPoll = nil
        micStopWatch?.cancel()
        micStopWatch = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral?.delegate = nil
        peripheral = nil
        writeCharacteristic = nil
        parser.reset()
        if case .unavailable = state {} else { state = .disconnected }
        connectedID = nil
        connectedName = nil
        batteryPercent = nil
        batteryCharging = nil
        batteryUpdatedAt = nil
        batteryRequestedAt = nil
        let waiters = countWaiters
        countWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(throwing: HeyCyanError.notConnected) }
        let credentials = credentialWaiters
        credentialWaiters.removeAll()
        for waiter in credentials.values { waiter.resume(throwing: HeyCyanError.notConnected) }
        let addresses = addressWaiters
        addressWaiters.removeAll()
        for waiter in addresses.values { waiter.resume(returning: nil) }
        reportedWiFiAddress = nil
        wakeAIPhoto()
        connectWaiter?.resume(throwing: HeyCyanError.notConnected)
        connectWaiter = nil
    }

    private func handle(_ event: HeyCyanEvent) {
        switch event {
        case .battery(let percent):
            if batteryPercent.map({ $0 / 10 }) != percent / 10 { trace("heycyan.battery", "level=\(percent / 10 * 10)") }
            batteryPercent = percent
            batteryUpdatedAt = .now
        case .batteryReply(let percent, let charging):
            // Glasses at 0 % cannot answer: a zero that is not charging is not a real level.
            guard percent > 0 || charging else {
                trace("heycyan.battery", "result=zero_ignored")
                return
            }
            if !batteryReplyTraced {
                batteryReplyTraced = true
                trace("heycyan.battery", "result=ok source=request")
            }
            if batteryPercent.map({ $0 / 10 }) != percent / 10 { trace("heycyan.battery", "level=\(percent / 10 * 10)") }
            batteryPercent = percent
            batteryCharging = charging
            batteryUpdatedAt = .now
        case .micStarted:
            audioFrames = 0
            // A photo also starts the glasses' own listening (seen on the M01): not a button press.
            let pressed = buttonFilter.isButtonPress(micStartedAt: .now)
            trace("heycyan.event", "mic_started button=\(pressed) listeners=\(buttonListeners.count)")
            if pressed { for listener in buttonListeners.values { listener.yield() } }
            micStopWatch?.cancel()
            micStopWatch = pressed ? nil : Task { [weak self] in
                // Counts only: audio bytes are never kept or logged.
                try? await Task.sleep(for: Self.micStopWait)
                guard !Task.isCancelled, let self else { return }
                self.micStopWatch = nil
                self.trace("heycyan.mic", "result=no_stop_event audio_frames=\(self.audioFrames)")
            }
        case .micStopped:
            micStopWatch?.cancel()
            micStopWatch = nil
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
        case .aiPhotoReply:
            trace("heycyan.event", "ai_photo_reply")
        case .aiPhotoReady(let chunkCount):
            trace("heycyan.event", "ai_photo_ready chunks=\(chunkCount) pulling=\(aiPhoto != nil)")
            guard aiPhoto != nil else { return }
            aiPhoto?.announcedChunks = chunkCount
            wakeAIPhoto()
        case .transferCredentials(let credentials):
            // Never the name or password: only that they arrived.
            trace("heycyan.transfer", "event=credentials has_password=\(!credentials.password.isEmpty) waiting=\(credentialWaiters.count)")
            let waiters = credentialWaiters
            credentialWaiters.removeAll()
            for waiter in waiters.values { waiter.resume(returning: credentials) }
        case .transferModeReply(let byteCount):
            trace("heycyan.transfer", "event=mode_reply_without_credentials bytes=\(byteCount)")
            let waiters = credentialWaiters
            credentialWaiters.removeAll()
            for waiter in waiters.values { waiter.resume(throwing: HeyCyanError.transferRefused) }
        case .exitTransferReply:
            trace("heycyan.transfer", "event=exit_reply")
        case .wifiAddress(let address):
            trace("heycyan.transfer", "event=wifi_address ip=\(address)")
            reportedWiFiAddress = address
            reportedWiFiAddressAt = .now
            let waiters = addressWaiters
            addressWaiters.removeAll()
            for waiter in waiters.values { waiter.resume(returning: address) }
        case .wifiError(let code):
            trace("heycyan.transfer", "event=wifi_error code=\(code)")
        case .volume, .state, .otherEvent, .controlReply, .unknown, .aiPhotoChunk:
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
        for frame in parser.push(value) {
            // Other frames (events, battery) can arrive between chunks; they go their usual way.
            if let chunk = HeyCyanAIPhotoChunk(frame) {
                handleAIPhotoChunk(chunk)
            } else {
                handle(HeyCyanEvent(frame))
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil { trace("heycyan.send", "result=failed") }
    }
}

/// Why an AI photo did not come over Bluetooth. The photo may still be saved on the glasses.
enum HeyCyanAIPhotoFailure: Error, Equatable {
    case notConnected
    /// Another photo is being taken or brought over.
    case busy
    /// A chunk went unanswered (3 s, repeated up to 3 times).
    case noReply
    case outOfTime
    /// The chunks did not make a JPEG.
    case notAPhoto
    case disconnected
    case cancelled

    var traceLabel: String {
        switch self {
        case .notConnected: "not_connected"
        case .busy: "busy"
        case .noReply: "no_reply"
        case .outOfTime: "out_of_time"
        case .notAPhoto: "not_jpeg"
        case .disconnected: "disconnected"
        case .cancelled: "cancelled"
        }
    }

    /// The fixed code a call's `look` reports (`LunaCameraError`).
    var lookCode: String {
        switch self {
        case .notConnected: "heycyan_not_connected"
        case .busy: "heycyan_busy"
        default: "heycyan_ai_photo_failed"
        }
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
    /// The glasses answered the transfer-mode request without a Wi-Fi name and password.
    case transferRefused

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let reason): "\(reason). Check Bluetooth in iPhone Settings."
        case .unknownGlasses: "Those glasses aren't nearby. Scan again and pick them from the list."
        case .connectFailed: "The glasses didn't accept the connection. Make sure they're on and not connected to another phone."
        case .notHeyCyan: "That device isn't HeyCyan glasses."
        case .notConnected: "The HeyCyan glasses aren't connected."
        case .timedOut: "The glasses didn't answer in time. Make sure they're on and close by."
        case .busy: "The glasses are busy. Try again in a moment."
        case .transferRefused: "The glasses didn't open their Wi-Fi for the photo."
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
        case .transferRefused: "transfer_refused"
        }
    }
}
