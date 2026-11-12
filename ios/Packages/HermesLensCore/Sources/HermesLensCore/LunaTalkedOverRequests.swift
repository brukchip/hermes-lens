import Foundation

/// Back-office requests the user talked over.
///
/// Talking over Luna makes the voice model cancel the tool calls in flight. A look or a
/// recording is quick and simply stops, but an `ask_luna` request keeps running: the
/// user usually still wants it, and hanging up its HTTP request would make the plugin
/// stop the Hermes run. When a detached request finishes, its result goes into the call
/// as a short note. If the voice model asks again for the same request while it still
/// runs, the new tool call is answered with that run's result instead of a second run.
///
/// Pure bookkeeping: the session owns the tasks and the socket, this decides.
public struct LunaTalkedOverRequests: Equatable, Sendable {
    /// Detached tool call id → its request text, normalised (nil when it had none).
    private var detached: [String: String?] = [:]
    /// Detached tool call id → the repeated tool call waiting for that run's result.
    private var adoptedBy: [String: LunaNativeToolCall] = [:]

    public init() {}

    /// Only back-office work outlives a talk-over; camera tools stop.
    public static func keepsRunningWhenTalkedOver(_ name: String) -> Bool {
        name == LunaNativeVoice.toolName
    }

    /// The voice model cancelled `ids`. `running` holds the tool calls still in flight.
    /// Returns the ids whose work must be cancelled now; the others keep running, detached.
    public mutating func cancel(_ ids: [String], running: [String: LunaNativeToolCall]) -> [String] {
        var cancelled: [String] = []
        for id in ids {
            // A repeat that was waiting on a detached run was itself cancelled: the run's
            // result becomes a note again when it finishes.
            for (run, repeated) in adoptedBy where repeated.id == id { adoptedBy[run] = nil }
            guard let call = running[id] else { continue }
            if Self.keepsRunningWhenTalkedOver(call.name) {
                detached.updateValue(call.request.map(Self.normalized), forKey: id)
            } else {
                cancelled.append(id)
            }
        }
        return cancelled
    }

    /// A new tool call arrived. Returns the id of the detached run that will answer it, or
    /// nil when the call should run normally. Matches the request text, ignoring case and
    /// spacing; a run answers at most one repeat.
    public mutating func adopt(_ call: LunaNativeToolCall) -> String? {
        guard Self.keepsRunningWhenTalkedOver(call.name), let request = call.request else { return nil }
        let wanted = Self.normalized(request)
        guard let run = detached.keys.sorted().first(where: { (detached[$0] ?? nil) == wanted && adoptedBy[$0] == nil })
        else { return nil }
        adoptedBy[run] = call
        return run
    }

    /// What to do with a finished run's result.
    public enum Delivery: Equatable, Sendable {
        /// Answer this tool call (the original one, or the repeat that adopted the run).
        case respond(LunaNativeToolCall)
        /// Nobody waits for it any more: tell the call in a note.
        case note
    }

    /// The run for `call` finished.
    public mutating func finish(_ call: LunaNativeToolCall) -> Delivery {
        guard detached.removeValue(forKey: call.id) != nil else { return .respond(call) }
        if let repeated = adoptedBy.removeValue(forKey: call.id) { return .respond(repeated) }
        return .note
    }

    public func isDetached(_ id: String) -> Bool { detached.keys.contains(id) }

    /// Repeats waiting on a detached run (they count as tools in flight).
    public var waitingRepeats: Int { adoptedBy.count }

    public var isEmpty: Bool { detached.isEmpty && adoptedBy.isEmpty }

    /// The call ended: nothing is waiting any more.
    public mutating func reset() { self = Self() }

    static func normalized(_ request: String) -> String {
        request.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// The text of a back-office result (`result`, else `error`), or "" when there is none.
    public static func resultText(_ response: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else { return "" }
        return (object["result"] as? String) ?? (object["error"] as? String) ?? ""
    }

    /// What Luna hears when talked-over work finishes; nil when there is nothing to say.
    public static func note(result: String, approvalSummary: String?) -> String? {
        if let approvalSummary {
            return "[Update from Luna's back office] A request from earlier in this call kept running and now "
                + "needs the user's tap on their phone: \(approvalSummary). Tell them in one short sentence to "
                + "check the card; never approve it yourself."
        }
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return "[Update] The user talked over this request, so it kept running. Result: \(text) "
            + "Tell them in one or two sentences only if it still matters."
    }
}
