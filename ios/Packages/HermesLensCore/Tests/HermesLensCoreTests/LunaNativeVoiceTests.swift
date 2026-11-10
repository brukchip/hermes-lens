import Foundation
import Testing
@testable import HermesLensCore

private func wire(_ text: String) -> Data { Data(text.utf8) }
private let pcm = Data(repeating: 12, count: 960)

@Test func nativeGenerationAndTurnCompleteDoNotCutPlayback() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let id = state.generation
    state.receive(.outputTranscript("Hello "), generation: id)
    state.receive(.outputTranscript("there."), generation: id)
    let scheduled = state.receive(.audio(pcm), generation: id)
    #expect(scheduled)
    state.receive(.generationComplete, generation: id)
    state.receive(.turnComplete, generation: id)
    #expect(state.phase == .speaking)
    #expect(state.transcript == "Hello there.")
    state.played(bytes: pcm.count, generation: state.playbackGeneration)
    #expect(state.phase == .listening)
}

@Test func nativePlaybackDrainWaitsForProviderTurnBoundary() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    state.receive(.audio(pcm), generation: state.generation)
    state.played(bytes: pcm.count, generation: state.playbackGeneration)
    #expect(state.phase == .speaking)
    state.receive(.turnComplete, generation: state.generation)
    #expect(state.phase == .listening)
}

@Test func nativeInterruptRejectsLateOutputAndOldPlaybackCallbacks() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let id = state.generation
    state.receive(.outputTranscript("Partial"), generation: id)
    state.receive(.audio(pcm), generation: id)
    let oldPlayback = state.playbackGeneration
    state.interrupt()
    #expect(state.interrupted)
    let scheduled = state.receive(.audio(pcm), generation: id)
    #expect(!scheduled)
    state.receive(.outputTranscript(" unheard ending"), generation: id)
    #expect(state.transcript == "Partial")
    state.receive(.turnComplete, generation: id)
    state.receive(.audio(pcm), generation: id)
    state.played(bytes: pcm.count, generation: oldPlayback)
    #expect(state.queuedAudioBytes == pcm.count)
}

@Test func nativeServerBargeInAllowsNextResponse() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let id = state.generation
    state.receive(.audio(pcm), generation: id)
    state.receive(.interrupted, generation: id)
    #expect(state.queuedAudioBytes == 0)
    #expect(state.phase == .listening)
    let scheduled = state.receive(.audio(pcm), generation: id)
    #expect(scheduled)
}

@Test func nativeEndedGenerationCannotAffectNewCall() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let old = state.generation
    state.end(); state.begin(); state.connected()
    state.receive(.failure, generation: old)
    #expect(state.phase == .listening)
}

@Test func nativeBacklogFailsExplicitlyInsteadOfDroppingSpeech() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let id = state.generation
    let scheduled = state.receive(.audio(Data(repeating: 0, count: 1_440_002)), generation: id)
    #expect(!scheduled)
    #expect(state.phase == .failed)
    state.receive(.ready, generation: id)
    #expect(state.phase == .failed)
}

@Test func nativeParsesEveryPartAndDoesNotMistakeGenerationForPlayback() throws {
    let parts = #"{"serverContent":{"outputTranscription":{"text":"Hi "},"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQI="}},{"text":"unused"},{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AwQ="}}]},"generationComplete":true,"turnComplete":true}}"#
    #expect(try LunaNativeWire.decode(wire(parts)) == [
        .outputTranscript("Hi "), .audio(Data([1, 2])), .audio(Data([3, 4])), .generationComplete, .turnComplete
    ])
}

@Test func nativeCaptionsDropGeminiControlTokens() throws {
    let message = #"{"serverContent":{"inputTranscription":{"text":"Hi<ctrl46> Luna"},"outputTranscription":{"text":"<ctrl3>Hello there<ctrl46>"}}}"#
    #expect(try LunaNativeWire.decode(wire(message)) == [.inputTranscript("Hi Luna"), .outputTranscript("Hello there")])
    #expect(LunaNativeWire.cleanTranscript("Use <b>bold</b> and <ctrl>") == "Use <b>bold</b> and <ctrl>")
}

@Test func nativeRejectsMalformedAudioAndUnexpectedTools() throws {
    #expect(throws: (any Error).self) { try LunaNativeWire.decode(wire("not json")) }
    #expect(throws: (any Error).self) { try LunaNativeWire.decode(Data(repeating: 32, count: 1_048_577)) }
    #expect(throws: (any Error).self) {
        try LunaNativeWire.decode(wire(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQ=="}}]}}}"#))
    }
    // A tool call without an id cannot be answered, so it is malformed, not a silent no-op.
    #expect(throws: (any Error).self) { try LunaNativeWire.decode(wire(#"{"toolCall":{"functionCalls":[{"name":"delete"}]}}"#)) }
    #expect(throws: (any Error).self) { try LunaNativeWire.decode(wire(#"{"toolCall":{"functionCalls":[]}}"#)) }
    #expect(try LunaNativeWire.decode(wire(#"{"error":{"code":3}}"#)) == [.failure])
    #expect(try LunaNativeWire.decode(wire(#"{"serverContent":{"interrupted":true,"outputTranscription":{"text":"old text"}}}"#)) == [.interrupted])
}

@Test func nativeGrantRestrictsTokenTransportAndLifetime() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let formatter = ISO8601DateFormatter()
    var payload: [String: Any] = [
        "protocol": LunaNativeVoice.protocolName, "callID": UUID().uuidString,
        "token": "auth_tokens/fixture", "websocketURL": LunaNativeVoice.socket,
        "model": LunaNativeVoice.model, "maxSeconds": 540,
        "expiresAt": formatter.string(from: now.addingTimeInterval(540)),
        "newSessionExpiresAt": formatter.string(from: now.addingTimeInterval(60))
    ]
    let valid = try LunaNativeCall.decode(JSONSerialization.data(withJSONObject: payload), now: now)
    #expect(valid.socketRequest().url?.query == nil)
    #expect(valid.socketRequest().value(forHTTPHeaderField: "Authorization") == "Token auth_tokens/fixture")
    let setup = try JSONSerialization.jsonObject(with: valid.setupMessage()) as? [String: [String: String]]
    #expect(setup == ["setup": ["model": "models/\(LunaNativeVoice.model)"]])
    for endpoint in ["wss://evil.invalid/socket", LunaNativeVoice.socket + "?key=bad", LunaNativeVoice.socket + "#fragment"] {
        payload["websocketURL"] = endpoint
        #expect(throws: (any Error).self) { try LunaNativeCall.decode(JSONSerialization.data(withJSONObject: payload), now: now) }
    }
    payload["websocketURL"] = LunaNativeVoice.socket
    payload["model"] = "gemini-3.8-live"; payload["tools"] = true
    let delegating = try LunaNativeCall.decode(JSONSerialization.data(withJSONObject: payload), now: now)
    #expect(delegating.tools == true)
    #expect(try JSONSerialization.jsonObject(with: delegating.setupMessage()) as? [String: [String: String]]
            == ["setup": ["model": "models/gemini-3.8-live"]])
    payload["model"] = "gemini-unreviewed"
    #expect(throws: (any Error).self) { try LunaNativeCall.decode(JSONSerialization.data(withJSONObject: payload), now: now) }
    payload["model"] = LunaNativeVoice.model
    payload["expiresAt"] = formatter.string(from: now.addingTimeInterval(10000))
    #expect(throws: (any Error).self) { try LunaNativeCall.decode(JSONSerialization.data(withJSONObject: payload), now: now) }
}

@Test func nativeConfigRequiresCompatibleOptIn() throws {
    let voice = try JSONDecoder().decode(HermesLensConfiguration.Voice.self, from: wire(#"{"completeSentenceSilenceSeconds":0.8,"unfinishedSentenceSilenceSeconds":1.35,"playbackTailSeconds":0.35}"#))
    #expect(!voice.nativeAudioEnabled)
    #expect(voice.nativeAudioProtocol.isEmpty)
    #expect(LunaNativeVoice.protocolName != "luna.native.v1")
}

@Test func nativeFiftyTurnsUseSameCallGeneration() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let id = state.generation
    for _ in 0..<50 {
        state.receive(.inputTranscript("test"), generation: id)
        state.receive(.outputTranscript("Hello."), generation: id)
        let scheduled = state.receive(.audio(pcm), generation: id)
        #expect(scheduled)
        state.receive(.turnComplete, generation: id)
        state.played(bytes: pcm.count, generation: state.playbackGeneration)
        #expect(state.phase == .listening)
        #expect(state.generation == id)
    }
}

@Test func nativeAudioInputIsBoundedPCMAndMuteHasExplicitEndEvent() throws {
    #expect(throws: (any Error).self) { try LunaNativeWire.audio(Data([1])) }
    #expect(throws: (any Error).self) { try LunaNativeWire.audio(Data(repeating: 0, count: 3202)) }
    let body = try JSONSerialization.jsonObject(with: LunaNativeWire.audio(pcm)) as? [String: Any]
    #expect(body?["realtimeInput"] != nil)
    #expect(String(decoding: LunaNativeWire.audioEnd(), as: UTF8.self).contains("audioStreamEnd"))
}

@Test func nativeToolCallsAreDecodedForForwardingNotExecution() throws {
    let message = #"{"toolCall":{"functionCalls":[{"id":"fc-1","name":"ask_luna","args":{"request":"When is my next meeting?"}},{"id":"fc-2","name":"delete","args":{"path":"/"}}]}}"#
    #expect(try LunaNativeWire.decode(wire(message)) == [.toolCalls([
        LunaNativeToolCall(id: "fc-1", name: "ask_luna", request: "When is my next meeting?"),
        LunaNativeToolCall(id: "fc-2", name: "delete", request: nil, arguments: ["path": "/"]),
    ])])
    #expect(try LunaNativeWire.decode(wire(#"{"toolCallCancellation":{"ids":["fc-1"]}}"#)) == [.toolCancellation(["fc-1"])])
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    state.receive(.toolCalls([LunaNativeToolCall(id: "fc-1", name: "ask_luna", request: "x")]), generation: state.generation)
    #expect(state.phase == .listening)
}

@Test func nativeToolResponsePassesTheBridgeObjectThrough() throws {
    let bridge = Data(#"{"result":"At 3 PM.","scheduling":"WHEN_IDLE"}"#.utf8)
    let message = try LunaNativeWire.toolResponse(id: "fc-1", name: "ask_luna", response: bridge)
    let root = try #require(try JSONSerialization.jsonObject(with: message) as? [String: Any])
    let responses = try #require((root["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])
    #expect(responses.count == 1)
    #expect(responses[0]["id"] as? String == "fc-1")
    #expect((responses[0]["response"] as? [String: Any])?["scheduling"] as? String == "WHEN_IDLE")
    #expect(throws: (any Error).self) { try LunaNativeWire.toolResponse(id: "x", name: "y", response: Data("[1]".utf8)) }
    let failure = try #require(try JSONSerialization.jsonObject(with: LunaNativeWire.toolFailure()) as? [String: Any])
    #expect(failure["error"] is String)
}

@Test func nativeToolResultCarriesAnApprovalCardOnlyWhenWellFormed() throws {
    let id = UUID()
    let plain = try LunaNativeToolResult.decode(Data(#"{"response":{"result":"At 3 PM.","scheduling":"WHEN_IDLE"}}"#.utf8))
    #expect(plain.approval == nil)
    let carded = try LunaNativeToolResult.decode(Data("""
    {"response":{"result":"Needs approval"},"approval":{"id":"\(id.uuidString)","summary":"Send a message to Sam"}}
    """.utf8))
    #expect(carded.approval == LunaNativeToolResult.Approval(id: id, summary: "Send a message to Sam"))
    let detailed = try LunaNativeToolResult.decode(Data("""
    {"response":{"result":"Needs approval"},"approval":{"id":"\(id.uuidString)","summary":"Delete in root path","detail":"rm -rf /srv/old","risky":true}}
    """.utf8))
    #expect(detailed.approval?.detail == "rm -rf /srv/old" && detailed.approval?.risky == true)
    #expect(throws: (any Error).self) {
        try LunaNativeToolResult.decode(Data(#"{"response":{"result":"x"},"approval":{"id":"nope","summary":"x"}}"#.utf8))
    }
    #expect(throws: (any Error).self) { try LunaNativeToolResult.decode(Data(#"{"nothing":true}"#.utf8)) }
    #expect(LunaNativeVoice.localTools == ["look", "record_video", "save_contact"])
}

@Test func nativeLookCarriesItsPhotoInsideTheFunctionResponse() throws {
    let message = try LunaNativeWire.toolResponse(id: "fc-9", name: "look", response: LunaNativeWire.toolResult("Photo taken."),
                                                  jpeg: Data([0xFF, 0xD8, 0xFF]))
    let root = try #require(try JSONSerialization.jsonObject(with: message) as? [String: Any])
    let response = try #require(((root["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])?.first)
    let inline = (response["parts"] as? [[String: Any]])?.first?["inlineData"] as? [String: String]
    #expect(inline?["mimeType"] == "image/jpeg" && inline?["data"] == "/9j/")
    #expect(throws: (any Error).self) {
        try LunaNativeWire.toolResponse(id: "x", name: "look", response: LunaNativeWire.toolResult("x"), jpeg: Data(count: 700_001))
    }
    let text = try JSONSerialization.jsonObject(with: LunaNativeWire.text(String(repeating: "a", count: 5000))) as? [String: [String: String]]
    #expect(text?["realtimeInput"]?["text"]?.count == 2_000)
}

@Test func nativeHeardTextShowsTheCurrentUtteranceOnly() throws {
    #expect(try LunaNativeWire.decode(wire(#"{"serverContent":{"inputTranscription":{"text":"How did "}}}"#)) == [.inputTranscript("How did ")])
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let id = state.generation
    state.receive(.inputTranscript("How did "), generation: id)
    state.receive(.inputTranscript("the launch go?"), generation: id)
    #expect(state.heard == "How did the launch go?")
    state.receive(.outputTranscript("Sales were up."), generation: id)
    #expect(state.heard == "How did the launch go?") // still shown while Luna answers
    state.receive(.turnComplete, generation: id)
    state.receive(.inputTranscript("Thanks"), generation: id)
    #expect(state.heard == "Thanks") // a new turn starts fresh
}

@Test func saveContactCallsKeepOnlyShortStringFields() throws {
    let long = String(repeating: "x", count: 501)
    let message = #"{"toolCall":{"functionCalls":[{"id":"fc-3","name":"save_contact","args":{"name":"Alex Morgan","phone":"+1 555 010 0000","company":"Acme","fax":7,"notes":"\#(long)"}}]}}"#
    #expect(try LunaNativeWire.decode(wire(message)) == [.toolCalls([
        LunaNativeToolCall(id: "fc-3", name: "save_contact", request: nil,
                           arguments: ["name": "Alex Morgan", "phone": "+1 555 010 0000", "company": "Acme"]),
    ])])
    #expect(LunaNativeVoice.localTools.contains("save_contact"))
}

@Test func attachPhotosIsReadAsABooleanOnlyForThatArgument() throws {
    let message = #"{"toolCall":{"functionCalls":[{"id":"fc-4","name":"ask_luna","args":{"request":"Keep these","attach_photos":true,"other":true}},{"id":"fc-5","name":"ask_luna","args":{"request":"Hi","attach_photos":false}}]}}"#
    guard case .toolCalls(let calls)? = try LunaNativeWire.decode(wire(message)).first else { Issue.record("no tool calls"); return }
    #expect(calls[0].attachesPhotos && calls[0].arguments == ["attach_photos": "true"])
    #expect(!calls[1].attachesPhotos)
    #expect(!LunaNativeToolCall(id: "x", name: "ask_luna", request: "Hi").attachesPhotos)
}

@Test func contactDraftNeedsANameOrCompanyAndTidiesFields() throws {
    #expect(LunaContactDraft(arguments: [:]) == nil)
    #expect(LunaContactDraft(arguments: ["name": "   ", "phone": "+251 911"]) == nil)
    let draft = try #require(LunaContactDraft(arguments: [
        "name": "  Alex\n Morgan ", "email": "not an email", "job_title": "Head of Sales", "company": "Acme",
    ]))
    #expect(draft.name == "Alex Morgan")
    #expect(draft.email == nil)
    #expect(draft.jobTitle == "Head of Sales")
    #expect(draft.title == "Alex Morgan")
    #expect(LunaContactDraft(arguments: ["company": "Acme", "email": "hi@acme.et"])?.title == "Acme")
    #expect(LunaContactDraft(arguments: ["company": "Acme", "email": "hi@acme.et"])?.email == "hi@acme.et")
}
