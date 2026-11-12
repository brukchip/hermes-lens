import Foundation

/// The conversation of one call in the order it was spoken, for the call record.
///
/// Built from the same transcript events the captions use. A user utterance ends when
/// Luna starts answering; Luna's answer ends when the user speaks again, when she is
/// interrupted or when her turn completes. Utterances are never merged or dropped by
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

    public init() {}

    /// Every utterance so far, oldest first, including the one still being spoken.
    public var entries: [Entry] {
        var all = committed
        if let open = Self.entry(.you, heard) { all.append(open) }
        if let open = Self.entry(.luna, said) { all.append(open) }
        return all
    }

    /// Part of what the user is saying. Luna's previous answer is finished.
    public mutating func user(_ text: String) {
        commitLuna()
        heard = String((heard + text).prefix(Self.maxEntryCharacters))
    }

    /// Part of what Luna is saying. The user's question before it is finished.
    public mutating func luna(_ text: String) {
        commitUser()
        said = String((said + text).prefix(Self.maxEntryCharacters))
    }

    /// Luna was cut off: what she said so far is final. The user may still be speaking,
    /// so their utterance stays open.
    public mutating func lunaStopped() { commitLuna() }

    /// The turn is complete: both sides are final.
    public mutating func turnEnded() { commitUser(); commitLuna() }

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
