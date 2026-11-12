import Foundation
import Testing
@testable import HermesLensCore

private typealias Entry = LunaTranscriptLog.Entry
private let pcm = Data(repeating: 12, count: 960)

@Test func aNewQuestionShowsBelowThePreviousAnswerUntilLunaReplies() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let id = state.generation
    state.receive(.inputTranscript("What time is it?"), generation: id)
    #expect(state.heardIsLatest)
    state.receive(.outputTranscript("It's three."), generation: id)
    #expect(!state.heardIsLatest)
    state.receive(.turnComplete, generation: id)
    // The next question: the old answer stays, and the question is the newer line.
    state.receive(.inputTranscript("And the date?"), generation: id)
    #expect(state.heard == "And the date?")
    #expect(state.transcript == "It's three.")
    #expect(state.heardIsLatest)
    state.receive(.outputTranscript("The ninth."), generation: id)
    #expect(state.transcript == "The ninth." && !state.heardIsLatest)
}

@Test func callLogKeepsSpokenOrderAcrossABargeIn() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let id = state.generation
    state.receive(.inputTranscript("Tell me a long story"), generation: id)
    state.receive(.outputTranscript("Once upon a time"), generation: id)
    state.receive(.audio(pcm), generation: id)
    // The user talks over Luna; the transcript of the new question can arrive before the
    // interruption itself.
    state.receive(.inputTranscript("Stop, "), generation: id)
    state.receive(.interrupted, generation: id)
    state.receive(.inputTranscript("what's the weather?"), generation: id)
    state.receive(.outputTranscript("Sunny."), generation: id)
    state.receive(.turnComplete, generation: id)
    #expect(state.log.entries == [
        Entry(speaker: .you, text: "Tell me a long story"),
        Entry(speaker: .luna, text: "Once upon a time"),
        Entry(speaker: .you, text: "Stop, what's the weather?"),
        Entry(speaker: .luna, text: "Sunny."),
    ])
}

@Test func callLogKeepsARepeatedYes() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let id = state.generation
    for answer in ["Shall I send it?", "Sent."] {
        state.receive(.inputTranscript("Yes"), generation: id)
        state.receive(.outputTranscript(answer), generation: id)
        state.receive(.turnComplete, generation: id)
    }
    #expect(state.log.entries.map(\.text) == ["Yes", "Shall I send it?", "Yes", "Sent."])
}

@Test func callLogIncludesTheUtteranceStillBeingSpokenAndSurvivesTheEnd() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let id = state.generation
    state.receive(.inputTranscript("Hello"), generation: id)
    #expect(state.log.entries == [Entry(speaker: .you, text: "Hello")])
    state.end()
    #expect(state.log.entries == [Entry(speaker: .you, text: "Hello")])
    state.begin()
    #expect(state.log.entries.isEmpty)
}

@Test func callLogDropsOutputSuppressedByAManualInterrupt() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let id = state.generation
    state.receive(.inputTranscript("Read it"), generation: id)
    state.receive(.outputTranscript("The first line"), generation: id)
    state.interrupt()
    state.receive(.outputTranscript(" unheard rest"), generation: id)
    state.receive(.turnComplete, generation: id)
    #expect(state.log.entries.map(\.text) == ["Read it", "The first line"])
}

@Test func transcriptLogBoundsItsSize() {
    var log = LunaTranscriptLog()
    for index in 0..<(LunaTranscriptLog.maxEntries + 10) {
        log.user("q\(index)"); log.luna("a\(index)")
    }
    #expect(log.entries.count == LunaTranscriptLog.maxEntries + 1) // + the open answer
    log.user(String(repeating: "x", count: 10_000))
    #expect(log.entries.last?.text.count == LunaTranscriptLog.maxEntryCharacters)
}
