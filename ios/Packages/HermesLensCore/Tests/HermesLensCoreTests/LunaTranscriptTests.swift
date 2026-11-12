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
        log.user("q\(index)"); log.luna("a\(index)"); log.turnEnded()
    }
    #expect(log.entries.count == LunaTranscriptLog.maxEntries)
    log.user(String(repeating: "x", count: 10_000))
    #expect(log.entries.last?.text.count == LunaTranscriptLog.maxEntryCharacters)
}

@Test func aLateChunkOfTheQuestionJoinsItInsteadOfSplittingBothUtterances() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let id = state.generation
    state.receive(.inputTranscript("What time"), generation: id)
    state.receive(.outputTranscript("It's"), generation: id)
    // Gemini delivers the tail of the question after Luna started answering.
    state.receive(.inputTranscript(" is it?"), generation: id)
    state.receive(.outputTranscript(" three."), generation: id)
    state.receive(.turnComplete, generation: id)
    #expect(state.log.entries == [Entry(speaker: .you, text: "What time is it?"),
                                  Entry(speaker: .luna, text: "It's three.")])
    #expect(state.heard == "What time is it?" && !state.heardIsLatest)
}

@Test func theSameChunkOrderFollowedByAnInterruptionStartsANewUtterance() {
    var state = LunaNativeCallState()
    state.begin(); state.connected()
    let id = state.generation
    state.receive(.inputTranscript("What time is it?"), generation: id)
    state.receive(.outputTranscript("It's"), generation: id)
    state.receive(.inputTranscript(" Wait,"), generation: id)
    #expect(state.heardIsLatest) // shown below Luna's answer meanwhile
    state.receive(.interrupted, generation: id)
    state.receive(.inputTranscript(" what's the date?"), generation: id)
    state.receive(.outputTranscript("The ninth."), generation: id)
    state.receive(.turnComplete, generation: id)
    #expect(state.log.entries.map(\.text) == ["What time is it?", "It's", "Wait, what's the date?", "The ninth."])
}

@Test func wordsDuringAnAnswerThatEndsWithoutMoreOfItStartANewUtterance() {
    var log = LunaTranscriptLog()
    log.user("Hi"); log.luna("Hello!")
    log.user(" One more thing")
    log.turnEnded()
    log.user(" about tomorrow")
    log.luna("Sure.")
    #expect(log.entries.map(\.text) == ["Hi", "Hello!", "One more thing about tomorrow", "Sure."])
}

@Test func lateWordsJoinOnlyTheQuestionOfThisTurn() {
    // Luna speaks first (no question this turn): words during her answer are kept, not lost.
    var first = LunaTranscriptLog()
    first.luna("Hi, I'm Luna.")
    first.user(" Hello")
    first.luna(" How can I help?")
    first.turnEnded()
    #expect(first.entries.map(\.text) == ["Hello", "Hi, I'm Luna. How can I help?"])
    // An update after an earlier turn: late words never join the older turn's question.
    var later = LunaTranscriptLog()
    later.user("What's the time?"); later.luna("Three."); later.turnEnded()
    later.luna("Your report is ready.")
    later.user(" thanks")
    later.luna(" It's in your inbox.")
    later.turnEnded()
    #expect(later.entries.map(\.text) == ["What's the time?", "Three.", "thanks", "Your report is ready. It's in your inbox."])
}
