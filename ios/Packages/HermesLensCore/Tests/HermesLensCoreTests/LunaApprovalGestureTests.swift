import Foundation
import Testing
@testable import HermesLensCore

private let t0 = Date(timeIntervalSince1970: 10_000)
private let card = LunaNativeToolResult.Approval(id: UUID(), summary: "Send a message to Sam")

private func slot(_ source: LunaApprovalSlot.Source = .answer, arrived: Date = t0, visible: Date = t0,
                  announcedAt: Date? = t0.addingTimeInterval(0.5)) -> LunaApprovalSlot {
    var slot = LunaApprovalSlot()
    slot.show(card, arrivedAt: arrived, now: visible, source: source)
    if let announcedAt { slot.lunaStartedSpeaking(at: announcedAt) }
    return slot
}

private func verdict(_ slot: LunaApprovalSlot, after seconds: TimeInterval, muted: Bool = false,
                     busy: Bool = false) -> LunaApprovalGesture.Verdict {
    slot.gesture(now: t0.addingTimeInterval(seconds), busy: busy, muted: muted)
}

@Test func aDoubleTapApprovesAnAnnouncedCardVisibleForAMomentWithTheMicOn() {
    #expect(verdict(slot(), after: 1.5) == .approves)
    #expect(verdict(slot(), after: 60) == .approves)
    #expect(verdict(slot(), after: 1.4) == .tooSoon)
    #expect(verdict(LunaApprovalSlot(), after: 5) == .noCard)
}

@Test func whileMutedTheDoubleTapOnlyUnmutes() {
    #expect(verdict(slot(), after: 5, muted: true) == .muted)
}

@Test func aCardLunaHasNotSpokenAboutSinceItAppearedIsNotApprovedByAGesture() {
    #expect(verdict(slot(announcedAt: nil), after: 30) == .notAnnounced)
    // Speech that started before the card appeared does not announce it.
    #expect(verdict(slot(visible: t0, announcedAt: t0.addingTimeInterval(-1)), after: 30) == .notAnnounced)
}

@Test func theGuardRunsFromWhenTheCardBecameVisibleNotWhenItArrived() {
    // A talked-over card can wait for the slot: it arrived 60 s before it became visible.
    var waited = LunaApprovalSlot()
    waited.show(card, arrivedAt: t0.addingTimeInterval(-60), now: t0, source: .answer)
    waited.lunaStartedSpeaking(at: t0.addingTimeInterval(0.2))
    #expect(verdict(waited, after: 1) == .tooSoon)
    #expect(verdict(waited, after: 2) == .approves)
}

@Test func cardsFromTalkedOverRequestsAndTheirFollowUpsAreButtonOnly() {
    let talkedOver = slot(.talkedOver)
    #expect(talkedOver.buttonOnly)
    #expect(verdict(talkedOver, after: 100) == .buttonOnly)
    var followUp = talkedOver
    followUp.show(card, arrivedAt: t0, now: t0, source: .followUp)
    #expect(followUp.buttonOnly)
    var normalFollowUp = slot(.answer)
    normalFollowUp.show(card, arrivedAt: t0, now: t0, source: .followUp)
    #expect(!normalFollowUp.buttonOnly)
    #expect(!slot(.answer).buttonOnly)
}

@Test func anExpiredOrBusyCardNeverTakesTheDoubleTapAndGoesAfterAMoment() {
    let card = slot()
    #expect(verdict(card, after: 5, busy: true) == .busy)
    #expect(verdict(card, after: LunaNativeVoice.approvalSeconds) == .expired)
    #expect(!card.isLive(now: t0.addingTimeInterval(LunaNativeVoice.approvalSeconds)))
    #expect(!card.shouldRemoveExpired(now: t0.addingTimeInterval(LunaNativeVoice.approvalSeconds + 2)))
    #expect(card.shouldRemoveExpired(now: t0.addingTimeInterval(LunaNativeVoice.approvalSeconds + 3)))
}

@Test func everyVerdictHasAPlainHint() {
    #expect(LunaApprovalGesture.Verdict.buttonOnly.hint.contains("can't approve this one"))
    #expect(LunaApprovalGesture.Verdict.muted.hint.contains("Tap Approve"))
    #expect(LunaApprovalGesture.Verdict.notAnnounced.hint.contains("Tap Approve"))
    #expect(LunaApprovalGesture.Verdict.approves.hint.contains("double-tap"))
}
