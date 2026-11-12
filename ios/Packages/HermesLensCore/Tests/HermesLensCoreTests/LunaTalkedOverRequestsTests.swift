import Foundation
import Testing
@testable import HermesLensCore

private func ask(_ id: String, _ request: String, photos: Bool = false) -> LunaNativeToolCall {
    LunaNativeToolCall(id: id, name: LunaNativeVoice.toolName, request: request,
                       arguments: photos ? ["attach_photos": "true"] : [:])
}

private func result(_ text: String) -> LunaNativeToolResult {
    LunaNativeToolResult(response: LunaNativeWire.toolResult(text), approval: nil)
}

private extension LunaTalkedOverRequests.Route {
    var adopted: String? { if case .adopt(let id) = self { id } else { nil } }
    var answerText: String? {
        if case .answer(let result) = self { LunaTalkedOverRequests.resultText(result.response) } else { nil }
    }
    var runs: Bool { if case .run = self { true } else { false } }
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
    #expect(ledger.isDetached("a") && ledger.isRunning)
    #expect(!ledger.isDetached("l"))
}

@Test func aDetachedResultIsKeptUntilItsNoteIsSent() {
    var ledger = LunaTalkedOverRequests()
    let call = ask("a", "Send the report")
    _ = ledger.cancel(["a"], running: ["a": call])
    #expect(ledger.finish(call, result: result("Sent.")) == .note)
    #expect(!ledger.isRunning && ledger.isDetached("a"))
    let taken = ledger.takeUndelivered("a")
    #expect(taken.map { LunaTalkedOverRequests.resultText($0.response) } == "Sent.")
    #expect(ledger.takeUndelivered("a") == nil)
    #expect(ledger.isEmpty)
    // A call that was never talked over answers itself.
    let other = ask("b", "Anything")
    #expect(ledger.finish(other, result: result("x")) == .respond(other))
}

@Test func aRepeatWhileTheRequestRunsIsAnsweredByThatRun() {
    var ledger = LunaTalkedOverRequests()
    let first = ask("a", "What's on my  calendar today?")
    _ = ledger.cancel(["a"], running: ["a": first])
    // Same text (spacing and case aside) while it still runs: adopted, no second run.
    let repeated = ask("b", "what's on my calendar today?")
    #expect(ledger.route(repeated).adopted == "a")
    #expect(ledger.waitingRepeats == 1)
    #expect(ledger.finish(first, result: result("Two meetings.")) == .respond(repeated))
    #expect(ledger.isEmpty)
}

@Test func aRepeatAfterTheRunFinishedIsAnsweredFromItsKeptResult() {
    var ledger = LunaTalkedOverRequests()
    let first = ask("a", "Book the table")
    _ = ledger.cancel(["a"], running: ["a": first])
    #expect(ledger.finish(first, result: result("Booked for 8.")) == .note)
    // The note has not gone out yet: the repeat gets the result, and the note is dropped.
    #expect(ledger.route(ask("b", "book the table")).answerText == "Booked for 8.")
    #expect(ledger.takeUndelivered("a") == nil)
    #expect(ledger.isEmpty)
}

@Test func aCancelledRepeatHandsTheResultBackToANote() {
    var ledger = LunaTalkedOverRequests()
    let first = ask("a", "Book the table")
    _ = ledger.cancel(["a"], running: ["a": first])
    #expect(ledger.route(ask("b", "Book the table")).adopted == "a")
    #expect(ledger.cancel(["b"], running: [:]).isEmpty)
    #expect(ledger.waitingRepeats == 0)
    #expect(ledger.finish(first, result: result("Done")) == .note)
}

@Test func onlyBackOfficeRequestsAreRouted() {
    var ledger = LunaTalkedOverRequests()
    _ = ledger.cancel(["a"], running: ["a": ask("a", "look")])
    #expect(ledger.route(LunaNativeToolCall(id: "l", name: "look", request: "look")).runs)
    ledger.reset()
    #expect(ledger.isEmpty)
}

@Test func talkedOverNotesCarryTheResultOrTheCard() throws {
    let text = LunaNativeWire.toolResult("Your next meeting is at 3.")
    #expect(LunaTalkedOverRequests.resultText(text) == "Your next meeting is at 3.")
    #expect(LunaTalkedOverRequests.resultText(LunaNativeWire.toolFailure("Nope.")) == "Nope.")
    #expect(LunaTalkedOverRequests.resultText(Data("x".utf8)) == "")
    let note = try #require(LunaTalkedOverRequests.note(result: "Your next meeting is at 3.", approvalSummary: nil))
    #expect(note.hasPrefix("[Update] The user talked over this request, so it kept running. Result: Your next meeting is at 3."))
    #expect(note.contains("only if it still matters"))
    let card = try #require(LunaTalkedOverRequests.note(result: "", approvalSummary: "Send a message to Sam"))
    #expect(card.contains("earlier in this call") && card.contains("Send a message to Sam"))
    #expect(LunaTalkedOverRequests.note(result: "  ", approvalSummary: nil) == nil)
    let detached = LunaTalkedOverRequests.detachedNote(request: "Email the report")
    #expect(detached.contains("still running") && detached.contains("Email the report"))
    #expect(detached.contains("Do not ask for it again"))
}
