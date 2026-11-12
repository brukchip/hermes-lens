import Foundation

/// The soft "still working" tone while Luna's back office works and nobody is talking.
/// It used to repeat every 2.5 s for as long as the work ran; now it backs off: once
/// after 1.5 s of quiet, then every 10 s, and not at all after a minute of quiet.
public enum LunaWorkingTone {
    public static let firstAfter: TimeInterval = 1.5
    public static let interval: TimeInterval = 10
    public static let stopAfter: TimeInterval = 60

    /// Seconds of quiet at which the tone plays: 1.5, 11.5, 21.5, 31.5, 41.5, 51.5.
    public static let times: [TimeInterval] = Array(stride(from: firstAfter, to: stopAfter, by: interval))

    /// True when a tone is due between two readings of the quiet time, `(previous, now]`.
    public static func plays(from previous: TimeInterval, to now: TimeInterval) -> Bool {
        times.contains { $0 > previous && $0 <= now }
    }
}

/// Before a call reaches its time limit, Luna says once that it is about to end.
public enum LunaCallEnding {
    /// How long before the end Luna is told, so she has time for one short sentence.
    public static let warnBefore: TimeInterval = 15
    /// A call with less than this much time left before the warning gets none.
    public static let minimumDelay: TimeInterval = 10

    /// Seconds from now until the warning, or nil when the call is too short for one.
    public static func warningDelay(remaining: TimeInterval) -> TimeInterval? {
        guard remaining - warnBefore >= minimumDelay else { return nil }
        return remaining - warnBefore
    }

    public static let note = "[Update from Luna's phone] This call is about to reach its time limit. Tell the user "
        + "in one short sentence that the call ends in a few seconds and they can start a new call to keep going."
}
