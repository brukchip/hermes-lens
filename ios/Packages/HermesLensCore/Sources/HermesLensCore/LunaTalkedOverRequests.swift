import Foundation

/// Back-office requests the user talked over.
///
/// Talking over Luna makes the voice model cancel the tool calls in flight. A look or a
/// recording is quick and simply stops, but an `ask_luna` request keeps running: the
/// user usually still wants it, and hanging up its HTTP request would make the plugin
/// stop the Hermes run. The voice model is told at once that the request continues. When
/// it finishes, its result is kept here until a note carrying it has been sent into the
/// call; if the voice model asks again for the same request meanwhile, the repeat is
/// answered from the same run (still running: it waits for it; finished: at once).
///
/// Pure bookkeeping: the session owns the tasks and the socket, this decides.
public struct LunaTalkedOverRequests: Sendable {
    private struct Run: Sendable {
        /// Normalised request text (nil when the call had none).
        let request: String?
        let attachesPhotos: Bool
        /// Set once the run finished; cleared when its note is sent or a repeat takes it.
        var finished: LunaNativeToolResult?
    }

    /// Detached tool call id → its run.
    private var runs: [String: Run] = [:]
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
                runs[id] = Run(request: call.request.map(Self.normalized), attachesPhotos: call.attachesPhotos)
            } else {
                cancelled.append(id)
            }
        }
        return cancelled
    }

    /// What to do with a new tool call.
    public enum Route: Sendable {
        /// Run it normally.
        case run
        /// The detached run with this id is still working on the same request: it answers
        /// this call when it finishes.
        case adopt(String)
        /// The same request already finished while talked over: answer with this result now.
        /// A card in it is shown with `cardSource` (always button-only).
        case answer(LunaNativeToolResult, cardSource: LunaApprovalSlot.Source)
        /// A talked-over request still runs (the server works on one request per chat at a
        /// time, so another would queue behind it and time out): answer on the phone at once
        /// with this text, without asking the server.
        case busy(String)
    }

    public static let busyAnswer = "The user's earlier request is still running. Tell them you'll share its "
        + "result when it's back, and to ask this again after that."
    public static let busyWithoutPhotosAnswer = "The user's earlier request is still running, without the "
        + "photos. Tell them you'll share its result when it's back, and to ask again with the photos after that."

    /// While a talked-over result waits for its note, the next back-office request, however
    /// it is worded, is answered with that result, marked as the result of the earlier request
    /// (the voice model often re-asks in other words; running it again would do it twice).
    /// While a talked-over request still runs, the same request (ignoring case and spacing) is
    /// adopted by it, once; any other back-office request is answered busy.
    public mutating func route(_ call: LunaNativeToolCall) -> Route {
        guard Self.keepsRunningWhenTalkedOver(call.name) else { return .run }
        if let id = runs.keys.sorted().first(where: { runs[$0]?.finished != nil }), let finished = runs[id]?.finished {
            runs[id] = nil  // delivered with this answer: no note follows
            return .answer(Self.markedAsEarlier(finished), cardSource: .talkedOver)
        }
        let wanted = call.request.map(Self.normalized)
        if let wanted, let id = runs.keys.sorted().first(where: { runs[$0]?.request == wanted }), let run = runs[id] {
            // A repeat that adds photos the run does not have cannot be answered by it.
            if call.attachesPhotos && !run.attachesPhotos { return .busy(Self.busyWithoutPhotosAnswer) }
            guard adoptedBy[id] == nil else { return .busy(Self.busyAnswer) }
            adoptedBy[id] = call
            return .adopt(id)
        }
        return isRunning ? .busy(Self.busyAnswer) : .run
    }

    /// A kept result handed to a later request: clearly the earlier request's result.
    static func markedAsEarlier(_ result: LunaNativeToolResult) -> LunaNativeToolResult {
        let text = resultText(result.response).trimmingCharacters(in: .whitespacesAndNewlines)
        let marked = "This is the result of the user's earlier request, which kept running after they talked "
            + "over it: \(text.isEmpty ? "done." : text) If they still need something else, ask again."
        return LunaNativeToolResult(response: LunaNativeWire.toolResult(marked), approval: result.approval)
    }

    /// What to do with a finished run's result.
    public enum Delivery: Equatable, Sendable {
        /// Answer this tool call (the original one, or the repeat that adopted the run). A card
        /// in the result is shown with `cardSource`: a run that was talked over is button-only
        /// even when a repeat it answered is waiting for it.
        case respond(LunaNativeToolCall, cardSource: LunaApprovalSlot.Source)
        /// Nobody waits for it: tell the call in a note (`takeUndelivered` when sending it).
        case note
    }

    /// The run for `call` finished with `result`.
    public mutating func finish(_ call: LunaNativeToolCall, result: LunaNativeToolResult) -> Delivery {
        guard runs[call.id] != nil else { return .respond(call, cardSource: .answer) }
        if let repeated = adoptedBy.removeValue(forKey: call.id) {
            runs[call.id] = nil
            return .respond(repeated, cardSource: .talkedOver)
        }
        runs[call.id]?.finished = result
        return .note
    }

    /// A finished talked-over result taken for delivery, and how a card in it is shown.
    public struct Kept: Sendable {
        public let result: LunaNativeToolResult
        /// Always `.talkedOver`: button-only.
        public let cardSource: LunaApprovalSlot.Source
    }

    /// The finished result of a talked-over run that no repeat has taken yet, removed from
    /// the ledger. nil when a repeat was already answered with it.
    public mutating func takeUndelivered(_ id: String) -> Kept? {
        guard let finished = runs[id]?.finished else { return nil }
        runs[id] = nil
        return Kept(result: finished, cardSource: .talkedOver)
    }

    public func isDetached(_ id: String) -> Bool { runs[id] != nil }

    /// A talked-over request is still working (not yet finished).
    public var isRunning: Bool { runs.values.contains { $0.finished == nil } }

    /// Repeats waiting on a detached run (they count as tools in flight).
    public var waitingRepeats: Int { adoptedBy.count }

    public var isEmpty: Bool { runs.isEmpty && adoptedBy.isEmpty }

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

    /// Told to the voice model when the user talks over a request that keeps running, so it
    /// neither asks again nor claims the request was dropped.
    public static func detachedNote(request: String?) -> String {
        let what = request.map { " (\"\(String($0.prefix(300)))\")" } ?? ""
        return "[Update from Luna's phone] The user talked over your request\(what). It is still running, and "
            + "its result will come as an update. Do not ask for it again; if the user asks, say it is on its way."
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
