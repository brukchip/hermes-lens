import Foundation

/// Whether a glasses double tap may approve the approval card on screen.
///
/// A double tap is a deliberate press, but it can be meant for something else (mute), so it
/// approves only a card the user has had time to see: one on screen for at least 1.5 s,
/// timed from when it actually became visible. A card from a request the user talked over
/// arrives unannounced in the middle of other talk, so it is approved only with the on-screen
/// button, never by a gesture. An expired card or one already being answered never takes the
/// tap (it mutes instead).
public enum LunaApprovalGesture {
    public static let minimumVisibleSeconds: TimeInterval = 1.5

    public static func mayApprove(visibleSince: Date?, now: Date, fromTalkedOverRequest: Bool,
                                  busy: Bool, secondsLeft: TimeInterval) -> Bool {
        guard let visibleSince, !fromTalkedOverRequest, !busy, secondsLeft > 0 else { return false }
        return now.timeIntervalSince(visibleSince) >= minimumVisibleSeconds
    }
}
