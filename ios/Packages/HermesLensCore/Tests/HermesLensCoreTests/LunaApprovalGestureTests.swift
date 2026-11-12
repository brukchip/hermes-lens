import Foundation
import Testing
@testable import HermesLensCore

private let visible = Date(timeIntervalSince1970: 10_000)

private func may(after seconds: TimeInterval, visibleSince: Date? = visible, talkedOver: Bool = false,
                 busy: Bool = false, left: TimeInterval = 100) -> Bool {
    LunaApprovalGesture.mayApprove(visibleSince: visibleSince, now: visible.addingTimeInterval(seconds),
                                   fromTalkedOverRequest: talkedOver, busy: busy, secondsLeft: left)
}

@Test func aDoubleTapApprovesOnlyACardOnScreenForAMomentAlready() {
    #expect(!may(after: 0))
    #expect(!may(after: 1.4))
    #expect(may(after: 1.5))
    #expect(may(after: 60))
    #expect(!may(after: 60, visibleSince: nil)) // not visible yet
}

@Test func aTalkedOverRequestsCardIsNeverApprovedByAGesture() {
    #expect(!may(after: 1.5, talkedOver: true))
    #expect(!may(after: 100, talkedOver: true))
}

@Test func anExpiredOrBusyCardNeverTakesTheDoubleTap() {
    #expect(!may(after: 5, left: 0))
    #expect(!may(after: 5, busy: true))
}
