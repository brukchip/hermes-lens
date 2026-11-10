import Foundation
import OSLog

enum GlassesRegistrationState: String, Sendable {
    case unavailable
    case available
    case registering
    case registered

    var displayName: String {
        switch self {
        case .unavailable: "Unavailable"
        case .available: "Ready to register"
        case .registering: "Registration in progress"
        case .registered: "Registered"
        }
    }
}

enum GlassesConnectionState: String, Sendable {
    case unavailable
    case disconnected
    /// Registered and nearby, with no session open: Luna connects when she needs the glasses.
    case ready
    case connecting
    case connected
    case observing
    case paused
    case failed

    var displayName: String {
        switch self {
        case .unavailable: "Unavailable"
        case .disconnected: "Not connected"
        case .ready: "Ready"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .observing: "Observing"
        case .paused: "Camera paused"
        case .failed: "Needs attention"
        }
    }
}

@MainActor
protocol GlassesService: AnyObject {
    var state: GlassesConnectionState { get }
    var registrationState: GlassesRegistrationState { get }
    var isMock: Bool { get }
    var latestPreviewJPEG: Data? { get }
    /// When `latestPreviewJPEG` arrived. A stalled stream keeps an old frame forever.
    var latestPreviewAt: Date? { get }
    func register() async throws
    func handleOpenURL(_ url: URL) async throws -> Bool
    func connect() async throws
    func startObserving() async throws
    func stopObserving() async
    func captureJPEG() async throws -> Data?
    /// A standalone high-quality photo (SDK 1.0 `Camera.photo`, experimental), taken
    /// without a video stream. Nil when a stream is running (a call uses its still).
    func captureHighQualityPhoto() async throws -> Data?
    func captureShortVideo() async throws -> Data?
    /// Closes the session so the glasses are free for Meta AI and other apps.
    func disconnect() async
    /// Closes the session and asks Meta AI to remove Luna's access to the glasses.
    func unregister() async throws
    /// Calls `onChange` whenever glasses appear, disappear or change link state, until
    /// the returned task is cancelled. Observing only: it never opens a session.
    func watchDevices(_ onChange: @escaping @MainActor @Sendable () -> Void) -> Task<Void, Never>?
    /// What the glasses report about themselves (no session needed), or nil when none are known.
    var deviceInfo: GlassesDeviceInfo? { get }
    /// Opens Meta AI's software update screen for the glasses.
    func openFirmwareUpdate() async throws
    /// Opens Meta AI's update screen for Luna's part on the glasses.
    func openGlassesAppUpdate() async throws
    /// Whether Meta AI lets Luna use the glasses camera; nil when it cannot be checked.
    func cameraPermissionGranted() async -> Bool?
    /// Asks in Meta AI for camera access; true when granted.
    func requestCameraPermission() async throws -> Bool
    /// Reports the glasses' buttons and touchpad to `handler` (Meta glasses SDK 1.0,
    /// experimental) until `stopGestures`. Opens the glasses session if needed.
    func startGestures(_ handler: @escaping @MainActor @Sendable (GlassesGesture) -> Void) async throws
    func stopGestures() async
    /// Listens for "Hey Meta, start Luna" (SDK 1.0 voice invocations, experimental; switched
    /// on in Meta's Developer Center). Answers each request once, then calls `onLaunch`.
    /// Needs connected glasses but no session. Safe to call repeatedly.
    func startVoiceLaunch(_ onLaunch: @escaping @MainActor @Sendable () -> Void)
}

/// What a press on the glasses asks Luna to do. The touchpad's single tap and
/// tap-and-hold stay with the glasses (they pause and stop the camera).
enum GlassesGesture: String, Sendable {
    /// Capture button press (short or double), or the action button.
    case look
    /// Capture button held.
    case record
    /// Touchpad double tap.
    case toggleMute
}

/// What the glasses say about themselves (Meta glasses SDK 1.0 device state). Shown in
/// the app only: the name is never logged.
struct GlassesDeviceInfo: Equatable, Sendable {
    enum Heat: Equatable, Sendable { case normal, warm, hot }
    var name: String
    var model: String
    /// 0–100, when the glasses report it.
    var battery: Int?
    var isCharging: Bool
    /// nil when the glasses do not say.
    var isWorn: Bool?
    var isFolded: Bool?
    var heat: Heat

    /// Why the camera should not be used now: folded, off the face or too hot.
    /// Unknown states never block (the glasses may simply not report them).
    var cameraBlocker: String? {
        if isFolded == true { return "glasses_folded" }
        if isWorn == false { return "glasses_not_worn" }
        if heat == .hot { return "glasses_too_hot" }
        return nil
    }

    /// Structure only, for the diagnostics log: battery in 10 % steps, never the name.
    var trace: String {
        let level = battery.map { "\($0 / 10 * 10)" } ?? "none"
        return "battery=\(level) charging=\(isCharging) worn=\(isWorn.map(String.init) ?? "unknown") "
            + "folded=\(isFolded.map(String.init) ?? "unknown") heat=\(heat)"
    }
}

@MainActor
final class MockGlassesService: GlassesService {
    private(set) var state: GlassesConnectionState = .disconnected
    let registrationState: GlassesRegistrationState = .registered
    let isMock = true
    var latestPreviewJPEG: Data? { nil }
    var latestPreviewAt: Date? { nil }

    func register() async throws {}

    func handleOpenURL(_ url: URL) async throws -> Bool { false }

    func connect() async throws {
        state = .connecting
        try? await Task.sleep(for: .milliseconds(350))
        state = .connected
    }

    func startObserving() async throws {
        if state == .disconnected { try await connect() }
        state = .observing
    }

    func stopObserving() async {
        state = .connected
    }

    func captureJPEG() async throws -> Data? {
        nil
    }

    func captureHighQualityPhoto() async throws -> Data? { nil }

    func captureShortVideo() async throws -> Data? {
        nil
    }

    func disconnect() async { state = .disconnected }

    func unregister() async throws { state = .disconnected }

    func watchDevices(_ onChange: @escaping @MainActor @Sendable () -> Void) -> Task<Void, Never>? { nil }
    var deviceInfo: GlassesDeviceInfo? { nil }
    func openFirmwareUpdate() async throws {}
    func openGlassesAppUpdate() async throws {}
    func cameraPermissionGranted() async -> Bool? { true }
    func requestCameraPermission() async throws -> Bool { true }
    func startGestures(_ handler: @escaping @MainActor @Sendable (GlassesGesture) -> Void) async throws {}
    func stopGestures() async {}
    func startVoiceLaunch(_ onLaunch: @escaping @MainActor @Sendable () -> Void) {}
}

#if canImport(MWDATCore)
import AVFoundation
import MWDATCamera
import MWDATCore
import MWDATInputs
import UIKit

@MainActor
extension GlassesGesture {
    static func label(_ event: InputEvent) -> String {
        switch event {
        case .nav(let direction, _, _): "nav_\(direction)"
        case .select: "select"
        case .back: "back"
        case .button: "button"
        case .capture(let press, _, _): "capture_\(press)"
        case .drag: "drag"
        @unknown default: "unknown"
        }
    }

    init?(_ event: InputEvent) {
        switch event {
        case .capture(.shortPress, _, _), .capture(.doublePress, _, _), .button(.action, _, _): self = .look
        case .capture(.hold, _, _): self = .record
        case .select: self = .toggleMute
        default: return nil
        }
    }
}

extension GlassesDeviceInfo {
    init(_ device: Device) {
        let heat: Heat = switch device.thermalLevel {
        case .moderate: .warm
        case .severe, .critical, .emergency, .shutdown: .hot
        default: .normal
        }
        self.init(
            name: device.nameOrId(),
            model: Self.model(device.deviceType()),
            battery: device.batteryLevel,
            isCharging: device.chargingState == .charging,
            isWorn: device.donState == .donned ? true : device.donState == .doffed ? false : nil,
            isFolded: device.hingeState == .closed ? true : device.hingeState == .open ? false : nil,
            heat: heat
        )
    }

    private static func model(_ type: DeviceType) -> String {
        switch type {
        case .rayBanMeta: "Ray-Ban Meta"
        case .rayBanMetaOptics: "Ray-Ban Meta Optics"
        case .oakleyMetaHSTN: "Oakley Meta HSTN"
        case .oakleyMetaVanguard: "Oakley Meta Vanguard"
        case .metaRayBanDisplay: "Meta Ray-Ban Display"
        default: "Meta glasses"
        }
    }
}

final class MetaWearablesGlassesService: GlassesService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesLens", category: "GlassesCamera")
    private let frameDecoder = GlassesFrameDecoder()
    private var inputs: Inputs?
    private var gestureTask: Task<Void, Never>?
    private var voiceLaunch: VoiceInvocationsStream?
    private var voiceLaunchTokens: [any AnyListenerToken] = []
    private var voiceLaunchTriedAt: Date?
    private var frameShapeLogged = false
    private var internalState: GlassesConnectionState = .disconnected
    let isMock = false
    private var wearables: (any WearablesInterface)?
    private var deviceSession: DeviceSession?
    private var camera: MWDATCamera.Camera?
    private var stream: MWDATCamera.Stream?
    private var frameToken: (any AnyListenerToken)?
    private var streamErrorToken: (any AnyListenerToken)?
    private var sessionErrorToken: (any AnyListenerToken)?
    private var lastSessionErrorTrace: String?
    private var latestFrameJPEG: Data?
    private var latestFrameAt: Date?
    private var videoRecorder: DirectVideoRecorder?
    private var videoRecordingError: Error?
    private var lastStreamErrorDescription: String?
    private var lastDeviceTrace: String?

    var latestPreviewJPEG: Data? { latestFrameJPEG }
    var latestPreviewAt: Date? { latestFrameAt }

    var state: GlassesConnectionState {
        if internalState == .failed { return .failed }
        if let stream {
            switch stream.state {
            case .streaming: return .observing
            case .paused: return .paused
            default: break
            }
        }
        guard let deviceSession else { return internalState == .disconnected && hasNearbyGlasses ? .ready : internalState }
        return switch deviceSession.state {
        case .started: .connected
        case .paused: .connected
        case .starting: .connecting
        case .idle, .stopping, .stopped: hasNearbyGlasses ? .ready : .disconnected
        }
    }

    /// Registered glasses that Meta AI reports as linked and compatible, found without
    /// opening a session. Luna used to hold a session whenever it ran; after the app
    /// was deleted mid-session, Meta AI kept reporting the glasses as livestreaming
    /// until a factory reset (2026-11-07). Sessions now open only for real use.
    private var hasNearbyGlasses: Bool {
        guard let wearables, wearables.registrationState == .registered else { return false }
        return wearables.devices.contains { identifier in
            guard let device = wearables.deviceForIdentifier(identifier), device.linkState == .connected else { return false }
            if case .compatible = device.compatibility() { return true }
            return false
        }
    }

    var registrationState: GlassesRegistrationState {
        guard let wearables else { return .unavailable }
        return switch wearables.registrationState {
        case .unavailable: GlassesRegistrationState.unavailable
        case .available: GlassesRegistrationState.available
        case .registering: GlassesRegistrationState.registering
        case .registered: GlassesRegistrationState.registered
        @unknown default: GlassesRegistrationState.unavailable
        }
    }

    init() {
        do {
            try Wearables.configure()
            wearables = Wearables.shared
        } catch WearablesError.alreadyConfigured {
            wearables = Wearables.shared
        } catch {
            internalState = .failed
        }
    }

    func register() async throws {
        guard let wearables else { throw GlassesServiceError.sdkUnavailable }
        if wearables.registrationState != .registered {
            try await wearables.startRegistration()
        }
    }

    func handleOpenURL(_ url: URL) async throws -> Bool {
        guard let wearables else { throw GlassesServiceError.sdkUnavailable }
        return try await wearables.handleUrl(url)
    }

    func connect() async throws {
        guard let wearables else { throw GlassesServiceError.sdkUnavailable }
        guard wearables.registrationState == .registered else {
            throw GlassesServiceError.registrationRequired
        }

        if deviceSession?.state == .started {
            internalState = stream?.state == .streaming ? .observing : .connected
            return
        }

        var permission = try await wearables.checkPermissionStatus(.camera)
        if permission == .denied {
            permission = try await wearables.requestPermission(.camera)
        }
        guard permission == .granted else {
            throw GlassesServiceError.cameraPermissionDenied
        }

        let deviceIdentifier = try await eligibleDeviceIdentifier(from: wearables)
        camera?.stop()
        deviceSession?.stop()
        camera = nil
        stream = nil
        let selector = SpecificDeviceSelector(device: deviceIdentifier)
        let session = try wearables.createSession(deviceSelector: selector)
        deviceSession = session
        if let sessionErrorToken { await sessionErrorToken.cancel() }
        // Why the glasses end a session (heat, battery, an update, Meta AI holding them).
        // The app never listened, so a session that stopped at once looked like
        // "not ready" (2026-11-05). Case names only in the log.
        sessionErrorToken = session.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in self?.traceSessionError(error) }
        }
        internalState = .connecting
        try session.start()
        try await waitForStarted(session)
        internalState = .connected
    }

    private func traceSessionError(_ error: DeviceSessionError) {
        let code = String(describing: error).split(separator: "(").first.map(String.init) ?? "unknown"
        guard code != lastSessionErrorTrace else { return }
        lastSessionErrorTrace = code
        VoiceDiagnosticLog.record("glasses.session_error", code)
    }

    /// The device search outcome in the diagnostics log, only when it changes.
    private func traceDevice(_ line: String) {
        guard line != lastDeviceTrace else { return }
        lastDeviceTrace = line
        VoiceDiagnosticLog.record("glasses.device", line)
    }

    private func eligibleDeviceIdentifier(
        from wearables: any WearablesInterface
    ) async throws -> DeviceIdentifier {
        var lastStatus = "Meta AI has not reported any glasses to Luna yet."
        var lastTrace = "devices=0"

        for _ in 0..<20 {
            let identifiers = wearables.devices
            for identifier in identifiers {
                guard let device = wearables.deviceForIdentifier(identifier) else { continue }
                let compatibility = device.compatibility()
                let linkState = device.linkState
                lastStatus = "\(device.nameOrId()) is \(linkState) and \(compatibility.displayString)."
                lastTrace = "devices=\(identifiers.count) link=\(linkState) compat=\(compatibility)"

                switch compatibility {
                case .deviceUpdateRequired:
                    // The glasses themselves need newer software (SDK 1.0: `openFirmwareUpdate`
                    // opens that screen; the DAT-app update is `datAppOnTheGlassesUpdateRequired`).
                    traceDevice(lastTrace)
                    try? await wearables.openFirmwareUpdate()
                    throw GlassesServiceError.glassesRuntimeUpdateRequired
                case .sdkUpdateRequired:
                    traceDevice(lastTrace)
                    throw GlassesServiceError.sdkUpdateRequired
                case .compatible where linkState == .connected:
                    return identifier
                case .undefined, .compatible:
                    break
                @unknown default:
                    break
                }
            }

            try await Task.sleep(for: .milliseconds(500))
        }

        // Structural only: link state and compatibility, never the glasses' name.
        traceDevice(lastTrace)
        throw GlassesServiceError.noEligibleDevice(lastStatus)
    }

    func startObserving() async throws {
        if deviceSession == nil || deviceSession?.state == .stopped {
            try await connect()
        }
        guard let deviceSession, deviceSession.state == .started else {
            throw GlassesServiceError.glassesNotReady
        }

        // DAT stream/camera stop is terminal. A stopped child must be detached
        // before the session can accept a fresh Camera capability.
        if let stream, stream.state == .stopped || stream.state == .stopping {
            await releaseCameraCapability()
        }
        if let stream, stream.state == .streaming {
            internalState = .observing
            return
        }

        // Glasses that will not serve a setting refuse it quietly (the stream never
        // starts). Step down the resolution instead of failing the look (hermes-glasses).
        let codec: VideoCodec = GlassesStreamPreferences.usesCompressedStream ? .hvc1 : .raw
        for resolution in [StreamingResolution.high, .medium, .low] {
            do {
                try await startStream(on: deviceSession, codec: codec, resolution: resolution)
                internalState = .observing
                return
            } catch GlassesServiceError.cameraUnavailable where resolution != .low {
                VoiceDiagnosticLog.record("glasses.stream", "refused resolution=\(resolution) codec=\(codec)")
                await releaseCameraCapability()
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw GlassesServiceError.cameraUnavailable
    }

    private func startStream(on deviceSession: DeviceSession, codec: VideoCodec,
                             resolution: StreamingResolution) async throws {
        if camera == nil {
            let configuration = StreamConfiguration(videoCodec: codec, resolution: resolution, frameRate: 15)
            camera = try deviceSession.addCamera(config: configuration)
            stream = camera?.stream
        }
        guard let stream else { throw GlassesServiceError.cameraUnavailable }
        if frameToken == nil {
            latestFrameJPEG = nil; latestFrameAt = nil
            frameShapeLogged = false
            frameDecoder.reset()
            let decoder = frameDecoder
            let label = "codec=\(codec) resolution=\(resolution)"
            frameToken = stream.videoFramePublisher.listen { [weak self] frame in
                // Compressed samples (.hvc1, or .raw in the background) carry no image: decode them.
                let compressed = GlassesFrameDecoder.isCompressed(frame.sampleBuffer)
                let image = compressed ? decoder.imageFrame(frame.sampleBuffer) : frame.sampleBuffer
                let jpeg = compressed
                    ? image.flatMap { decoder.jpeg($0) }
                    : frame.makeUIImage()?.jpegData(compressionQuality: 0.9)
                Task { @MainActor [weak self] in
                    self?.noteFrameShape(label: label, compressed: compressed, decoded: jpeg != nil, image: image)
                    guard let jpeg, let image else { return }
                    self?.latestFrameJPEG = jpeg
                    self?.latestFrameAt = .now
                    if let recorder = self?.videoRecorder {
                        do {
                            try recorder.append(image)
                        } catch {
                            self?.videoRecordingError = error
                        }
                    }
                }
            }
        }
        if streamErrorToken == nil {
            lastStreamErrorDescription = nil
            streamErrorToken = stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor [weak self] in
                    let description = error.description
                    self?.lastStreamErrorDescription = description
                    self?.logger.error("DAT stream error: \(description, privacy: .public)")
                }
            }
        }
        if stream.state != .streaming {
            logger.notice("Starting reusable DAT camera stream")
            stream.start()
            try await waitForStreaming(stream)
        }
    }

    /// Logs once per stream what actually arrives: codec asked for, compressed or not,
    /// and the delivered frame size. Structure only, never content.
    private func noteFrameShape(label: String, compressed: Bool, decoded: Bool, image: CMSampleBuffer?) {
        guard !frameShapeLogged else { return }
        frameShapeLogged = true
        var size = "none"
        if let image, let pixels = CMSampleBufferGetImageBuffer(image) {
            size = "\(CVPixelBufferGetWidth(pixels))x\(CVPixelBufferGetHeight(pixels))"
        }
        VoiceDiagnosticLog.record("glasses.stream", "\(label) compressed=\(compressed) decoded=\(decoded) size=\(size)")
    }

    func stopObserving() async {
        await releaseCameraCapability()
        internalState = deviceSession?.state == .started ? .connected : .disconnected
    }

    func disconnect() async {
        await stopGestures()
        await releaseCameraCapability()
        if let sessionErrorToken { await sessionErrorToken.cancel() }
        sessionErrorToken = nil
        let hadSession = deviceSession != nil
        deviceSession?.stop()
        deviceSession = nil
        internalState = .disconnected
        if hadSession { VoiceDiagnosticLog.record("glasses.session", "closed") }
    }

    func unregister() async throws {
        await disconnect()
        guard let wearables else { throw GlassesServiceError.sdkUnavailable }
        try await wearables.startUnregistration()
    }

    var deviceInfo: GlassesDeviceInfo? {
        guard let wearables else { return nil }
        let devices = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        guard let device = devices.first(where: { $0.linkState == .connected }) ?? devices.first else { return nil }
        return GlassesDeviceInfo(device)
    }

    func openFirmwareUpdate() async throws {
        guard let wearables else { throw GlassesServiceError.sdkUnavailable }
        try await wearables.openFirmwareUpdate()
    }

    func openGlassesAppUpdate() async throws {
        guard let wearables else { throw GlassesServiceError.sdkUnavailable }
        try await wearables.openDATGlassesAppUpdate()
    }

    func cameraPermissionGranted() async -> Bool? {
        guard let wearables, wearables.registrationState == .registered,
              let status = try? await wearables.checkPermissionStatus(.camera) else { return nil }
        return status == .granted
    }

    func requestCameraPermission() async throws -> Bool {
        guard let wearables else { throw GlassesServiceError.sdkUnavailable }
        return try await wearables.requestPermission(.camera) == .granted
    }

    func startGestures(_ handler: @escaping @MainActor @Sendable (GlassesGesture) -> Void) async throws {
        if deviceSession == nil || deviceSession?.state == .stopped {
            try await connect()
        }
        guard let deviceSession, deviceSession.state == .started else { throw GlassesServiceError.glassesNotReady }
        if inputs == nil {
            inputs = try deviceSession.addInputs(configuration: InputsConfiguration(
                sources: [.captouch, .captureButton, .actionButton], consumeBack: false))
        }
        guard let inputs else { throw GlassesServiceError.glassesNotReady }
        gestureTask?.cancel()
        gestureTask = Task { @MainActor in
            for await event in inputs.events {
                guard let gesture = GlassesGesture(event) else {
                    // Kind and direction only, to learn which presses the glasses deliver.
                    VoiceDiagnosticLog.record("glasses.gesture_unused", GlassesGesture.label(event))
                    continue
                }
                VoiceDiagnosticLog.record("glasses.gesture", gesture.rawValue)
                handler(gesture)
            }
        }
        VoiceDiagnosticLog.record("glasses.gestures", "started")
    }

    func startVoiceLaunch(_ onLaunch: @escaping @MainActor @Sendable () -> Void) {
        guard voiceLaunch == nil, let wearables, wearables.registrationState == .registered else { return }
        // At most one attempt a minute, so a failing channel cannot flood the log.
        if let tried = voiceLaunchTriedAt, Date.now.timeIntervalSince(tried) < 60 { return }
        guard let device = wearables.devices.first(where: { wearables.deviceForIdentifier($0)?.linkState == .connected })
        else { return }
        voiceLaunchTriedAt = .now
        do {
            let stream = try VoiceInvocationsStream(wearables: wearables)
            voiceLaunchTokens = [
                stream.invocationsPublisher.listen { invocation in
                    guard let launch = invocation as? LaunchApp else { return }
                    Task { @MainActor in
                        // Meta needs exactly one answer per request.
                        let answered = await launch.responseHandle.sendSuccess(actionOutput: nil)
                        VoiceDiagnosticLog.record("glasses.voice_launch", "received answered=\(answered)")
                        onLaunch()
                    }
                },
                stream.errorPublisher.listen { [weak self] error in
                    Task { @MainActor [weak self] in
                        VoiceDiagnosticLog.record("glasses.voice_launch", "error=\(String(describing: error).prefix(40))")
                        self?.stopVoiceLaunch()
                    }
                },
            ]
            try stream.start(deviceIdentifier: device)
            voiceLaunch = stream
            VoiceDiagnosticLog.record("glasses.voice_launch", "listening")
        } catch {
            VoiceDiagnosticLog.record("glasses.voice_launch", "failed error=\(String(describing: type(of: error)))")
            stopVoiceLaunch()
        }
    }

    private func stopVoiceLaunch() {
        voiceLaunch?.stop()
        voiceLaunch = nil
        let tokens = voiceLaunchTokens
        voiceLaunchTokens = []
        Task { for token in tokens { await token.cancel() } }
    }

    func stopGestures() async {
        gestureTask?.cancel()
        gestureTask = nil
        guard inputs != nil else { return }
        inputs = nil
        try? deviceSession?.removeInputs()
        VoiceDiagnosticLog.record("glasses.gestures", "stopped")
    }

    func watchDevices(_ onChange: @escaping @MainActor @Sendable () -> Void) -> Task<Void, Never>? {
        guard let wearables else { return nil }
        return Task { @MainActor in
            var linkTokens: [any AnyListenerToken] = []
            for await identifiers in wearables.devicesStream() {
                for token in linkTokens { await token.cancel() }
                linkTokens = identifiers.compactMap { wearables.deviceForIdentifier($0) }.flatMap { device in
                    [device.addLinkStateListener { _ in Task { @MainActor in onChange() } },
                     // Battery, charging, worn, hinge and heat (SDK 1.0).
                     device.addDeviceStateListener { _ in Task { @MainActor in onChange() } }]
                }
                onChange()
            }
            for token in linkTokens { await token.cancel() }
        }
    }

    private func releaseCameraCapability() async {
        let activeStream = stream
        if camera != nil {
            logger.notice("Stopping terminal DAT camera capability")
            // Camera.stop() cascades to its Stream and detaches the capability
            // from the active DeviceSession. A later capture must addCamera()
            // again rather than trying to restart a terminal Stream instance.
            camera?.stop()
        } else if let activeStream, activeStream.state != .stopped {
            activeStream.stop()
        }
        if let activeStream, activeStream.state != .stopped {
            try? await waitForStopped(activeStream)
        }
        if let frameToken { await frameToken.cancel() }
        if let streamErrorToken { await streamErrorToken.cancel() }
        frameToken = nil
        streamErrorToken = nil
        stream = nil
        camera = nil
        latestFrameJPEG = nil; latestFrameAt = nil
        videoRecorder?.cancel()
        videoRecorder = nil
        videoRecordingError = nil
        lastStreamErrorDescription = nil
    }

    func captureJPEG() async throws -> Data? {
        let isCaptureOnly = stream?.state != .streaming
        if stream == nil || stream?.state != .streaming {
            try await startObserving()
        }
        guard let stream else { throw GlassesServiceError.cameraUnavailable }
        do {
            let photo = try await firstPhoto(from: photoEvents(from: stream))
            if isCaptureOnly { await stopObserving() }
            return photo
        } catch {
            if isCaptureOnly { await stopObserving() }
            throw error
        }
    }

    func captureHighQualityPhoto() async throws -> Data? {
        guard stream?.state != .streaming else { return nil }
        if deviceSession == nil || deviceSession?.state == .stopped {
            try await connect()
        }
        guard let deviceSession, deviceSession.state == .started else { throw GlassesServiceError.glassesNotReady }
        if camera == nil {
            camera = try deviceSession.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 15))
            stream = camera?.stream
        }
        guard let photo = camera?.photo else { throw GlassesServiceError.cameraUnavailable }
        defer { Task { await self.releaseCameraCapability() } }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await Self.firstStandalonePhoto(photo) }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw GlassesServiceError.photoCaptureTimedOut
            }
            guard let data = try await group.next() else { throw GlassesServiceError.photoCaptureFailed }
            group.cancelAll()
            return data
        }
    }

    /// Starts the photo capability, takes one large, high-quality photo once it is
    /// started, and returns its bytes; the capability's error ends the wait.
    private nonisolated static func firstStandalonePhoto(_ photo: MWDATCamera.Photo) async throws -> Data {
        let events = AsyncThrowingStream<Data, Error> { continuation in
            let listeners = ListenerStore()
            let stateToken = photo.statePublisher.listen { state in
                if state == .started { photo.capturePhoto(resolution: .large, quality: .high) }
            }
            let dataToken = photo.photoDataPublisher.listen { captured in
                continuation.yield(captured.imageData)
                continuation.finish()
            }
            let errorToken = photo.errorPublisher.listen { error in
                continuation.finish(throwing: GlassesServiceError.videoStreamFailed(error.description))
            }
            Task { await listeners.set([stateToken, dataToken, errorToken]) }
            continuation.onTermination = { _ in
                Task { await listeners.cancel() }
                photo.stop()
            }
            photo.start()
        }
        for try await data in events { return data }
        throw GlassesServiceError.photoCaptureFailed
    }

    func captureShortVideo() async throws -> Data? {
        let isCaptureOnly = stream?.state != .streaming
        if stream == nil || stream?.state != .streaming {
            try await startObserving()
        }
        logger.notice("Beginning six-second direct DAT video recording")
        let recorder = DirectVideoRecorder()
        videoRecorder = recorder
        videoRecordingError = nil
        do {
            for _ in 0..<60 {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            videoRecorder = nil
            recorder.cancel()
            if isCaptureOnly { await stopObserving() }
            throw error
        }
        videoRecorder = nil
        if let videoRecordingError {
            recorder.cancel()
            self.videoRecordingError = nil
            if isCaptureOnly { await stopObserving() }
            throw videoRecordingError
        }
        let clip: Data
        do {
            clip = try await recorder.finish()
        } catch {
            if isCaptureOnly { await stopObserving() }
            if let lastStreamErrorDescription {
                throw GlassesServiceError.videoStreamFailed(lastStreamErrorDescription)
            }
            throw error
        }
        if isCaptureOnly { await stopObserving() }
        logger.notice("Direct DAT video completed with \(clip.count, privacy: .public) bytes")
        return clip  // saved on the phone only, so there is no upload size to respect
    }

    private func photoEvents(
        from stream: MWDATCamera.Stream
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let listenerStore = ListenerStore()
            let photoToken = stream.photoDataPublisher.listen { photo in
                continuation.yield(photo.data)
                continuation.finish()
            }
            let errorToken = stream.errorPublisher.listen { error in
                continuation.finish(
                    throwing: GlassesServiceError.videoStreamFailed(error.description)
                )
            }
            Task { await listenerStore.set([photoToken, errorToken]) }
            continuation.onTermination = { _ in
                Task { await listenerStore.cancel() }
            }
            guard stream.capturePhoto(format: .jpeg) else {
                continuation.finish(throwing: GlassesServiceError.photoRequestRejected)
                return
            }
        }
    }

    private func waitForStreaming(_ stream: MWDATCamera.Stream) async throws {
        var sawStartupTransition = false

        for attempt in 0..<150 {
            switch stream.state {
            case .streaming:
                return
            case .stopped:
                if sawStartupTransition || attempt >= 15 {
                    throw GlassesServiceError.cameraUnavailable
                }
                try await Task.sleep(for: .milliseconds(200))
            case .waitingForDevice, .starting:
                sawStartupTransition = true
                try await Task.sleep(for: .milliseconds(200))
            case .stopping:
                throw GlassesServiceError.cameraUnavailable
            case .paused:
                try await Task.sleep(for: .milliseconds(200))
            @unknown default:
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        throw GlassesServiceError.connectionTimedOut
    }

    private func waitForStopped(_ stream: MWDATCamera.Stream) async throws {
        for _ in 0..<30 {
            switch stream.state {
            case .stopped:
                return
            case .streaming, .waitingForDevice, .starting, .paused, .stopping:
                try await Task.sleep(for: .milliseconds(100))
            @unknown default:
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        logger.error("DAT camera stream did not stop before its reuse window")
        throw GlassesServiceError.connectionTimedOut
    }

    private func waitForStarted(_ session: DeviceSession) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await sessionState in session.stateStream() {
                    if sessionState == .started { return }
                    if sessionState == .stopped {
                        throw GlassesServiceError.glassesNotReady
                    }
                }
                throw GlassesServiceError.glassesNotReady
            }
            group.addTask {
                // A reason the glasses give is more useful than "not ready".
                for await error in session.errorStream() {
                    if let reason = GlassesServiceError.sessionRejected(error) { throw reason }
                }
                try await Task.sleep(for: .seconds(30))
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw GlassesServiceError.connectionTimedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func firstPhoto(
        from events: AsyncThrowingStream<Data, Error>
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                for try await data in events { return data }
                throw GlassesServiceError.photoCaptureFailed
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw GlassesServiceError.photoCaptureTimedOut
            }
            guard let result = try await group.next() else {
                throw GlassesServiceError.photoCaptureFailed
            }
            group.cancelAll()
            return result
        }
    }
}

@MainActor
private final class DirectVideoRecorder {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var outputURL: URL?
    private var frameCount = 0

    func append(_ sampleBuffer: CMSampleBuffer) throws {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if writer == nil {
            try configure(using: sampleBuffer)
        }
        guard let writer, let input else {
            throw GlassesServiceError.videoCaptureFailed
        }
        guard writer.status == .writing else {
            throw writer.error ?? GlassesServiceError.videoCaptureFailed
        }
        guard input.isReadyForMoreMediaData else { return }
        guard input.append(sampleBuffer) else {
            throw writer.error ?? GlassesServiceError.videoCaptureFailed
        }
        frameCount += 1
    }

    func finish() async throws -> Data {
        guard let writer, let input, let outputURL, frameCount >= 2 else {
            cancel()
            throw GlassesServiceError.videoCaptureFailed
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            let error = writer.error ?? GlassesServiceError.videoCaptureFailed
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        return try Data(contentsOf: outputURL)
    }

    func cancel() {
        writer?.cancelWriting()
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        writer = nil
        input = nil
        outputURL = nil
        frameCount = 0
    }

    private func configure(using sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw GlassesServiceError.videoCaptureFailed
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        guard dimensions.width >= 2, dimensions.height >= 2 else {
            throw GlassesServiceError.videoCaptureFailed
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-lens-direct-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 4_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ],
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw GlassesServiceError.videoCaptureFailed
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? GlassesServiceError.videoCaptureFailed
        }
        let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard startTime.isValid else {
            writer.cancelWriting()
            throw GlassesServiceError.videoCaptureFailed
        }
        writer.startSession(atSourceTime: startTime)
        self.writer = writer
        self.input = input
        outputURL = url
    }
}

private actor ListenerStore {
    private var tokens: [any AnyListenerToken] = []
    private var isCancelled = false

    func set(_ newTokens: [any AnyListenerToken]) async {
        if isCancelled {
            for token in newTokens { await token.cancel() }
        } else {
            tokens = newTokens
        }
    }

    func cancel() async {
        isCancelled = true
        let activeTokens = tokens
        tokens.removeAll()
        for token in activeTokens { await token.cancel() }
    }
}
#endif

enum GlassesServiceError: Error, LocalizedError {
    case hardwareSetupRequired
    case sdkUnavailable
    case registrationRequired
    case cameraPermissionDenied
    case glassesRuntimeUpdateRequired
    case sdkUpdateRequired
    case noEligibleDevice(String)
    case glassesNotReady
    case cameraUnavailable
    case connectionTimedOut
    case photoRequestRejected
    case photoCaptureTimedOut
    case photoCaptureFailed
    case videoCaptureFailed
    case videoStreamFailed(String)
    case tooHot
    case batteryLow
    case glassesAppUpdateRequired
    case glassesAppUnavailable

    /// The glasses' own reason for refusing or ending a session, when it is one the user can act on.
    static func sessionRejected(_ error: DeviceSessionError) -> GlassesServiceError? {
        switch error {
        case .thermalCritical, .thermalEmergency: .tooHot
        case .batteryCritical, .peakPowerShutdown: .batteryLow
        case .datAppOnTheGlassesUpdateRequired: .glassesAppUpdateRequired
        // SDK 1.0: the glasses need a newer Luna build. (dwaOutOfStuRange is only a warning.)
        case .insufficientSDKVersion: .sdkUpdateRequired
        case .dwaUnavailable: .glassesAppUnavailable
        default: nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .hardwareSetupRequired:
            "Meta developer registration and glasses permission are required before hardware capture."
        case .sdkUnavailable: "The Meta Wearables service could not be initialized."
        case .registrationRequired: "Set up Luna with Meta AI first."
        case .cameraPermissionDenied: "Camera access was not granted in Meta AI."
        case .glassesRuntimeUpdateRequired:
            "Your glasses need a software update. Meta AI is opening to update them."
        case .sdkUpdateRequired:
            "Luna needs an update to work with these glasses."
        case .noEligibleDevice(let status):
            "No eligible glasses are ready. \(status)"
        case .glassesNotReady: "Open, wear, and connect the glasses, then try again."
        case .cameraUnavailable: "The glasses camera is not available."
        case .connectionTimedOut: "The glasses connection timed out."
        case .photoRequestRejected: "The glasses rejected the photo request."
        case .photoCaptureTimedOut: "The glasses did not return a photo in time."
        case .photoCaptureFailed: "The glasses could not capture a photo."
        case .videoCaptureFailed: "The glasses could not create a short visual scan."
        case .videoStreamFailed(let detail):
            "The glasses video stream stopped before recording finished. \(detail)"
        case .tooHot: "The glasses are too hot. Let them cool down, then try again."
        case .batteryLow: "The glasses battery is too low. Charge them, then try again."
        case .glassesAppUpdateRequired: "The glasses need a software update. Open the Meta AI app to update them."
        case .glassesAppUnavailable: "The glasses' connection for Luna isn't responding. Restart the glasses, check they show as connected in the Meta AI app, then try again."
        }
    }
}
