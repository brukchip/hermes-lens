import Foundation

/// The conversation of one call in the order it was spoken, for the call record.
///
/// Built from the same transcript events the captions use. A user utterance ends when
/// Luna starts answering; Luna's answer ends when she is interrupted or her turn completes.
/// User words that arrive during her answer are placed by what follows them (see `pending`),
/// so the order does not depend on when Gemini delivers each transcript chunk. Utterances are never merged or dropped by
/// content, so saying "yes" twice keeps both.
public struct LunaTranscriptLog: Equatable, Sendable {
    public enum Speaker: String, Sendable { case you, luna }

    public struct Entry: Equatable, Sendable {
        public let speaker: Speaker
        public let text: String
        public init(speaker: Speaker, text: String) { self.speaker = speaker; self.text = text }
    }

    /// The most entries a call keeps (oldest dropped first) and the longest entry.
    public static let maxEntries = 400
    public static let maxEntryCharacters = 4_000

    private var committed: [Entry] = []
    private var heard = ""
    private var said = ""
    /// User words that arrived while Luna was answering. Gemini's input transcript can lag:
    /// such a chunk is either the late tail of the question Luna is answering, or the start
    /// of a new utterance that is talking over her. Which one is known only from what comes
    /// next: more of Luna's answer means it was late (it joins the question); an interruption
    /// or the end of her turn means a new utterance.
    private var pending = ""

    public init() {}

    /// Every utterance so far, oldest first, including the one still being spoken.
    public var entries: [Entry] {
        var all = committed
        if let open = Self.entry(.you, heard) { all.append(open) }
        if let open = Self.entry(.luna, said) { all.append(open) }
        if let open = Self.entry(.you, pending) { all.append(open) }
        return all
    }

    /// What the user said most recently (for the captions).
    public var currentUser: String {
        if !pending.isEmpty { return pending }
        if !heard.isEmpty { return heard }
        return committed.last { $0.speaker == .you }?.text ?? ""
    }

    /// The user's most recent words came after Luna's current answer (a new question).
    public var userSpokeLast: Bool { !pending.isEmpty || (!heard.isEmpty && said.isEmpty) }

    /// Part of what the user is saying.
    public mutating func user(_ text: String) {
        if said.isEmpty {
            heard = String((heard + text).prefix(Self.maxEntryCharacters))
        } else {
            pending = String((pending + text).prefix(Self.maxEntryCharacters))
        }
    }

    /// Part of what Luna is saying. The user's question before it is finished, and words that
    /// arrived during her answer without interrupting it were the late tail of that question.
    public mutating func luna(_ text: String) {
        commitUser()
        if !pending.isEmpty { joinLateWords() }
        said = String((said + text).prefix(Self.maxEntryCharacters))
    }

    /// Luna was cut off: what she said so far is final, and words heard during her answer
    /// begin the user's new utterance, which may still go on.
    public mutating func lunaStopped() {
        commitLuna()
        startUtteranceFromPending()
    }

    /// The turn is complete: both sides are final. Words that came during Luna's answer and
    /// were not followed by more of it begin a new utterance.
    public mutating func turnEnded() {
        commitUser(); commitLuna()
        startUtteranceFromPending()
    }

    private mutating func startUtteranceFromPending() {
        guard !pending.isEmpty else { return }
        heard = String((heard + pending).prefix(Self.maxEntryCharacters)); pending = ""
    }

    /// Appends late words to the user's last utterance (the one before Luna's current answer).
    private mutating func joinLateWords() {
        defer { pending = "" }
        guard let index = committed.lastIndex(where: { $0.speaker == .you }),
              let joined = Self.entry(.you, String((committed[index].text + pending).prefix(Self.maxEntryCharacters)))
        else { return }
        committed[index] = joined
    }

    private mutating func commitUser() {
        if let entry = Self.entry(.you, heard) { append(entry) }
        heard = ""
    }

    private mutating func commitLuna() {
        if let entry = Self.entry(.luna, said) { append(entry) }
        said = ""
    }

    private mutating func append(_ entry: Entry) {
        committed.append(entry)
        if committed.count > Self.maxEntries { committed.removeFirst(committed.count - Self.maxEntries) }
    }

    private static func entry(_ speaker: Speaker, _ text: String) -> Entry? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Entry(speaker: speaker, text: text)
    }
}
