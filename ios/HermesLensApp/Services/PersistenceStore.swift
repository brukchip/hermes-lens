import Foundation
import HermesLensCore

/// Where Luna keeps personal data: Application Support, or — for UI tests
/// (`-LunaUITestData`, debug builds only) — a throwaway folder wiped at launch, so
/// automated runs on a real iPhone never read or change real calls, notes,
/// reminders or captures.
enum LunaStorageRoot {
    static func url(_ fileManager: FileManager = .default) -> URL {
        #if DEBUG
        if isUITestRun {
            return fileManager.temporaryDirectory.appendingPathComponent("LunaUITestData", isDirectory: true)
        }
        #endif
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    static var isUITestRun: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-LunaUITestData")
        #else
        false
        #endif
    }

    /// Starts each UI-test launch from an empty Library. The stores already created
    /// their folders, so the folders are recreated empty rather than left missing.
    static func resetForUITestRun() {
        guard isUITestRun else { return }
        let directory = url().appendingPathComponent("HermesLens", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("Captures", isDirectory: true),
                                                 withIntermediateDirectories: true)
    }
}

struct DataRetentionPolicy: Equatable, Sendable {
    var captureLifetime: TimeInterval
    var memoryLifetime: TimeInterval
    var completedReminderLifetime: TimeInterval

    static let standard = DataRetentionPolicy(
        captureLifetime: 30 * 24 * 60 * 60,
        memoryLifetime: 365 * 24 * 60 * 60,
        completedReminderLifetime: 90 * 24 * 60 * 60
    )
}

actor PersistenceStore {
    private struct Snapshot: Codable {
        var memories: [MemoryRecord]
        var reminders: [ReminderRecord]
        var artifacts: [CaptureArtifact]?
    }

    private let fileManager: FileManager
    private let fileURL: URL
    private let mediaDirectoryURL: URL
    private let policy: DataRetentionPolicy
    private let now: @Sendable () -> Date

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        policy: DataRetentionPolicy = .standard,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fileManager = fileManager
        self.policy = policy
        self.now = now
        let root = rootURL ?? LunaStorageRoot.url(fileManager)
        let directory = root.appendingPathComponent("HermesLens", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaDirectory = directory.appendingPathComponent("Captures", isDirectory: true)
        try? fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("snapshot.json")
        mediaDirectoryURL = mediaDirectory
    }

    func load() -> (
        memories: [MemoryRecord],
        reminders: [ReminderRecord],
        artifacts: [CaptureArtifact]
    ) {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder.hermes.decode(Snapshot.self, from: data)
        else {
            return ([], [], [])
        }
        let retained = enforceRetention(
            memories: snapshot.memories,
            reminders: snapshot.reminders,
            artifacts: snapshot.artifacts ?? []
        )
        if retained.changed {
            try? writeSnapshot(
                memories: retained.memories,
                reminders: retained.reminders,
                artifacts: retained.artifacts
            )
        }
        return (
            retained.memories,
            retained.reminders,
            retained.artifacts
        )
    }

    func save(
        memories: [MemoryRecord],
        reminders: [ReminderRecord],
        artifacts: [CaptureArtifact]
    ) throws {
        let retained = enforceRetention(
            memories: memories,
            reminders: reminders,
            artifacts: artifacts
        )
        try writeSnapshot(
            memories: retained.memories,
            reminders: retained.reminders,
            artifacts: retained.artifacts
        )
    }

    func exportBundle(
        memories: [MemoryRecord],
        reminders: [ReminderRecord],
        artifacts: [CaptureArtifact]
    ) throws -> URL {
        let retained = enforceRetention(
            memories: memories,
            reminders: reminders,
            artifacts: artifacts
        )
        let exportRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HermesLensExport-\(UUID().uuidString)", isDirectory: true)
        let exportCaptures = exportRoot.appendingPathComponent("Captures", isDirectory: true)
        try fileManager.createDirectory(at: exportCaptures, withIntermediateDirectories: true)
        let manifest = Snapshot(
            memories: retained.memories,
            reminders: retained.reminders,
            artifacts: retained.artifacts
        )
        let data = try JSONEncoder.hermes.encode(manifest)
        try data.write(
            to: exportRoot.appendingPathComponent("HermesLensData.json"),
            options: [.atomic, .completeFileProtection]
        )
        for artifact in retained.artifacts where isSafeFilename(artifact.localFilename) {
            let source = mediaDirectoryURL.appendingPathComponent(artifact.localFilename)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(
                at: source,
                to: exportCaptures.appendingPathComponent(artifact.localFilename)
            )
        }
        return exportRoot
    }

    func deleteAllPersonalData() throws {
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        if fileManager.fileExists(atPath: mediaDirectoryURL.path) {
            try fileManager.removeItem(at: mediaDirectoryURL)
        }
        try fileManager.createDirectory(at: mediaDirectoryURL, withIntermediateDirectories: true)
    }

    func storeCapture(_ data: Data, kind: CaptureArtifactKind, id: UUID) throws -> String {
        let fileExtension = kind == .photo ? "jpg" : "mp4"
        let filename = "\(id.uuidString.lowercased()).\(fileExtension)"
        let destination = mediaDirectoryURL.appendingPathComponent(filename)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        return filename
    }

    func captureData(filename: String) -> Data? {
        guard isSafeFilename(filename) else { return nil }
        return try? Data(contentsOf: mediaDirectoryURL.appendingPathComponent(filename))
    }

    func captureURL(filename: String) -> URL? {
        guard isSafeFilename(filename) else { return nil }
        let url = mediaDirectoryURL.appendingPathComponent(filename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func deleteCapture(filename: String) throws {
        guard isSafeFilename(filename) else { return }
        let url = mediaDirectoryURL.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func writeSnapshot(
        memories: [MemoryRecord],
        reminders: [ReminderRecord],
        artifacts: [CaptureArtifact]
    ) throws {
        let snapshot = Snapshot(
            memories: memories,
            reminders: reminders,
            artifacts: artifacts
        )
        let data = try JSONEncoder.hermes.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private func enforceRetention(
        memories: [MemoryRecord],
        reminders: [ReminderRecord],
        artifacts: [CaptureArtifact]
    ) -> (
        memories: [MemoryRecord],
        reminders: [ReminderRecord],
        artifacts: [CaptureArtifact],
        changed: Bool
    ) {
        let referenceDate = now()
        let retainedMemories = memories.filter {
            referenceDate.timeIntervalSince($0.capturedAt) <= policy.memoryLifetime
        }
        let retainedReminders = reminders.filter {
            !$0.isCompleted
                || referenceDate.timeIntervalSince($0.completedAt ?? $0.dueAt)
                    <= policy.completedReminderLifetime
        }
        let retainedArtifacts = artifacts.filter {
            referenceDate.timeIntervalSince($0.capturedAt) <= policy.captureLifetime
        }
        let retainedNames = Set(retainedArtifacts.map(\.localFilename))
        for artifact in artifacts where !retainedNames.contains(artifact.localFilename) {
            try? deleteCapture(filename: artifact.localFilename)
        }
        return (
            retainedMemories,
            retainedReminders,
            retainedArtifacts,
            retainedMemories.count != memories.count
                || retainedReminders.count != reminders.count
                || retainedArtifacts.count != artifacts.count
        )
    }

    private func isSafeFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename == URL(fileURLWithPath: filename).lastPathComponent
            && !filename.contains("..")
    }
}
