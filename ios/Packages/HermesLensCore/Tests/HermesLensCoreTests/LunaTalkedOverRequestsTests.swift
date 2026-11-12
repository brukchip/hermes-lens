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
        if case .answer(let result, _) = self { LunaTalkedOverRequests.resultText(result.response) } else { nil }
    }
    var answerCardSource: LunaApprovalSlot.Source? {
        if case .answer(_, let source) = self { source } else { nil }
    }
    var runs: Bool { if case .run = self { true } else { false } }
    var busyText: String? { if case .busy(let text) = self { text } else { nil } }
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
    #expect(taken.map { LunaTalkedOverRequests.resultText($0.result.response) } == "Sent.")
    #expect(taken?.cardSource == .talkedOver) // its card is button-only
    #expect(ledger.takeUndelivered("a") == nil)
    #expect(ledger.isEmpty)
    // A call that was never talked over answers itself.
    let other = ask("b", "Anything")
    #expect(ledger.finish(other, result: result("x")) == .respond(other, cardSource: .answer))
}

@Test func aRepeatWhileTheRequestRunsIsAnsweredByThatRun() {
    var ledger = LunaTalkedOverRequests()
    let first = ask("a", "What's on my  calendar today?")
    _ = ledger.cancel(["a"], running: ["a": first])
    // Same text (spacing and case aside) while it still runs: adopted, no second run.
    let repeated = ask("b", "what's on my calendar today?")
    #expect(ledger.route(repeated).adopted == "a")
    #expect(ledger.waitingRepeats == 1)
    // The run was talked over: a card in its result is button-only, even though a repeat waits.
    #expect(ledger.finish(first, result: result("Two meetings.")) == .respond(repeated, cardSource: .talkedOver))
    #expect(ledger.isEmpty)
}

@Test func aRepeatAfterTheRunFinishedIsAnsweredFromItsKeptResult() {
    var ledger = LunaTalkedOverRequests()
    let first = ask("a", "Book the table")
    _ = ledger.cancel(["a"], running: ["a": first])
    #expect(ledger.finish(first, result: result("Booked for 8.")) == .note)
    // The note has not gone out yet: the repeat gets the result, and the note is dropped.
    #expect(ledger.route(ask("b", "book the table")).answerText?.contains("earlier request") == true)
    #expect(ledger.takeUndelivered("a") == nil)
    #expect(ledger.isEmpty)
}

@Test func aKeptResultsCardIsButtonOnlyWhenARepeatTakesIt() {
    var ledger = LunaTalkedOverRequests()
    let first = ask("a", "Send it")
    _ = ledger.cancel(["a"], running: ["a": first])
    _ = ledger.finish(first, result: result("x"))
    #expect(ledger.route(ask("b", "Send it")).answerCardSource == .talkedOver)
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

@Test func aDifferentRequestWhileATalkedOverOneRunsIsAnsweredBusyOnThePhone() {
    var ledger = LunaTalkedOverRequests()
    let first = ask("a", "Email the report to Sam")
    _ = ledger.cancel(["a"], running: ["a": first])
    #expect(ledger.route(ask("b", "What's the weather?")).busyText == LunaTalkedOverRequests.busyAnswer)
    // The identical request is still adopted; a second repeat is busy, not a second run.
    #expect(ledger.route(ask("c", "Email the report to Sam")).adopted == "a")
    #expect(ledger.route(ask("d", "Email the report to Sam")).busyText != nil)
    // Camera tools are never held back.
    #expect(ledger.route(LunaNativeToolCall(id: "l", name: "look", request: nil)).runs)
    // Once it finished, other requests run normally again.
    _ = ledger.finish(first, result: result("Sent."))
    #expect(ledger.route(ask("e", "What's the weather?")).runs)
}

@Test func aRepeatThatAddsPhotosIsNotAnsweredByARunWithout() {
    var ledger = LunaTalkedOverRequests()
    let first = ask("a", "Keep this receipt")
    _ = ledger.cancel(["a"], running: ["a": first])
    #expect(ledger.route(ask("b", "Keep this receipt", photos: true)).busyText == LunaTalkedOverRequests.busyWithoutPhotosAnswer)
    _ = ledger.finish(first, result: result("Kept."))
    // Finished, note not sent yet: the repeat gets the earlier result, which says to ask again.
    let answer = ledger.route(ask("c", "Keep this receipt", photos: true)).answerText
    #expect(answer?.contains("Kept.") == true && answer?.contains("ask again") == true)
    #expect(ledger.route(ask("d", "Keep this receipt", photos: true)).runs)
}

@Test func aRewordedReAskAfterTheRunFinishedGetsTheEarlierResultNotASecondRun() throws {
    var ledger = LunaTalkedOverRequests()
    let first = ask("a", "Email the report to Sam")
    _ = ledger.cancel(["a"], running: ["a": first])
    #expect(ledger.finish(first, result: result("Sent to Sam at 10:02.")) == .note)
    // The voice model asks again in other words while the note still waits.
    let text = try #require(ledger.route(ask("b", "Did the report go out to Sam?")).answerText)
    #expect(text.hasPrefix("This is the result of the user's earlier request"))
    #expect(text.contains("Sent to Sam at 10:02.") && text.contains("If they still need something else, ask again."))
    // Delivered: the note is not sent as well, and the next request runs normally.
    #expect(ledger.takeUndelivered("a") == nil)
    #expect(ledger.route(ask("c", "Anything else")).runs)
}
