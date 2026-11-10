import AVFAudio
import Foundation
import Observation

enum AudioDiagnosticState: Equatable {
    case inactive
    case preparing
    case active
    case interrupted
    case failed(String)

    var displayName: String {
        switch self {
        case .inactive: "Inactive"
        case .preparing: "Preparing"
        case .active: "Listening"
        case .interrupted: "Interrupted"
        case .failed: "Needs attention"
        }
    }
}

@MainActor
@Observable
final class AudioDiagnosticService {
    var state: AudioDiagnosticState = .inactive
    var permissionName = "Not requested"
    var availableInputs: [String] = []
    var inputRoute = "None"
    var outputRoute = "None"
    var sampleRate = 0.0
    var channelCount: UInt32 = 0
    var ioBufferDuration = 0.0
    var inputLevel = 0.0
    var lastEvent = "Ready for a deliberate foreground test."

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let observerTokens = ObserverTokens()
    private var hasInputTap = false

    init() {
        refreshPermission()
        refreshRoutes()
        observeAudioLifecycle()
    }

    func requestPermissionAndStart() async {
        state = .preparing
        let granted = await requestPermission()
        refreshPermission()
        guard granted else {
            state = .failed("Microphone permission was denied.")
            lastEvent = "Enable microphone access in iPhone Settings to continue."
            return
        }

        do {
            try configureSession()
            try startMetering()
            state = .active
            lastEvent = isUsingBluetoothInput
                ? "Ray-Ban Bluetooth microphone selected."
                : "Audio is active, but the input is not the Ray-Ban microphone."
        } catch {
            stop()
            state = .failed(error.localizedDescription)
            lastEvent = error.localizedDescription
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        synthesizer.stopSpeaking(at: .immediate)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        inputLevel = 0
        state = .inactive
        refreshRoutes()
        lastEvent = "Audio test stopped. No audio was saved."
    }

    func speakRouteTest() {
        guard state == .active else {
            lastEvent = "Start the audio test before testing speech output."
            return
        }
        let utterance = AVSpeechUtterance(
            string: "Luna audio test. If you hear this in the glasses, the output route is working."
        )
        utterance.rate = 0.48
        synthesizer.speak(utterance)
        lastEvent = "Speech test sent to (outputRoute)."
    }

    var isUsingBluetoothInput: Bool {
        session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
    }

    var isUsingBluetoothOutput: Bool {
        session.currentRoute.outputs.contains {
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP
        }
    }

    private func requestPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func configureSession() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP]
        )
        try session.setActive(true)

        if let rayBanInput = session.availableInputs?.first(where: isLikelyGlassesInput) {
            try session.setPreferredInput(rayBanInput)
        } else if let hfpInput = session.availableInputs?.first(where: {
            $0.portType == .bluetoothHFP
        }) {
            try session.setPreferredInput(hfpInput)
        }
        refreshRoutes()
    }

    private func startMetering() throws {
        guard !engine.isRunning else { return }
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioDiagnosticError.inputUnavailable
        }

        if !hasInputTap {
            AudioLevelTap.install(on: inputNode, format: format) { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.inputLevel = level
                }
            }
            hasInputTap = true
        }

        engine.prepare()
        try engine.start()
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        ioBufferDuration = session.ioBufferDuration
    }

    private func refreshPermission() {
        permissionName = switch AVAudioApplication.shared.recordPermission {
        case .granted: "Allowed"
        case .denied: "Denied"
        case .undetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }

    private func refreshRoutes() {
        availableInputs = session.availableInputs?.map {
            "\($0.portName) · \($0.portType.rawValue)"
        } ?? []
        inputRoute = routeName(session.currentRoute.inputs)
        outputRoute = routeName(session.currentRoute.outputs)
        if session.sampleRate > 0 { sampleRate = session.sampleRate }
        ioBufferDuration = session.ioBufferDuration
    }

    private func routeName(_ ports: [AVAudioSessionPortDescription]) -> String {
        ports.isEmpty ? "None" : ports.map { "\($0.portName) · \($0.portType.rawValue)" }.joined(separator: ", ")
    }

    private func isLikelyGlassesInput(_ input: AVAudioSessionPortDescription) -> Bool {
        guard input.portType == .bluetoothHFP else { return false }
        let name = input.portName.lowercased()
        return name.contains("ray-ban") || name.contains("rayban") || name.contains("meta")
    }

    private func observeAudioLifecycle() {
        let routeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRoutes()
                self?.lastEvent = "Audio route changed. Verify the active microphone before continuing."
            }
        }
        let interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self else { return }
                if rawType == AVAudioSession.InterruptionType.began.rawValue {
                    state = .interrupted
                    lastEvent = "Audio was interrupted. Resume only with an explicit tap."
                } else {
                    lastEvent = "Interruption ended. Tap Start audio test to resume."
                }
                refreshRoutes()
            }
        }
        observerTokens.values = [routeToken, interruptionToken]
    }
}

private final class ObserverTokens: @unchecked Sendable {
    var values: [NSObjectProtocol] = []

    deinit {
        for token in values {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

private enum AudioLevelTap {
    static func install(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        levelHandler: @escaping @Sendable (Double) -> Void
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?.pointee else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            var sum = 0.0
            for index in 0..<frameCount {
                let sample = Double(channel[index])
                sum += sample * sample
            }
            levelHandler(min(1, sqrt(sum / Double(frameCount)) * 8))
        }
    }
}

enum AudioDiagnosticError: Error, LocalizedError {
    case inputUnavailable

    var errorDescription: String? {
        switch self {
        case .inputUnavailable: "No usable microphone input is available."
        }
    }
}
