import Foundation
import Testing
@testable import HermesLensCore

private func ask(_ id: String, _ request: String) -> LunaNativeToolCall {
    LunaNativeToolCall(id: id, name: LunaNativeVoice.toolName, request: request)
}

@Test func talkingOverCancelsCameraToolsButKeepsBackOfficeWorkRunning() {
    var ledger = LunaTalkedOverRequests()
    let running = [
        "a": ask("a", "What's on my calendar?"),
        "l": LunaNativeToolCall(id: "l", name: "look", request: nil),
        "v": LunaNativeToolCall(id: "v", name: "record_video", request: nil),
    ]
    let cancelled = ledger.cancel(["a", "l", "v", "unknown"], running: running)
    #expect(cancelled.sorted() == ["l", "v"])
    #expect(ledger.isDetached("a"))
    #expect(!ledger.isDetached("l"))
}

@Test func aDetachedRunThatNobodyAsksForAgainBecomesANote() {
    var ledger = LunaTalkedOverRequests()
    let call = ask("a", "Send the report")
    _ = ledger.cancel(["a"], running: ["a": call])
    #expect(ledger.finish(call) == .note)
    #expect(ledger.isEmpty)
    // A call that was never talked over answers itself.
    let other = ask("b", "Anything")
    #expect(ledger.finish(other) == .respond(other))
}

@Test func aRepeatedRequestIsAnsweredByTheRunningRequest() {
    var ledger = LunaTalkedOverRequests()
    let first = ask("a", "What's on my  calendar today?")
    _ = ledger.cancel(["a"], running: ["a": first])
    // Different request text: runs normally.
    #expect(ledger.adopt(ask("x", "Something else")) == nil)
    // Same text (spacing and case aside) while it still runs: adopted, no second run.
    let repeated = ask("b", "what's on my calendar today?")
    #expect(ledger.adopt(repeated) == "a")
    #expect(ledger.waitingRepeats == 1)
    // A run answers one repeat only.
    #expect(ledger.adopt(ask("c", "What's on my calendar today?")) == nil)
    #expect(ledger.finish(first) == .respond(repeated))
    #expect(ledger.isEmpty)
}

@Test func aCancelledRepeatHandsTheResultBackToANote() {
    var ledger = LunaTalkedOverRequests()
    let first = ask("a", "Book the table")
    _ = ledger.cancel(["a"], running: ["a": first])
    let repeated = ask("b", "Book the table")
    #expect(ledger.adopt(repeated) == "a")
    // The repeat is talked over too: nothing to cancel (it never ran), the note returns.
    #expect(ledger.cancel(["b"], running: [:]).isEmpty)
    #expect(ledger.waitingRepeats == 0)
    #expect(ledger.finish(first) == .note)
}

@Test func onlyBackOfficeRequestsAreAdopted() {
    var ledger = LunaTalkedOverRequests()
    _ = ledger.cancel(["a"], running: ["a": ask("a", "look")])
    #expect(ledger.adopt(LunaNativeToolCall(id: "l", name: "look", request: "look")) == nil)
    ledger.reset()
    #expect(ledger.isEmpty)
}

@Test func talkedOverNotesCarryTheResultOrTheCard() throws {
    let result = LunaNativeWire.toolResult("Your next meeting is at 3.")
    #expect(LunaTalkedOverRequests.resultText(result) == "Your next meeting is at 3.")
    #expect(LunaTalkedOverRequests.resultText(LunaNativeWire.toolFailure("Nope.")) == "Nope.")
    #expect(LunaTalkedOverRequests.resultText(Data("x".utf8)) == "")
    let note = try #require(LunaTalkedOverRequests.note(result: "Your next meeting is at 3.", approvalSummary: nil))
    #expect(note.hasPrefix("[Update] The user talked over this request, so it kept running. Result: Your next meeting is at 3."))
    #expect(note.contains("only if it still matters"))
    let card = try #require(LunaTalkedOverRequests.note(result: "", approvalSummary: "Send a message to Sam"))
    #expect(card.contains("earlier in this call") && card.contains("Send a message to Sam"))
    #expect(LunaTalkedOverRequests.note(result: "  ", approvalSummary: nil) == nil)
}
