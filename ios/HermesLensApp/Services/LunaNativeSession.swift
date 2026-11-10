@preconcurrency import AVFAudio
import Foundation
import HermesLensCore
import Observation
import UIKit

private enum NativeSend: Sendable {
    case audio(Data), endAudio
    /// Self-test speech streamed in place of the mic (debug builds); never gated by mute.
    case injected(Data)
}

private final class NativeSocketDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// First-buffer and first-chunk markers for one installed tap, read from the audio thread.
private final class NativeInputProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = false
    private var chunks = false
    /// True exactly once, on the tap's first buffer.
    func firstBuffer() -> Bool { lock.lock(); defer { lock.unlock() }; if buffers { return false }; buffers = true; return true }
    /// True exactly once, on the first converted 16 kHz chunk.
    func firstChunk() -> Bool { lock.lock(); defer { lock.unlock() }; if chunks { return false }; chunks = true; return true }
    var hasBuffer: Bool { lock.lock(); defer { lock.unlock() }; return buffers }
}

/// The audio callback never awaits network or queues unbounded MainActor tasks.
private final class NativeMicrophoneGate: @unchecked Sendable {
    private let lock = NSLock()
    private var muted = false
    func setMuted(_ value: Bool) { lock.lock(); muted = value; lock.unlock() }
    var isMuted: Bool { lock.lock(); defer { lock.unlock() }; return muted }
}

private actor NativeSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    init(call: LunaNativeCall) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = TimeInterval(call.maxSeconds)
        session = URLSession(configuration: configuration, delegate: NativeSocketDelegate(), delegateQueue: nil)
        task = session.webSocketTask(with: call.socketRequest())
        task.maximumMessageSize = 1_048_576
    }
    func start(_ setup: Data) async throws {
        task.resume()
        try await task.send(.string(String(decoding: setup, as: UTF8.self)))
    }
    func send(_ event: NativeSend) async throws {
        let data: Data
        switch event {
        case .audio(let chunk), .injected(let chunk): data = try LunaNativeWire.audio(chunk)
        case .endAudio: data = LunaNativeWire.audioEnd()
        }
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
    /// A complete client message (tool responses), sent outside the audio queue so
    /// a busy microphone stream can never drop it.
    func sendMessage(_ data: Data) async throws {
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw LunaNativeError.invalidResponse
        }
    }
    /// WebSocket close code only; the close reason is provider text and is never read.
    var closeCode: Int { task.closeCode.rawValue }
    func close() { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
}

/// One foreground-started duplex call. No Apple recognition or ElevenLabs chain.
/// Why a call's camera tool failed, as a fixed code for the trace (no content).
struct LunaCameraError: Error {
    let code: String
}

/// Phone-side tools for a native call: the glasses camera. Provided by the app shell.
struct LunaNativeLocalTools {
    /// One glasses photo (JPEG), already saved to the Library.
    var capturePhoto: @MainActor () async throws -> Data
    /// A short glasses clip, saved to the Library; Luna's summary follows there.
    var recordVideo: @MainActor () async throws -> Void
    /// The call ended: release anything held for it (the warm camera stream).
    var endCall: @MainActor () async -> Void = {}
}

@MainActor @Observable
final class LunaNativeSession {
    private(set) var state = LunaNativeCallState()
    private(set) var errorMessage: String?
    private(set) var routeTitle = "iPhone"
    private(set) var inputLevel = 0.0
    /// Tools in flight (look, record, back office), shown as chips on Home.
    private(set) var tools: [LunaToolActivity] = []
    var activeTools: Int { tools.count }
    /// When the current approval card appeared (for its countdown).
    private(set) var approvalShownAt: Date?
    /// The conversation so far, kept in memory and handed to the call record at End.
    private(set) var turns: [LunaCallTurn] = []
    /// Actions the user approved or declined during this call.
    private(set) var actions: [LunaCallAction] = []
    /// The look photos taken in this call (newest last, at most four, at most 1440 px), kept in
    /// memory only so a request can carry them when Luna asks to attach photos. Dropped at the end.
    @ObservationIgnored private var callPhotos: [Data] = []
    /// A tapped shortcut ("Look") made before the call finished connecting.
    @ObservationIgnored private var pendingAsk: String?
    /// The grant locked in `ask_luna`, so the user's Hermes agent and its tools are reachable.
    private(set) var toolsAvailable = false
    /// An action Hermes wants to take, waiting for the user's tap. Never approved by voice.
    private(set) var approval: LunaNativeToolResult.Approval?
    private(set) var approvalBusy = false
    /// A contact Luna read from a card, waiting for the user's check in Apple's sheet.
    /// Kept after the call ends so they can still save it.
    private(set) var contactDraft: LunaContactDraft?
    /// False when the call failed for a reason an immediate retry cannot fix.
    private(set) var retryable = true
    @ObservationIgnored private let localTools: LunaNativeLocalTools?
    @ObservationIgnored private let coordinator: AudioSessionCoordinator
    @ObservationIgnored private let broker: LunaNativeBrokerClient
    @ObservationIgnored private var socket: NativeSocket?
    @ObservationIgnored private var callID: UUID?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    /// Soft "still working" cue while the back office runs and Luna is quiet.
    @ObservationIgnored private var cuePlayer: AVAudioPlayerNode?
    @ObservationIgnored private var thinkingCue: AVAudioPCMBuffer?
    @ObservationIgnored private var connectedCue: AVAudioPCMBuffer?
    @ObservationIgnored private var thinkingTask: Task<Void, Never>?
    /// Uptime when Luna's queued speech finishes playing.
    @ObservationIgnored private var speechPlaysUntil: TimeInterval = 0
    @ObservationIgnored private var playbackFormat: AVAudioFormat?
    @ObservationIgnored private var audioTap: HermesPCM16KAudioTap?
    @ObservationIgnored private var gate: NativeMicrophoneGate?
    @ObservationIgnored private var outbound: AsyncStream<NativeSend>.Continuation?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    @ObservationIgnored private var setupDeadline: Task<Void, Never>?
    @ObservationIgnored private var durationDeadline: Task<Void, Never>?
    @ObservationIgnored private var turnDeadline: Task<Void, Never>?
    @ObservationIgnored private var writeDeadline: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var hasTap = false
    @ObservationIgnored private var tapFormat: AVAudioFormat?
    @ObservationIgnored private var engineRestarts: [TimeInterval] = []
    @ObservationIgnored private var toolTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var inputProbe: NativeInputProbe?
    @ObservationIgnored private var voiceProcessing = false
    @ObservationIgnored private var levelPeak = 0.0
    @ObservationIgnored private var levelTrace: Task<Void, Never>?
    @ObservationIgnored private var heardInTurn = false
    #if DEBUG
    /// Self-test only (`-LunaCaptureMic`): the exact PCM sent to Gemini, first 40 s,
    /// written to the app container at call end so the Mac can inspect it.
    @ObservationIgnored private var micCapture: Data?
    #endif
    @ObservationIgnored private var inputWatchdog: Task<Void, Never>?
    /// Any non-zero input since the tap was (re)built; see `armSilenceWatchdog`.
    @ObservationIgnored private var heardSound = false
    @ObservationIgnored private var silenceWatchdog: Task<Void, Never>?
    @ObservationIgnored private var silentInputResets = 0
    @ObservationIgnored private var scheduledBuffers = 0
    @ObservationIgnored private var playedBuffers = 0
    /// One native call per app. A session left behind (the screen was abandoned
    /// via another tab or a capture flow) is ended before a new one starts;
    /// otherwise its grant stays live and the bridge refuses the next call (409).
    @ObservationIgnored private static weak var current: LunaNativeSession?
    /// The bridge call this app last opened. A killed, crashed or reinstalled app
    /// never sends its DELETE, and the bridge then refuses the next call from this
    /// device (409) for up to nine minutes. The next start ends it first.
    private static let openCallKey = "luna.native.openCallID"
    @ObservationIgnored private var ownsAudio = false
    @ObservationIgnored private var requiresBluetooth = false
    @ObservationIgnored private var startedAt = 0.0
    @ObservationIgnored private var lastSpeechAt = 0.0
    @ObservationIgnored private var firstInputSent = false
    @ObservationIgnored private var droppedAudioChunks = 0
    @ObservationIgnored private var firstOutputInTurn = true

    init(coordinator: AudioSessionCoordinator, configuration: HermesEndpointConfiguration,
         localTools: LunaNativeLocalTools? = nil) {
        self.coordinator = coordinator
        self.localTools = localTools
        broker = LunaNativeBrokerClient(configuration: configuration)
    }

    func start() async {
        guard [.idle, .ended, .failed].contains(state.phase) else { return }
        if let previous = Self.current, previous !== self {
            if ![.idle, .ended, .failed].contains(previous.state.phase) {
                previous.end(); VoiceDiagnosticLog.record("native.call.replaced")
            }
            await previous.closingTask?.value
        }
        Self.current = self
        cleanup(); state.begin(); errorMessage = nil; retryable = true
        startedAt = ProcessInfo.processInfo.systemUptime
        firstInputSent = false; droppedAudioChunks = 0; firstOutputInTurn = true; lastSpeechAt = 0
        let generation = state.generation
        trace("connect.requested")
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard generation == state.generation, !Task.isCancelled else { return }
        guard allowed else { fail(LunaNativeError.microphone, reason: "microphone_denied"); return }
        do {
            try coordinator.claim(.nativeVoice); ownsAudio = true
            // Bring up the glasses' microphone while the token is fetched (hermes-glasses):
            // the route is decided when the socket is ready, and a slow HFP link would
            // otherwise leave the whole call on the iPhone.
            let route = Task { await self.prepareGlassesRoute() }
            await closingTask?.value
            if let stale = UserDefaults.standard.string(forKey: Self.openCallKey).flatMap(UUID.init(uuidString:)) {
                await broker.end(stale)
                UserDefaults.standard.removeObject(forKey: Self.openCallKey)
                trace("call.stale_closed")
            }
            guard generation == state.generation, !Task.isCancelled else { return }
            let call = try await broker.create(requestID: generation)
            guard generation == state.generation, !Task.isCancelled else {
                await broker.end(call.callID); return
            }
            callID = call.callID
            UserDefaults.standard.set(call.callID.uuidString, forKey: Self.openCallKey)
            toolsAvailable = call.tools == true
            trace("token.ready", detail: "model=\(call.model) tools=\(toolsAvailable)")
            await route.value
            guard generation == state.generation, !Task.isCancelled else {
                await broker.end(call.callID); return
            }
            let connection = NativeSocket(call: call)
            socket = connection
            setupDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, generation == self.state.generation,
                      self.state.phase == .connecting else { return }
                self.fail(LunaNativeError.connection, reason: "setup_deadline")
            }
            try await connection.start(call.setupMessage())
            guard generation == state.generation, !Task.isCancelled else { await connection.close(); return }
            receiveTask = Task { [weak self] in
                var stage = "socket_receive"
                do {
                    while !Task.isCancelled {
                        stage = "socket_receive"
                        let data = try await connection.receive()
                        guard let self, generation == self.state.generation else { return }
                        stage = "wire_decode"
                        for event in try LunaNativeWire.decode(data) {
                            guard generation == self.state.generation else { return }
                            stage = "handle_\(Self.label(event))"
                            try self.handle(event, generation: generation)
                        }
                    }
                } catch {
                    let closeCode = await connection.closeCode
                    guard let self, generation == self.state.generation, !Task.isCancelled else { return }
                    self.fail(LunaNativeError.connection, reason: "\(stage) close=\(closeCode)", underlying: error)
                }
            }
            let remaining = min(TimeInterval(call.maxSeconds), call.expiresAt.timeIntervalSinceNow - 2)
            durationDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, remaining)))
                guard !Task.isCancelled, let self, generation == self.state.generation else { return }
                self.end()
                self.errorMessage = "This call reached its nine-minute limit. Start a new call to continue."
            }
        } catch {
            guard generation == state.generation, !Task.isCancelled else { return }
            fail(error, reason: "connect")
        }
    }

    private func handle(_ event: LunaNativeEvent, generation: UUID) throws {
        switch event {
        case .ready:
            guard state.phase == .connecting else { return }
            setupDeadline?.cancel(); setupDeadline = nil
            try configureAudio(generation: generation)
            state.connected(); trace("socket.ready")
            // Three rising notes: Luna is listening now (heard on the glasses).
            playCue(connectedCue)
            if let pendingAsk { self.pendingAsk = nil; ask(pendingAsk) }
            return
        case .interrupted:
            turns.record(heard: state.heard, said: state.transcript)
            state.interrupt(manual: false); stopPlayback()
            firstOutputInTurn = true; turnDeadline?.cancel(); trace("turn.interrupted")
            return
        case .failure: throw LunaNativeError.connection
        case .goAway:
            end(); errorMessage = "The live connection reached its limit. Start a new call to continue."
            return
        case .usage(let input, let output):
            VoiceDiagnosticLog.record("native.usage", "input_tokens=\(input) output_tokens=\(output)")
        case .inputTranscript:
            if !heardInTurn { heardInTurn = true; trace("turn.heard") }
            armTurnDeadline(generation: generation)
        case .toolCalls(let calls):
            for call in calls { startTool(call, generation: generation) }
            return
        case .toolCancellation(let ids):
            for id in ids { toolTasks.removeValue(forKey: id)?.cancel() }
            tools.removeAll { ids.contains($0.id) }
            trace("tool.cancelled", detail: "count=\(ids.count)")
            return
        default: break
        }
        let shouldPlay = state.receive(event, generation: generation)
        if state.phase == .failed { throw LunaNativeError.audioBacklog }
        if case .audio(let data) = event, shouldPlay {
            if firstOutputInTurn {
                firstOutputInTurn = false
                let sinceSpeech = lastSpeechAt > 0 ? Int((ProcessInfo.processInfo.systemUptime - lastSpeechAt) * 1000) : -1
                trace("audio.first_received", detail: "since_local_speech_ms=\(sinceSpeech)")
                armTurnDeadline(generation: generation)
            }
            try play(data)
        }
        if case .turnComplete = event {
            turns.record(heard: state.heard, said: state.transcript)
            heardInTurn = false
            turnDeadline?.cancel(); turnDeadline = nil
            firstOutputInTurn = true; trace("turn.provider_complete")
            tracePlayback(generation: generation)
        }
    }

    private func configureAudio(generation: UUID) throws {
        let audio = AVAudioSession.sharedInstance()
        // No `.defaultToSpeaker`: on the glasses it produced an output override ~1 s
        // into the call that dropped the HFP link (route_change_4_bt0, 2026-10-30).
        // Dictation and live translation, both proven on the glasses, omit it too.
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try audio.setPreferredIOBufferDuration(0.02)
        try audio.setActive(true)
        preferGlassesInput(audio)
        #if DEBUG
        // Self-test only: use the iPhone's own mic so the whole pipeline can be
        // proven from the Mac's speakers regardless of where the glasses are.
        if LunaSelfTest.flag("-LunaBuiltInMic"),
           let builtIn = audio.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? audio.setPreferredInput(builtIn)
        }
        #endif
        requiresBluetooth = audio.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
        // iPhone-only call: the speaker, not the earpiece receiver.
        if !requiresBluetooth { try? audio.overrideOutputAudioPort(.speaker) }
        routeTitle = requiresBluetooth ? "Glasses / Bluetooth" : "iPhone"
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        self.engine = engine; self.player = player
        engine.attach(player)
        // Voice processing (Apple's echo canceller) only for the iPhone's own mic and
        // speaker, where open-speaker duplex would otherwise echo. On the glasses'
        // Bluetooth HFP route it reconfigured the engine ~350 ms after start and the
        // tap then delivered nothing (glasses, 2026-10-30). The two paths proven on
        // the glasses — dictation and live translation — never enable it; HFP
        // headsets cancel their own echo.
        voiceProcessing = !requiresBluetooth
        if voiceProcessing { try engine.inputNode.setVoiceProcessingEnabled(true) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)
        else { throw LunaNativeError.invalidResponse }
        playbackFormat = format
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let cuePlayer = AVAudioPlayerNode()
        engine.attach(cuePlayer); engine.connect(cuePlayer, to: engine.mainMixerNode, format: format)
        self.cuePlayer = cuePlayer; thinkingCue = Self.makeThinkingCue(format: format)
        connectedCue = Self.makeCue(format: format, notes: [(0, 523.25), (0.09, 659.25), (0.18, 783.99)], seconds: 0.5)
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        trace("audio.route", detail: "hfp=\(requiresBluetooth) vp=\(voiceProcessing) rate=\(Int(inputFormat.sampleRate)) channels=\(inputFormat.channelCount)")
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw LunaNativeError.connection }
        // ~3 s of 100 ms mic chunks. On a slow or relayed network the oldest audio is
        // dropped and the call carries on; only a send stalled past the write deadline
        // ends it. Holding just 0.5 s ended every call on a slow phone network
        // (tap_backlog, 2026-10-31).
        let (stream, continuation) = AsyncStream<NativeSend>.makeStream(bufferingPolicy: .bufferingNewest(30))
        outbound = continuation
        let gate = NativeMicrophoneGate()
        self.gate = gate
        guard let socket else { throw LunaNativeError.connection }
        sendTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled, let self, generation == self.state.generation else { return }
                if case .audio = event, gate.isMuted { continue }
                self.writeDeadline = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, let self, generation == self.state.generation else { return }
                    self.fail(LunaNativeError.audioBacklog, reason: "write_deadline")
                }
                #if DEBUG
                if case .audio(let chunk) = event, self.micCapture != nil, self.micCapture!.count < 40 * 32_000 {
                    self.micCapture!.append(chunk)
                }
                #endif
                do {
                    try await socket.send(event)
                    self.writeDeadline?.cancel(); self.writeDeadline = nil
                    guard generation == self.state.generation else { return }
                    if !self.firstInputSent, case .injected = event { self.firstInputSent = true; self.trace("audio.first_sent", detail: "injected=true") }
                    if !self.firstInputSent, case .audio = event {
                        self.firstInputSent = true; self.trace("audio.first_sent")
                    }
                } catch {
                    guard generation == self.state.generation, !Task.isCancelled else { return }
                    self.fail(LunaNativeError.connection, reason: "socket_send", underlying: error); return
                }
            }
        }
        // Tap before start. Starting first left the input format at 0 Hz with voice
        // processing on (self-test, 2026-10-30); an input with no tap is not pulled.
        try installInputTap(on: engine, format: inputFormat, generation: generation)
        engine.prepare(); try engine.start(); player.play()
        installObservers(generation: generation)
        startThinkingCue(generation: generation)
        #if DEBUG
        if LunaSelfTest.flag("-LunaCaptureMic") { micCapture = Data() }
        startInjectedSpeech(generation: generation)
        #endif
        // Peak input level every 5 s: a number only, to tell a silent mic from an unheard one.
        levelTrace = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, generation == self.state.generation else { return }
                self.trace("audio.level", detail: "peak=\(String(format: "%.3f", self.levelPeak))")
                self.levelPeak = 0
            }
        }
        trace("audio.ready", detail: "rate=\(Int(inputFormat.sampleRate)) hfp=\(requiresBluetooth) vp=\(voiceProcessing)")
    }

    #if DEBUG
    /// Self-test only (`-LunaInjectPCM`): streams `selftest-input.pcm` (16 kHz mono
    /// Int16, pushed from the Mac) in real time in place of the microphone, which is
    /// muted. Exercises Gemini, delegation, playback and interruption independently
    /// of the room's acoustics; mic capture is verified separately.
    private func startInjectedSpeech(generation: UUID) {
        guard LunaSelfTest.flag("-LunaInjectPCM"),
              let url = VoiceDiagnosticLog.fileURL?.deletingLastPathComponent().appendingPathComponent("selftest-input.pcm"),
              let pcm = try? Data(contentsOf: url), !pcm.isEmpty, let outbound else { return }
        gate?.setMuted(true)
        trace("selftest.inject_start", detail: "seconds=\(pcm.count / 32_000)")
        Task { [weak self] in
            var offset = 0
            while offset < pcm.count {
                guard let self, generation == self.state.generation else { return }
                let end = min(offset + 3_200, pcm.count)
                if case .dropped = outbound.yield(.injected(pcm.subdata(in: offset..<end))) { self.trace("selftest.inject_dropped") }
                offset = end
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.trace("selftest.inject_end")
        }
    }
    #endif

    /// Answers one Gemini tool call: `ask_luna` through the bridge, `look` and
    /// `record_video` on the phone with the glasses camera.
    ///
    /// The calls are non-blocking on Gemini's side: Luna keeps listening and talking
    /// while they work, and speaks the result when idle. Every outcome, including a
    /// failure, gets a tool response so Gemini never waits on a lost call. Only fixed
    /// outcome codes and timings are traced, never the request, image or answer.
    private func startTool(_ call: LunaNativeToolCall, generation: UUID) {
        guard let callID, let socket, toolTasks[call.id] == nil else { return }
        let started = ProcessInfo.processInfo.systemUptime
        let crowded = toolTasks.count >= 4
        trace("tool.requested", detail: "name=\(Self.toolLabel(call.name)) crowded=\(crowded)")
        toolTasks[call.id] = Task { [weak self, broker] in
            var outcome = "ok"
            var image: Data?
            let result: LunaNativeToolResult
            if crowded {
                result = LunaNativeToolResult(response: LunaNativeWire.toolFailure("Luna is still working on earlier requests."), approval: nil)
                outcome = "crowded"
            } else if call.attachesPhotos, self?.callPhotos.isEmpty ?? true {
                result = LunaNativeToolResult(response: LunaNativeWire.toolFailure(
                    "No photo was taken in this call yet. Take one with look first, then ask again."), approval: nil)
                outcome = "no_photo"
            } else if LunaNativeVoice.localTools.contains(call.name) {
                guard let self else { return }
                (result, image, outcome) = await self.runLocalTool(call)
            } else {
                do {
                    // Photos leave the phone only when Luna asked to attach them to this request,
                    // and go only to the user's own Hermes server.
                    var photoIDs: [String] = []
                    if call.attachesPhotos, let photos = self?.callPhotos.suffix(LunaNativeVoice.maxPhotos) {
                        for photo in photos { photoIDs.append(try await broker.uploadPhoto(callID: callID, jpeg: photo)) }
                    }
                    result = try await broker.runTool(callID: callID, call: call, photoIDs: photoIDs)
                }
                catch {
                    if Task.isCancelled { return } // Cancelled by Gemini; the bridge stops the run.
                    result = LunaNativeToolResult(response: LunaNativeWire.toolFailure(), approval: nil); outcome = "bridge_error"
                }
            }
            guard !Task.isCancelled, let self, generation == self.state.generation else { return }
            self.toolTasks[call.id] = nil; self.tools.removeAll { $0.id == call.id }
            do {
                try await socket.sendMessage(LunaNativeWire.toolResponse(id: call.id, name: call.name,
                                                                         response: result.response, jpeg: image))
            } catch {
                guard generation == self.state.generation else { return }
                self.fail(LunaNativeError.connection, reason: "tool_response_send", underlying: error); return
            }
            if let approval = result.approval {
                self.approval = approval; self.approvalShownAt = .now; outcome = "needs_approval"
                #if DEBUG
                // Self-test only: exercise the card path by declining. Never approves.
                if LunaSelfTest.flag("-LunaAutoDecline") {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(3))
                        self?.decideApproval(false)
                    }
                }
                #endif
            }
            self.trace("tool.responded", detail: "name=\(Self.toolLabel(call.name)) outcome=\(outcome) ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
        }
        tools.append(LunaToolActivity(id: call.id, name: call.name, request: call.request))
    }

    private func runLocalTool(_ call: LunaNativeToolCall) async -> (LunaNativeToolResult, Data?, String) {
        func result(_ data: Data) -> LunaNativeToolResult { LunaNativeToolResult(response: data, approval: nil) }
        switch call.name {
        case "save_contact":
            guard let draft = LunaContactDraft(arguments: call.arguments) else {
                return (result(LunaNativeWire.toolFailure(
                    "No name or company was given. Look at the card again or ask the user.")), nil, "contact_invalid")
            }
            contactDraft = draft
            return (result(LunaNativeWire.toolResult(
                "The contact card for \(draft.title) is on the user's phone. Tell them briefly to check it and tap Done to save; it is not saved yet.")),
                nil, "contact")
        case "look", "record_video": break
        default:
            return (result(LunaNativeWire.toolFailure("That tool is not available in this call.")), nil, "unknown_tool")
        }
        guard let localTools else {
            return (result(LunaNativeWire.toolFailure("The glasses camera is not available in this call.")), nil, "no_camera")
        }
        do {
            if call.name == "look" {
                let jpeg = try await localTools.capturePhoto()
                let copy = Self.forModel(jpeg)
                callPhotos = Array((callPhotos + [copy]).suffix(LunaNativeVoice.maxPhotos))
                return (result(LunaNativeWire.toolResult(
                    "Photo taken with the user's glasses and saved to their Library; it is attached to this result. Describe what matters for their question. If no image is attached, say so instead of guessing.")),
                    copy, "photo")
            }
            try await localTools.recordVideo()
            return (result(LunaNativeWire.toolResult(
                "Recorded a six-second clip with the user's glasses and saved it to their Library on the phone. You cannot see the clip; if they want it described, offer to look instead.")),
                nil, "video")
        } catch {
            // Fixed code plus the error's type/case only (e.g. GlassesServiceError.notConnected).
            let code = (error as? LunaCameraError)?.code ?? "unknown"
            let message = switch code {
            case "camera_off_in_settings": "The user has turned off camera use during calls in Settings. Tell them; do not retry."
            case "glasses_not_worn": "The user is not wearing the glasses right now. Ask them to put them on, then look again."
            case "glasses_folded": "The user's glasses are folded. Ask them to open and wear them, then look again."
            case "glasses_too_hot": "The glasses are too hot to use the camera. Tell the user to give them a few minutes; do not retry now."
            default: "The glasses camera could not do that. Check that the glasses are on, connected and unfolded."
            }
            return (result(LunaNativeWire.toolFailure(message)), nil, "camera_error:\(code)")
        }
    }

    /// The image Luna's model sees. Glasses frames (720 × 1280) and stills (1080 × 1440) go
    /// as they are, so small text stays readable; anything larger is scaled to 1440 px.
    /// The renderer scale is pinned to 1: the default (the screen's 3×) would upscale the image.
    static func forModel(_ jpeg: Data) -> Data {
        guard let image = UIImage(data: jpeg) else { return jpeg }
        let longest = max(image.size.width, image.size.height) * image.scale
        if longest <= 1440, jpeg.count <= 700_000 { return jpeg }
        let scale = min(1, 1440 / longest)
        let size = CGSize(width: (image.size.width * image.scale * scale).rounded(),
                          height: (image.size.height * image.scale * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.85) ?? jpeg
    }

    private static func toolLabel(_ name: String) -> String {
        name == LunaNativeVoice.toolName || LunaNativeVoice.localTools.contains(name) ? name : "unknown"
    }

    /// The user's tap on the approval card. The result (or the next card) comes back and
    /// is handed to Luna to say; the voice model itself can never approve.
    func decideApproval(_ approve: Bool) {
        guard let approval, let callID, let socket, !approvalBusy else { return }
        approvalBusy = true
        let generation = state.generation
        trace("approval.decided", detail: "approve=\(approve)")
        Task { [weak self, broker] in
            // Speak at once: carrying out the action takes seconds, and silence after a
            // tap sounds like nothing happened (2026-10-31).
            let now = approve
                ? "The user just tapped Approve for: \(approval.summary). It is being carried out now. Say only a very short acknowledgement, such as 'Okay, sending it now.'"
                : "The user just tapped Decline for: \(approval.summary). Say only a very short acknowledgement, such as 'Okay, I won't.'"
            try? await socket.sendMessage(LunaNativeWire.text("[Update from Luna's back office] " + now))
            let result = try? await broker.decide(callID: callID, approvalID: approval.id, approve: approve)
            guard let self, generation == self.state.generation else { return }
            self.approvalBusy = false
            self.approval = result?.approval
            self.approvalShownAt = result?.approval == nil ? nil : .now
            var body = ""
            if let result, let object = try? JSONSerialization.jsonObject(with: result.response) as? [String: Any] {
                body = (object["result"] as? String) ?? (object["error"] as? String) ?? ""
            }
            let note = result == nil
                ? "The user tapped \(approve ? "Approve" : "Decline"), but the back office could not be reached. Tell them briefly."
                : "The user tapped \(approve ? "Approve" : "Decline") on their phone. Back office result: \(body) "
                    + "You already acknowledged the tap: now say only the outcome, in one short sentence."
            try? await socket.sendMessage(LunaNativeWire.text("[Update from Luna's back office] " + note))
            self.actions.append(LunaCallAction(summary: approval.summary, approved: approve))
            self.trace("approval.result", detail: "ok=\(result != nil) next=\(result?.approval != nil)")
        }
    }

    /// The user closed Apple's new-contact sheet or dismissed the card. Luna hears the
    /// outcome if the call is still live; nothing about the contact is traced.
    func finishContact(saved: Bool) {
        guard let draft = contactDraft else { return }
        contactDraft = nil
        actions.append(LunaCallAction(summary: "Save contact: \(draft.title)", approved: saved))
        trace("contact.finished", detail: "saved=\(saved)")
        guard let socket, [.listening, .responding, .speaking].contains(state.phase) else { return }
        let note = saved
            ? "The user saved the contact \(draft.title) on their phone. Say only a very short confirmation."
            : "The user closed the contact card for \(draft.title) without saving it. Acknowledge in a few words."
        Task { try? await socket.sendMessage(LunaNativeWire.text("[Update from Luna's phone] " + note)) }
    }

    /// Whether Luna's reply actually played (2026-11-07: replies stopped logging
    /// playback_complete). Counts, engine/player state and the output port type only.
    private func tracePlayback(generation: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, generation == self.state.generation else { return }
            let output = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+")
            self.trace("audio.playback", detail: "scheduled=\(self.scheduledBuffers) played=\(self.playedBuffers) "
                + "player=\(self.player?.isPlaying == true) engine=\(self.engine?.isRunning == true) "
                + "phase=\(self.state.phase.rawValue) out=\(output)")
        }
    }

    /// Converts glasses/iPhone input to 16 kHz PCM chunks for the socket.
    private func installInputTap(on engine: AVAudioEngine, format: AVAudioFormat, generation: UUID) throws {
        guard let gate, let continuation = outbound else { throw LunaNativeError.connection }
        let chunkProbe = NativeInputProbe()
        let tap = try HermesPCM16KAudioTap(inputFormat: format, chunkHandler: { [weak self] chunk in
            if chunkProbe.firstChunk() {
                Task { @MainActor [weak self] in
                    guard let self, generation == self.state.generation else { return }
                    self.trace("audio.first_chunk", detail: "bytes=\(chunk.count) muted=\(gate.isMuted)")
                }
            }
            guard !gate.isMuted else { return }
            if case .dropped = continuation.yield(.audio(chunk)) {
                Task { @MainActor [weak self] in
                    guard let self, generation == self.state.generation else { return }
                    self.droppedAudioChunks += 1
                    if self.droppedAudioChunks == 1 || self.droppedAudioChunks.isMultiple(of: 50) {
                        self.trace("audio.dropped", detail: "chunks=\(self.droppedAudioChunks)")
                    }
                }
            }
        }, levelHandler: { [weak self] level in
            guard !gate.isMuted else { return }
            Task { @MainActor [weak self] in
                guard let self, generation == self.state.generation else { return }
                self.inputLevel = level
                self.levelPeak = max(self.levelPeak, level)
                if level > 0 { self.heardSound = true }
                if level > 0.10 { self.lastSpeechAt = ProcessInfo.processInfo.systemUptime }
            }
        })
        audioTap = tap
        tapFormat = format
        let probe = NativeInputProbe()
        inputProbe = probe
        let block = tap.tapBlock(onFirstBuffer: { @Sendable [weak self] frames in
            _ = probe.firstBuffer()
            Task { @MainActor [weak self] in
                guard let self, generation == self.state.generation else { return }
                self.trace("audio.first_tap", detail: "frames=\(frames)")
            }
        })
        engine.inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(max(256, format.sampleRate / 10)),
                                    format: format, block: block)
        hasTap = true
        armInputWatchdog(generation: generation)
        armSilenceWatchdog(generation: generation)
    }

    /// The glasses mic can deliver pure digital silence: after the HFP route bounced and
    /// came back, every level read 0.000 and Luna heard nothing (2026-11-02). A working
    /// mic always picks up some noise while Luna is quiet (in the logs, exact zeros only
    /// fell while she was speaking), so 6 s of exact zeros outside her playback means the
    /// link is dead (a fresh glasses link read zeros for ~3 s and then recovered, 2026-11-07). The audio session is reset once; if it is still silent, the call
    /// fails with a plain message instead of listening to nothing.
    private func armSilenceWatchdog(generation: UUID) {
        heardSound = false
        silenceWatchdog?.cancel()
        silenceWatchdog = Task { [weak self] in
            var quiet = 0.0
            while quiet < 6 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, generation == self.state.generation else { return }
                if self.heardSound { return }
                let playing = ProcessInfo.processInfo.systemUptime < self.speechPlaysUntil + 0.3
                if !playing, self.gate?.isMuted == false { quiet += 0.5 }
            }
            guard let self, generation == self.state.generation else { return }
            self.trace("audio.silent_input", detail: "resets=\(self.silentInputResets) hfp=\(self.requiresBluetooth)")
            if self.silentInputResets > 0 { self.fail(LunaNativeError.microphoneSilent, reason: "silent_input") }
            else { self.resetAudioSession(generation: generation) }
        }
    }

    /// Deactivates and reactivates the audio session so iOS sets the Bluetooth link up
    /// again, then restarts the engine with a fresh tap.
    private func resetAudioSession(generation: UUID) {
        guard let engine else { return }
        silentInputResets += 1
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setActive(false)
            try audio.setActive(true)
            preferGlassesInput(audio)
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw LunaNativeError.microphoneSilent }
            try installInputTap(on: engine, format: format, generation: generation)
            engine.prepare(); try engine.start(); restartPlayers()
            requiresBluetooth = audio.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
            trace("audio.session_reset", detail: "rate=\(Int(format.sampleRate)) hfp=\(requiresBluetooth)")
        } catch {
            fail(LunaNativeError.microphoneSilent, reason: "session_reset", underlying: error)
        }
    }

    /// The glasses route has shown an engine that runs while its tap delivers
    /// nothing (2026-10-30: 56 s of silence after a restart, no audio sent). If
    /// no buffer arrives within 1.5 s the tap is rebuilt once; if it is still
    /// silent the call fails with `no_input` rather than listening to nothing.
    private func armInputWatchdog(generation: UUID, rebuilt: Bool = false) {
        inputWatchdog?.cancel()
        inputWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, generation == self.state.generation,
                  let probe = self.inputProbe, !probe.hasBuffer else { return }
            self.trace("audio.no_input", detail: "rebuilt=\(rebuilt) running=\(self.engine?.isRunning == true)")
            guard !rebuilt else { self.fail(LunaNativeError.connection, reason: "no_input"); return }
            self.rebuildInput(generation: generation)
        }
    }

    private func rebuildInput(generation: UUID) {
        guard let engine else { return }
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        let format = engine.inputNode.outputFormat(forBus: 0)
        do {
            guard format.sampleRate > 0, format.channelCount > 0 else { throw LunaNativeError.connection }
            try installInputTap(on: engine, format: format, generation: generation)
            inputWatchdog?.cancel()
            engine.prepare(); try engine.start(); restartPlayers()
            armInputWatchdog(generation: generation, rebuilt: true)
            trace("audio.input_rebuilt", detail: "rate=\(Int(format.sampleRate)) channels=\(format.channelCount)")
        } catch {
            fail(LunaNativeError.connection, reason: "input_rebuild", underlying: error)
        }
    }

    /// After the engine restarts, a player still reports `isPlaying` but no longer renders:
    /// 2026-11-07, 10 reply buffers scheduled, 0 played, player and engine "running", and
    /// Luna was silent after every route-change restart. Stop and play rebuilds its timeline.
    private func restartPlayers() {
        player?.stop(); player?.play()
        cuePlayer?.stop(); cuePlayer?.play()
    }

    /// Restarts the engine after `AVAudioEngineConfigurationChange`.
    ///
    /// With voice processing on a Bluetooth HFP route, iOS reconfigures the I/O
    /// unit roughly 350 ms after the first start and stops the engine. Measured
    /// on the glasses 2026-10-30: every native call ended here with
    /// `reason=engine_config_change`. The call survives by restarting in place;
    /// the tap is rebuilt only when the input format actually changed. Voice
    /// processing is never toggled here — doing so mid-reconfiguration can
    /// deadlock AudioDSP. Three restarts within ten seconds means the route is
    /// genuinely unstable, so the call fails rather than looping.
    private func recoverEngine(generation: UUID) {
        guard let engine, generation == state.generation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        engineRestarts = engineRestarts.filter { now - $0 < 10 } + [now]
        guard engineRestarts.count <= 3 else {
            fail(LunaNativeError.connection, reason: "engine_restart_loop"); return
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail(LunaNativeError.connection, reason: "engine_config_no_input"); return
        }
        let formatChanged = tapFormat.map { $0.sampleRate != format.sampleRate || $0.channelCount != format.channelCount } ?? true
        do {
            // Always rebuild the tap: keeping it when the format was unchanged left
            // a running engine whose tap never delivered (glasses, 2026-10-30).
            if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
            try installInputTap(on: engine, format: format, generation: generation)
            engine.prepare(); try engine.start(); restartPlayers()
            requiresBluetooth = AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
            trace("audio.engine_restarted", detail: "format_changed=\(formatChanged) rate=\(Int(format.sampleRate)) hfp=\(requiresBluetooth)")
        } catch {
            fail(LunaNativeError.connection, reason: "engine_restart", underlying: error)
        }
    }

    private func play(_ data: Data) throws {
        if cuePlayer?.isPlaying == true { cuePlayer?.stop() }
        let now = ProcessInfo.processInfo.systemUptime
        speechPlaysUntil = max(speechPlaysUntil, now) + Double(data.count / 2) / 24_000
        guard let format = playbackFormat, let player,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let samples = buffer.floatChannelData?.pointee else { throw LunaNativeError.invalidResponse }
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { bytes in
            let octets = bytes.bindMemory(to: UInt8.self)
            for index in 0..<Int(buffer.frameLength) {
                samples[index] = Float(Int16(bitPattern: UInt16(octets[index * 2]) | UInt16(octets[index * 2 + 1]) << 8)) / 32768
            }
        }
        let playback = state.playbackGeneration
        let generation = state.generation
        // dataConsumed is too early: buffers can still be audible after that callback.
        // @Sendable: runs on an AVFoundation queue, so it must not inherit main-actor isolation.
        scheduledBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.state.generation else { return }
                self.playedBuffers += 1
                guard playback == self.state.playbackGeneration else { return }
                self.state.played(bytes: data.count, generation: playback)
                if self.state.phase == .listening { self.trace("audio.playback_complete") }
            }
        }
        if !player.isPlaying { player.play() }
    }

    /// True while Luna's back office is working for the user: a delegated request or an
    /// approved action. Local look/record have their own on-screen progress.
    private var backOfficeWorking: Bool {
        approvalBusy || tools.contains { !LunaNativeVoice.localTools.contains($0.name) }
    }

    /// A soft cue on the glasses while the back office works and nobody is talking:
    /// first after 1.5 s of quiet, then every 2.5 s. Luna's voice stops it at once.
    private func startThinkingCue(generation: UUID) {
        thinkingTask?.cancel()
        thinkingTask = Task { [weak self] in
            var quietFor = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, generation == self.state.generation else { return }
                // Quiet means no speech either way, measured from the audio itself: while a
                // delegated request runs, the call phase stays `.speaking` after Luna's
                // "let me check" (self-test, 2026-10-31).
                let now = ProcessInfo.processInfo.systemUptime
                let quiet = now > self.speechPlaysUntil + 0.3 && now - self.lastSpeechAt > 1
                guard self.backOfficeWorking, quiet, ![.idle, .connecting, .failed, .ended].contains(self.state.phase)
                else { quietFor = 0; continue }
                quietFor += 0.5
                if quietFor >= 1.5, (quietFor - 1.5).truncatingRemainder(dividingBy: 2.5) == 0 {
                    if quietFor == 1.5 { self.trace("thinking.cue") }
                    self.playThinkingCue()
                }
            }
        }
    }

    private func playThinkingCue() { playCue(thinkingCue) }

    private func playCue(_ cue: AVAudioPCMBuffer?) {
        guard let cuePlayer, let cue, engine?.isRunning == true else { return }
        if !cuePlayer.isPlaying { cuePlayer.play() }
        cuePlayer.scheduleBuffer(cue, completionHandler: nil)
    }

    /// Two quiet, rounded notes (~0.45 s): reads as "still on it", not as an alert.
    private static func makeThinkingCue(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        makeCue(format: format, notes: [(0, 523.25), (0.16, 659.25)], seconds: 0.45)
    }

    /// Soft bell-like notes (fast attack, gentle decay), quiet under Luna's voice.
    private static func makeCue(format: AVAudioFormat, notes: [(start: Double, hz: Double)],
                                seconds: Double) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let length = AVAudioFrameCount(rate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
              let samples = buffer.floatChannelData?.pointee else { return nil }
        buffer.frameLength = length
        for index in 0..<Int(length) {
            let t = Double(index) / rate
            var value = 0.0
            for note in notes where t >= note.start {
                let local = t - note.start
                let envelope = min(1, local / 0.012) * exp(-local * 9)
                value += sin(2 * .pi * note.hz * local) * envelope
            }
            samples[index] = Float(value * 0.05)
        }
        return buffer
    }

    func toggleMute() {
        guard [.listening, .responding, .speaking].contains(state.phase) else { return }
        state.mute(!state.isMuted); gate?.setMuted(state.isMuted)
        if state.isMuted {
            inputLevel = 0
            outbound?.yield(.endAudio)
        }
    }

    func interrupt() {
        state.interrupt(); stopPlayback(); turnDeadline?.cancel()
        firstOutputInTurn = true
        // Automatic Gemini VAD cancels generation when speech resumes. The button
        // immediately silences playback and drops the old output through turnComplete.
        trace("playback.interrupted")
    }

    private func stopPlayback() {
        player?.stop(); player?.reset(); speechPlaysUntil = 0
        if engine?.isRunning == true { player?.play() }
    }

    private func armTurnDeadline(generation: UUID) {
        turnDeadline?.cancel()
        turnDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, generation == self.state.generation else { return }
            self.fail(LunaNativeError.connection, reason: "turn_deadline")
        }
    }

    private func installObservers(generation: UUID) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor [weak self] in
                guard began, let self, generation == self.state.generation else { return }
                self.fail(LunaNativeError.connection, reason: "audio_interruption")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self, generation == self.state.generation else { return }
                let audio = AVAudioSession.sharedInstance()
                var stillBluetooth = audio.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
                let code = "\(reason.map(String.init) ?? "nil")_bt\(stillBluetooth ? 1 : 0)"
                self.trace("audio.route_change", detail: "reason=\(code)")
                guard self.requiresBluetooth, !stillBluetooth else { return }
                // The glasses mic left the route. Ask for it back once before giving up:
                // a transient re-route is recoverable, a powered-off pair is not.
                self.preferGlassesInput(audio)
                stillBluetooth = audio.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
                if !stillBluetooth { self.fail(LunaNativeError.connection, reason: "route_lost_\(code)") }
                else { self.trace("audio.route_restored") }
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.state.generation, self.engine?.isRunning == false else { return }
                self.recoverEngine(generation: generation)
            }
        })
    }

    /// Activates the call's audio session and, when a Bluetooth headset microphone is
    /// available but not yet the input, waits up to 3 s for it to come up.
    private func prepareGlassesRoute() async {
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try audio.setActive(true)
        } catch { return }
        preferGlassesInput(audio)
        guard audio.availableInputs?.contains(where: { $0.portType == .bluetoothHFP }) == true else { return }
        let started = ProcessInfo.processInfo.systemUptime
        var waited = false
        for attempt in 0..<30 {
            if audio.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) { break }
            waited = true
            if attempt == 15 { preferGlassesInput(audio) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if waited {
            let hfp = audio.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
            trace("audio.route_wait", detail: "ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) hfp=\(hfp)")
        }
    }

    private func preferGlassesInput(_ audio: AVAudioSession) {
        let inputs = audio.availableInputs ?? []
        let glasses = inputs.first { input in
            let name = input.portName.lowercased()
            return input.portType == .bluetoothHFP && (name.contains("meta") || name.contains("rayban") || name.contains("ray-ban") || name.contains("rb "))
        } ?? inputs.first { $0.portType == .bluetoothHFP }
        if let glasses { try? audio.setPreferredInput(glasses) }
    }

    func end() { state.end(); cleanup(); trace("call.ended") }

    /// A tapped shortcut becomes a request in the conversation (e.g. Look). Sent once
    /// the call is connected; Luna then decides which tool to use.
    func ask(_ text: String) {
        guard let socket, [.listening, .responding, .speaking].contains(state.phase) else {
            if [.idle, .connecting].contains(state.phase) { pendingAsk = text }
            return
        }
        trace("ask.sent")
        Task { try? await socket.sendMessage(LunaNativeWire.text(text)) }
    }

    /// Ends the call as failed.
    ///
    /// `reason` names the code path that gave up. Eleven call sites used to end in
    /// an identical, reason-free "call.failed" trace, most with the same generic
    /// `.connection` error, so a device failure could not be told apart from a
    /// route change, an engine reconfiguration or a provider error. Reasons are
    /// fixed strings chosen in code. Never log provider bodies, tokens or exception
    /// strings; the error is recorded as its case name or its domain and numeric code.
    private func fail(_ error: Error, reason: String, underlying: Error? = nil) {
        state.fail()
        let cause = Self.lastingCause(of: underlying ?? error, reason: reason)
        retryable = cause == nil
        errorMessage = (cause ?? error as? LunaNativeError ?? .connection).errorDescription
        cleanup(); trace("call.failed", detail: "reason=\(reason) error=\(Self.describe(underlying ?? error))")
    }

    /// Failures an immediate retry cannot fix (2026-11-01 logs): the server name does not
    /// resolve (no route to the server), or iOS refuses the microphone ('!rec') because a phone call,
    /// Siri or another app holds it or the app is in the background.
    private static func lastingCause(of error: Error, reason: String) -> LunaNativeError? {
        if reason == "audio_interruption" { return .microphoneBusy }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, [NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                                           NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet].contains(ns.code) {
            return .serverUnreachable
        }
        let busy: [AVAudioSession.ErrorCode] = [.cannotStartRecording, .insufficientPriority, .cannotInterruptOthers]
        if ns.domain == "com.apple.coreaudio.avfaudio", busy.map(\.rawValue).contains(ns.code) { return .microphoneBusy }
        return nil
    }

    private static func describe(_ error: Error) -> String {
        if let native = error as? LunaNativeError { return "native.\(native)" }
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }

    /// Fixed event names for traces; never the payload (audio or transcript text).
    private static func label(_ event: LunaNativeEvent) -> String {
        switch event {
        case .ready: "ready"
        case .inputTranscript: "input_transcript"
        case .outputTranscript: "output_transcript"
        case .audio: "audio"
        case .interrupted: "interrupted"
        case .generationComplete: "generation_complete"
        case .turnComplete: "turn_complete"
        case .usage: "usage"
        case .goAway: "go_away"
        case .failure: "provider_failure"
        case .toolCalls: "tool_calls"
        case .toolCancellation: "tool_cancellation"
        }
    }

    private func cleanup() {
        gate?.setMuted(true); outbound?.finish(); outbound = nil
        receiveTask?.cancel(); receiveTask = nil; sendTask?.cancel(); sendTask = nil
        setupDeadline?.cancel(); setupDeadline = nil; durationDeadline?.cancel(); durationDeadline = nil
        turnDeadline?.cancel(); turnDeadline = nil; writeDeadline?.cancel(); writeDeadline = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        thinkingTask?.cancel(); thinkingTask = nil; cuePlayer?.stop()
        player?.stop(); engine?.stop()
        toolTasks.values.forEach { $0.cancel() }; toolTasks = [:]; tools = []; pendingAsk = nil
        approval = nil; approvalBusy = false; approvalShownAt = nil
        if let localTools { Task { await localTools.endCall() } }
        inputWatchdog?.cancel(); inputWatchdog = nil; inputProbe = nil
        silenceWatchdog?.cancel(); silenceWatchdog = nil; silentInputResets = 0
        levelTrace?.cancel(); levelTrace = nil; levelPeak = 0; heardInTurn = false
        #if DEBUG
        if let micCapture, let directory = VoiceDiagnosticLog.fileURL?.deletingLastPathComponent() {
            try? micCapture.write(to: directory.appendingPathComponent("selftest-mic.pcm"))
            trace("selftest.mic_saved", detail: "bytes=\(micCapture.count)")
        }
        micCapture = nil
        #endif
        audioTap = nil; tapFormat = nil; engineRestarts = []
        player = nil; cuePlayer = nil; thinkingCue = nil; connectedCue = nil; engine = nil; playbackFormat = nil; gate = nil; inputLevel = 0
        if let socket { Task { await socket.close() } }; socket = nil
        if let callID {
            closingTask = Task {
                await broker.end(callID)
                if UserDefaults.standard.string(forKey: Self.openCallKey) == callID.uuidString {
                    UserDefaults.standard.removeObject(forKey: Self.openCallKey)
                }
            }
        }
        callID = nil; callPhotos = []
        if ownsAudio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            coordinator.release(.nativeVoice); ownsAudio = false
        }
    }

    private func trace(_ name: String, detail: String = "") {
        VoiceDiagnosticLog.record("native.\(name)", "elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)) \(detail)")
    }
}
