import Foundation

/// Whether a glasses double tap may approve the approval card on screen.
///
/// Tools run in the background and their results are spoken when Luna is idle, so a card
/// can appear while she is answering something else, and a double tap is also mute/unmute.
/// The double tap approves only when ALL of these hold; otherwise it keeps its normal
/// meaning (mute or unmute). The on-screen Approve button is never affected.
/// - the mic is not muted (a tap while muted only unmutes);
/// - Luna has started speaking after the card appeared, so it has been announced;
/// - the card has been visible for 1.5 s;
/// - the card is not from a request the user talked over (those are button-only), and it
///   is neither expired nor already being answered.
public enum LunaApprovalGesture {
    public static let minimumVisibleSeconds: TimeInterval = 1.5

    public enum Verdict: Equatable, Sendable {
        case approves
        case noCard
        /// From a talked-over request: only the on-screen button approves it.
        case buttonOnly
        case expired
        case busy
        /// The mic is muted: a double tap unmutes.
        case muted
        /// Luna has not spoken since the card appeared.
        case notAnnounced
        /// Visible for less than 1.5 s.
        case tooSoon

        /// The footnote under the card, in plain words.
        public var hint: String {
            switch self {
            case .approves, .tooSoon, .noCard:
                "Nothing happens unless you tap Approve or double-tap your glasses."
            case .buttonOnly:
                "Nothing happens unless you tap Approve. A double tap on your glasses can't approve this one."
            case .muted:
                "Tap Approve on your phone. While you're muted, a double tap on your glasses only unmutes."
            case .notAnnounced:
                "Tap Approve on your phone. A double tap on your glasses works once Luna has told you about it."
            case .expired:
                "This request expired, so nothing was done. Ask Luna again if you still want it."
            case .busy:
                "Sending your answer…"
            }
        }
    }

    public static func verdict(visibleSince: Date?, now: Date, buttonOnly: Bool, busy: Bool,
                               secondsLeft: TimeInterval, muted: Bool, announced: Bool) -> Verdict {
        guard let visibleSince else { return .noCard }
        if secondsLeft <= 0 { return .expired }
        if busy { return .busy }
        if buttonOnly { return .buttonOnly }
        if muted { return .muted }
        if !announced { return .notAnnounced }
        if now.timeIntervalSince(visibleSince) < minimumVisibleSeconds { return .tooSoon }
        return .approves
    }
}

/// The approval card a call shows, with what the double-tap rule needs to know about it.
public struct LunaApprovalSlot: Equatable, Sendable {
    /// Where a card came from, which decides whether a double tap may approve it.
    public enum Source: Equatable, Sendable {
        /// The answer to a request nobody talked over.
        case answer
        /// A request the user talked over (its own result, a repeat it answered, or a kept
        /// result): button-only.
        case talkedOver
        /// The next card after the user answered this one: keeps this card's rule.
        case followUp
    }

    public private(set) var card: LunaNativeToolResult.Approval?
    /// When the server issued the card: the two-minute countdown runs from here.
    public private(set) var arrivedAt: Date?
    /// When the card actually became visible: the 1.5 s guard runs from here.
    public private(set) var visibleSince: Date?
    public private(set) var buttonOnly = false
    /// Luna started speaking after the card appeared.
    public private(set) var announced = false

    /// After expiring, a card stays (disabled, reading "Expired") this long, then goes.
    public static let expiredLinger: TimeInterval = 3

    public init() {}

    public mutating func show(_ card: LunaNativeToolResult.Approval, arrivedAt: Date, now: Date, source: Source) {
        let inherited = buttonOnly
        self.card = card; self.arrivedAt = arrivedAt; visibleSince = now; announced = false
        buttonOnly = switch source {
        case .answer: false
        case .talkedOver: true
        case .followUp: inherited
        }
    }

    public mutating func clear() { self = Self() }

    /// Luna began a new spoken response at `time`.
    public mutating func lunaStartedSpeaking(at time: Date) {
        guard card != nil, let visibleSince, time >= visibleSince else { return }
        announced = true
    }

    public func secondsLeft(now: Date) -> TimeInterval {
        arrivedAt.map { LunaNativeVoice.approvalSecondsLeft(shownAt: $0, now: now) } ?? 0
    }

    /// A card is up that can still be answered.
    public func isLive(now: Date) -> Bool { card != nil && secondsLeft(now: now) > 0 }

    /// The card expired and has lingered long enough to be removed.
    public func shouldRemoveExpired(now: Date) -> Bool {
        guard card != nil, let arrivedAt else { return false }
        return now.timeIntervalSince(arrivedAt) >= LunaNativeVoice.approvalSeconds + Self.expiredLinger
    }

    public func gesture(now: Date, busy: Bool, muted: Bool) -> LunaApprovalGesture.Verdict {
        LunaApprovalGesture.verdict(visibleSince: card == nil ? nil : visibleSince, now: now, buttonOnly: buttonOnly,
                                    busy: busy, secondsLeft: secondsLeft(now: now), muted: muted, announced: announced)
    }
}
