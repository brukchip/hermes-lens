import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LunaNativeVoice {
    public static let protocolName = "luna.native.v2"
    public static let endpoint = "v1/lens/realtime/calls"
    public static let model = "gemini-3.1-flash-live-preview"
    /// Models a server grant may name. The server chooses; the app only refuses unreviewed ones.
    public static let models: Set<String> = [model, "gemini-3.8-live"]
    /// The one tool a grant can lock in. Its calls are executed by the bridge, never on the phone.
    public static let toolName = "ask_luna"
    public static let toolEndpoint = "v1/lens/native/tools"
    public static let approvalEndpoint = "v1/lens/native/approvals"
    /// Tools the grant declares that run on the phone (glasses camera, contacts), never on the bridge.
    public static let localTools: Set<String> = ["look", "record_video", "save_contact"]
    public static let socket = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"
}

public struct LunaNativeCall: Decodable, Sendable {
    public let protocolName: String
    public let callID: UUID
    public let token: String
    public let websocketURL: URL
    public let model: String
    public let expiresAt: Date
    public let newSessionExpiresAt: Date
    public let maxSeconds: Int
    /// True when the grant locks in `ask_luna`, i.e. Luna's back office is reachable in this call.
    public let tools: Bool?
    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol", callID, token, websocketURL, model, expiresAt, newSessionExpiresAt, maxSeconds, tools
    }

    public static func decode(_ data: Data, now: Date = .now) throws -> Self {
        guard data.count <= 64 * 1024 else { throw LunaNativeError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let text = try value.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw LunaNativeError.invalidResponse }
            return date
        }
        guard let grant = try? decoder.decode(Self.self, from: data),
              grant.protocolName == LunaNativeVoice.protocolName,
              LunaNativeVoice.models.contains(grant.model),
              grant.websocketURL.absoluteString == LunaNativeVoice.socket,
              grant.token.hasPrefix("auth_tokens/"), grant.token.utf8.count <= 16_384,
              !grant.token.contains(where: { $0.isWhitespace }),
              grant.newSessionExpiresAt > now,
              grant.newSessionExpiresAt.timeIntervalSince(now) <= 90,
              grant.expiresAt > grant.newSessionExpiresAt,
              grant.expiresAt.timeIntervalSince(now) <= 600,
              (60...540).contains(grant.maxSeconds) else { throw LunaNativeError.invalidResponse }
        return grant
    }

    public func socketRequest() -> URLRequest {
        var request = URLRequest(url: websocketURL)
        // Keep the ephemeral token out of URLs, crash descriptions and proxy logs.
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func setupMessage() throws -> Data {
        // All audio/model/persona/tool constraints are locked by the server's grant.
        try JSONSerialization.data(withJSONObject: ["setup": ["model": "models/\(model)"]])
    }
}

public enum LunaNativeError: LocalizedError, Sendable {
    case unavailable, connection, invalidResponse, activeCall, microphone, usageLimit, audioBacklog
    /// Retrying at once cannot help: the server is unreachable or iOS will not give the microphone.
    case serverUnreachable, microphoneBusy
    /// The microphone delivered pure digital silence, even after the audio was reset.
    case microphoneSilent
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Live voice is not activated on the server yet."
        case .activeCall: "Another live call is still closing. Please wait a moment and reconnect."
        case .microphone: "Allow microphone access in iPhone Settings to talk to Luna."
        case .connection: "The live connection was interrupted. Reconnect to continue."
        case .invalidResponse: "Luna could not establish a compatible live connection."
        case .usageLimit: "The live voice usage limit has been reached. Please try again later."
        case .audioBacklog: "The connection could not keep up with the audio. Reconnect to continue."
        case .serverUnreachable: "Luna's server can't be reached. Check your connection to your Hermes server, then try again."
        case .microphoneBusy: "A phone call, Siri or another app is using the microphone. Try again when it's free."
        case .microphoneSilent: "Luna can't hear the glasses microphone. Try again; if it keeps happening, switch the glasses off and on."
        }
    }
}

private final class NativeNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor LunaNativeBrokerClient {
    private let configuration: HermesEndpointConfiguration
    private let session: URLSession
    /// Tool requests wait on a Hermes run (bridge cap 60 s), longer than call setup allows.
    private let toolSession: URLSession
    private var pendingCloses = Set<UUID>()

    public init(configuration: HermesEndpointConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        let ephemeral = URLSessionConfiguration.ephemeral
        ephemeral.timeoutIntervalForRequest = 20
        ephemeral.timeoutIntervalForResource = 25
        ephemeral.urlCache = nil
        self.session = session ?? URLSession(configuration: ephemeral, delegate: NativeNoRedirect(), delegateQueue: nil)
        let tools = URLSessionConfiguration.ephemeral
        tools.timeoutIntervalForRequest = 75
        tools.timeoutIntervalForResource = 80
        tools.urlCache = nil
        toolSession = session ?? URLSession(configuration: tools, delegate: NativeNoRedirect(), delegateQueue: nil)
    }

    /// Forwards one Gemini tool call to the bridge; returns the tool response (and any approval card).
    /// Cancelling the calling task drops the request, and the bridge then stops the Hermes run.
    public func runTool(callID: UUID, call: LunaNativeToolCall) async throws -> LunaNativeToolResult {
        guard call.name == LunaNativeVoice.toolName, let text = call.request else {
            return LunaNativeToolResult(response: LunaNativeWire.toolFailure("That request is not available in this call."), approval: nil)
        }
        var request = identifiedRequest(path: LunaNativeVoice.toolEndpoint, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 75
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "callID": callID.uuidString.lowercased(), "id": call.id, "name": call.name, "args": ["request": text],
        ])
        let (data, response) = try await toolSession.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw LunaNativeError.connection
        }
        return try LunaNativeToolResult.decode(data)
    }

    /// The user's tap on an approval card. The server resumes (or denies) the parked Hermes run
    /// and returns its result — possibly another approval card.
    public func decide(callID: UUID, approvalID: UUID, approve: Bool) async throws -> LunaNativeToolResult {
        var request = identifiedRequest(path: LunaNativeVoice.approvalEndpoint, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 75
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "callID": callID.uuidString.lowercased(), "approvalID": approvalID.uuidString.lowercased(),
            "choice": approve ? "approve" : "decline",
        ])
        let (data, response) = try await toolSession.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw LunaNativeError.connection
        }
        return try LunaNativeToolResult.decode(data)
    }

    public func create(requestID: UUID) async throws -> LunaNativeCall {
        // A failed disconnect must be retried before allocating a replacement call.
        for id in pendingCloses { await end(id) }
        guard pendingCloses.isEmpty else { throw LunaNativeError.connection }
        var request = identifiedRequest(path: LunaNativeVoice.endpoint, method: "POST", requestID: requestID)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["protocol": LunaNativeVoice.protocolName])
        let data: Data
        do { data = try await perform(request) }
        catch let error as URLError where [.networkConnectionLost, .timedOut].contains(error.code) {
            // One bounded retry, with the SAME idempotency key. No audio replay.
            try await Task.sleep(for: .milliseconds(250))
            data = try await perform(request)
        }
        return try LunaNativeCall.decode(data)
    }

    public func end(_ callID: UUID) async {
        pendingCloses.insert(callID)
        var request = identifiedRequest(path: "\(LunaNativeVoice.endpoint)/\(callID)", method: "DELETE")
        request.timeoutInterval = 8
        do {
            let (_, response) = try await session.data(for: request)
            if let response = response as? HTTPURLResponse,
               (200..<300).contains(response.statusCode) || response.statusCode == 404 {
                pendingCloses.remove(callID)
            }
        } catch { /* Retry on the next explicit connection, never log credentials. */ }
    }

    private func identifiedRequest(path: String, method: String, requestID: UUID = UUID()) -> URLRequest {
        var request = URLRequest(url: configuration.url(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.deviceID.uuidString, forHTTPHeaderField: "X-Hermes-Device-ID")
        request.setValue(configuration.sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
        request.setValue(requestID.uuidString, forHTTPHeaderField: "Idempotency-Key")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LunaNativeError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return data
        case 409: throw LunaNativeError.activeCall
        case 429: throw LunaNativeError.usageLimit
        case 503:
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = body?["error"] as? [String: Any]
            if error?["code"] as? String == "native_voice_unavailable" { throw LunaNativeError.unavailable }
            throw LunaNativeError.connection
        default: throw LunaNativeError.connection
        }
    }
}

public enum LunaNativeEvent: Equatable, Sendable {
    case ready, outputTranscript(String), audio(Data), interrupted, generationComplete, turnComplete
    /// What the user said, as Gemini transcribes it. Shown on screen during the call only:
    /// never logged, traced or saved.
    case inputTranscript(String)
    case usage(input: Int, output: Int), goAway, failure
    /// Gemini asks the back office. Forwarded to the bridge; never executed on the phone.
    case toolCalls([LunaNativeToolCall])
    /// Gemini abandoned these calls (usually barge-in); their bridge requests are cancelled.
    case toolCancellation([String])
}

/// The bridge's answer to a delegated call: the tool response for Gemini and,
/// when Hermes wants to act, the approval card the user must tap.
public struct LunaNativeToolResult: Sendable {
    public struct Approval: Equatable, Sendable {
        public let id: UUID
        /// Hermes's reason, also spoken by Luna.
        public let summary: String
        /// The command or action itself, as Hermes will run it (credentials redacted).
        public let detail: String?
        /// Hermes's own safety check flagged this action.
        public let risky: Bool
        public init(id: UUID, summary: String, detail: String? = nil, risky: Bool = false) {
            self.id = id; self.summary = summary; self.detail = detail; self.risky = risky
        }
    }
    public let response: Data
    public let approval: Approval?

    public init(response: Data, approval: Approval?) {
        self.response = response; self.approval = approval
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32 * 1024,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = body["response"] as? [String: Any] else { throw LunaNativeError.connection }
        var approval: Approval?
        if let card = body["approval"] as? [String: Any] {
            guard let id = (card["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let summary = card["summary"] as? String, !summary.isEmpty, summary.count <= 400 else {
                throw LunaNativeError.invalidResponse
            }
            let detail = (card["detail"] as? String).flatMap { $0.isEmpty || $0 == summary ? nil : String($0.prefix(600)) }
            approval = Approval(id: id, summary: summary, detail: detail, risky: card["risky"] as? Bool ?? false)
        }
        return Self(response: try JSONSerialization.data(withJSONObject: inner), approval: approval)
    }
}

public struct LunaNativeToolCall: Equatable, Sendable {
    public let id: String
    public let name: String
    /// `args.request` when present (forwarded to the bridge for `ask_luna`).
    public let request: String?
    /// Other short string arguments, for local tools such as `save_contact`.
    /// Non-string values, long values and extra keys are dropped.
    public let arguments: [String: String]

    public init(id: String, name: String, request: String?, arguments: [String: String] = [:]) {
        self.id = id; self.name = name; self.request = request; self.arguments = arguments
    }
}

public enum LunaNativeWire {
    /// Microphone audio is sent in 100 ms chunks of 16 kHz mono PCM16.
    public static let inputChunkBytes = 3_200

    public static func audio(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= inputChunkBytes, data.count.isMultiple(of: 2) else {
            throw LunaNativeError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: [
            "realtimeInput": ["audio": ["data": data.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]],
        ])
    }

    public static func audioEnd() -> Data { Data(#"{"realtimeInput":{"audioStreamEnd":true}}"#.utf8) }

    /// `response` is the bridge's JSON object, passed through unchanged. A `look` result
    /// carries its photo inside the function response: measured 2026-10-30, Gemini read
    /// the image there 2/2, but 0/2 when the same JPEG went separately as a video frame
    /// (it answered before the frame was used, once inventing an invoice).
    public static func toolResponse(id: String, name: String, response: Data, jpeg: Data? = nil) throws -> Data {
        guard response.count <= 16 * 1024,
              let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw LunaNativeError.invalidResponse
        }
        var functionResponse: [String: Any] = ["id": id, "name": name, "response": object]
        if let jpeg {
            guard !jpeg.isEmpty, jpeg.count <= 700_000 else { throw LunaNativeError.invalidResponse }
            functionResponse["parts"] = [["inlineData": ["mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]]]
        }
        return try JSONSerialization.data(withJSONObject: ["toolResponse": ["functionResponses": [functionResponse]]])
    }

    /// A short note from the app into the conversation (e.g. an approved action's result).
    public static func text(_ text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["realtimeInput": ["text": String(text.prefix(2_000))]])
    }

    /// A local tool's result in the same shape the bridge uses.
    public static func toolResult(_ text: String, scheduling: String = "WHEN_IDLE") -> Data {
        (try? JSONSerialization.data(withJSONObject: ["result": text, "scheduling": scheduling])) ?? Data("{}".utf8)
    }

    /// Spoken by Luna when the back office cannot be reached; no provider detail.
    public static func toolFailure(_ text: String = "Luna's back office is not reachable right now.") -> Data {
        (try? JSONSerialization.data(withJSONObject: ["error": text, "scheduling": "WHEN_IDLE"])) ?? Data("{}".utf8)
    }

    /// Gemini sometimes leaks control tokens such as `<ctrl46>` into transcripts.
    /// They are never words, so captions drop them.
    static func cleanTranscript(_ text: String) -> String {
        guard text.contains("<ctrl") else { return text }
        return text.replacingOccurrences(of: #"<ctrl\d+>"#, with: "", options: .regularExpression)
    }

    public static func decode(_ data: Data) throws -> [LunaNativeEvent] {
        guard !data.isEmpty, data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LunaNativeError.invalidResponse
        }
        if root["error"] != nil { return [.failure] }
        var events: [LunaNativeEvent] = []
        if let toolCall = root["toolCall"] {
            guard let calls = (toolCall as? [String: Any])?["functionCalls"] as? [[String: Any]],
                  (1...8).contains(calls.count) else { throw LunaNativeError.invalidResponse }
            events.append(.toolCalls(try calls.map { call in
                guard let id = call["id"] as? String, (1...128).contains(id.utf8.count),
                      let name = call["name"] as? String, (1...64).contains(name.utf8.count) else {
                    throw LunaNativeError.invalidResponse
                }
                let args = call["args"] as? [String: Any] ?? [:]
                let request = args["request"] as? String
                var arguments: [String: String] = [:]
                for (key, value) in args where key != "request" && (1...32).contains(key.utf8.count) {
                    guard arguments.count < 12, let text = value as? String, text.utf8.count <= 500 else { continue }
                    arguments[key] = text
                }
                return LunaNativeToolCall(id: id, name: name, request: request.flatMap { $0.utf8.count <= 4_000 ? $0 : nil },
                                          arguments: arguments)
            }))
        }
        if let cancellation = root["toolCallCancellation"] as? [String: Any] {
            let ids = (cancellation["ids"] as? [String] ?? []).filter { (1...128).contains($0.utf8.count) }
            if !ids.isEmpty { events.append(.toolCancellation(Array(ids.prefix(8)))) }
        }
        if root["setupComplete"] != nil { events.append(.ready) }
        if root["goAway"] != nil { events.append(.goAway) }
        if let usage = root["usageMetadata"] as? [String: Any],
           let input = usage["promptTokenCount"] as? Int,
           let output = usage["responseTokenCount"] as? Int,
           (0...10_000_000).contains(input), (0...10_000_000).contains(output) {
            events.append(.usage(input: input, output: output))
        }
        guard let content = root["serverContent"] as? [String: Any] else { return events }
        if content["interrupted"] as? Bool == true {
            events.append(.interrupted)
            // Never replay parts bundled with an interruption acknowledgement.
            return events
        }
        if let transcript = content["inputTranscription"] as? [String: Any], let text = transcript["text"] as? String {
            guard text.utf8.count <= 64_000 else { throw LunaNativeError.invalidResponse }
            events.append(.inputTranscript(cleanTranscript(text))) // Display only; never logged or stored.
        }
        if let transcript = content["outputTranscription"] as? [String: Any], let text = transcript["text"] as? String {
            guard text.utf8.count <= 64_000 else { throw LunaNativeError.invalidResponse }
            events.append(.outputTranscript(cleanTranscript(text))) // Preserve spaces between deltas.
        }
        if let turn = content["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inline = part["inlineData"] as? [String: Any] else { continue }
                guard inline["mimeType"] as? String == "audio/pcm;rate=24000",
                      let encoded = inline["data"] as? String,
                      let audio = Data(base64Encoded: encoded), !audio.isEmpty,
                      audio.count <= 192_000, audio.count.isMultiple(of: 2) else {
                    throw LunaNativeError.invalidResponse
                }
                events.append(.audio(audio))
            }
        }
        if content["generationComplete"] as? Bool == true { events.append(.generationComplete) }
        if content["turnComplete"] as? Bool == true { events.append(.turnComplete) }
        return events
    }
}

/// Tracks provider completion separately from audio played on the device.
public struct LunaNativeCallState: Equatable, Sendable {
    public enum Phase: String, Sendable { case idle, connecting, listening, responding, speaking, failed, ended }
    public private(set) var phase: Phase = .idle
    public private(set) var transcript = ""
    /// The user's current utterance (display only). Starts fresh with each new turn.
    public private(set) var heard = ""
    private var userTurnOpen = false
    public private(set) var interrupted = false
    public private(set) var generation = UUID()
    public private(set) var playbackGeneration = UUID()
    public private(set) var isMuted = false
    public private(set) var responseInProgress = false
    public private(set) var queuedAudioBytes = 0
    public private(set) var suppressingOutput = false
    private var turnIsComplete = true
    public init() {}

    public mutating func begin() { self = Self(); phase = .connecting }
    public mutating func connected() { if phase == .connecting { phase = .listening } }
    public mutating func mute(_ muted: Bool) { isMuted = muted }
    public mutating func end() { generation = UUID(); clearPlayback(); phase = .ended }
    public mutating func fail() { generation = UUID(); clearPlayback(); phase = .failed }

    private mutating func clearPlayback() {
        playbackGeneration = UUID(); queuedAudioBytes = 0; responseInProgress = false
    }

    public mutating func interrupt(manual: Bool = true) {
        guard ![.ended, .failed].contains(phase) else { return }
        interrupted = responseInProgress || queuedAudioBytes > 0 || !transcript.isEmpty
        suppressingOutput = manual && !turnIsComplete
        clearPlayback()
        turnIsComplete = true
        phase = .listening
    }

    private mutating func startResponse() {
        if !responseInProgress {
            clearPlayback()
            responseInProgress = true; turnIsComplete = false; transcript = ""; interrupted = false
        }
    }

    /// Returns true only when this audio chunk should be scheduled for playback.
    @discardableResult public mutating func receive(_ event: LunaNativeEvent, generation id: UUID) -> Bool {
        guard id == generation, ![.ended, .failed].contains(phase) else { return false }
        switch event {
        case .ready: connected()
        case .inputTranscript(let text):
            if !userTurnOpen { heard = ""; userTurnOpen = true }
            heard = String((heard + text).suffix(4_000))
            if phase == .listening { phase = .responding }
        case .outputTranscript(let text):
            userTurnOpen = false
            guard !suppressingOutput else { return false }
            startResponse(); transcript = String((transcript + text).prefix(16_000))
            if phase != .speaking { phase = .responding }
        case .audio(let data):
            userTurnOpen = false
            guard !suppressingOutput else { return false }
            startResponse()
            guard queuedAudioBytes + data.count <= 1_440_000 else { fail(); return false }
            queuedAudioBytes += data.count
            phase = .speaking
            return true
        case .interrupted: interrupt(manual: false)
        case .generationComplete: break // Not an audible or complete-turn boundary.
        case .turnComplete:
            turnIsComplete = true; suppressingOutput = false
            if queuedAudioBytes == 0 { responseInProgress = false; phase = .listening }
        case .failure: fail()
        case .goAway, .usage, .toolCalls, .toolCancellation: break
        }
        return false
    }

    public mutating func played(bytes: Int, generation id: UUID) {
        guard id == playbackGeneration, ![.ended, .failed].contains(phase) else { return }
        queuedAudioBytes = max(0, queuedAudioBytes - bytes)
        if queuedAudioBytes == 0 && turnIsComplete { responseInProgress = false; phase = .listening }
    }
}
