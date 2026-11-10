import Foundation
import HermesLensCore

/// What remains of a call after End: the conversation, the actions the user
/// approved or declined, and the photos and clips taken. Stored only on this
/// iPhone (never synced to the server) and kept for 30 days.
struct CallRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let turns: [LunaCallTurn]
    let actions: [LunaCallAction]
    /// Library captures made during the call (looks and clips).
    let captureIDs: [UUID]

    /// The first thing the user asked, or a neutral title.
    var title: String {
        let first = turns.first { $0.speaker == .you }?.text ?? "Call with Luna"
        return first.count > 80 ? String(first.prefix(79)) + "…" : first
    }

    /// Luna's last answer, for one-line previews.
    var summary: String {
        turns.last { $0.speaker == .luna }?.text ?? "No answer was spoken."
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// Local-only store for call records, separate from the Library snapshot.
actor CallRecordStore {
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    private let fileURL: URL
    private let now: @Sendable () -> Date

    init(rootURL: URL? = nil, now: @escaping @Sendable () -> Date = { .now }) {
        let root = rootURL ?? LunaStorageRoot.url()
        let directory = root.appendingPathComponent("HermesLens", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("calls.json")
        self.now = now
    }

    /// Records newer than 30 days, newest first. Expired ones are dropped from disk.
    func load() -> [CallRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder.hermes.decode([CallRecord].self, from: data) else { return [] }
        let kept = retained(records)
        if kept.count != records.count { try? write(kept) }
        return kept
    }

    func save(_ records: [CallRecord]) throws {
        try write(retained(records))
    }

    func deleteAll() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func retained(_ records: [CallRecord]) -> [CallRecord] {
        let cutoff = now().addingTimeInterval(-Self.lifetime)
        return records.filter { $0.endedAt >= cutoff }.sorted { $0.startedAt > $1.startedAt }
    }

    private func write(_ records: [CallRecord]) throws {
        let data = try JSONEncoder.hermes.encode(records)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
