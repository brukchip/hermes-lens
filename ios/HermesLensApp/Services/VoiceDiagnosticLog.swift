import Foundation
import OSLog

/// A small, bounded, content-free trace of the voice capture path.
///
/// The same lines go to OSLog and to a file inside the app container, so a
/// device-only problem can be diagnosed by copying the file off the phone
/// (`xcrun devicectl device copy from --domain-type appDataContainer`).
///
/// Privacy contract: this records event
/// names, audio route names, sample rates, channel counts, error domains and
/// codes, and timestamps. It must never record transcripts, recognized text,
/// answers, questions, captures, tokens, or credentials. Callers pass short
/// structural strings only.
@MainActor
enum VoiceDiagnosticLog {
    /// About a day of calls: 400 lines covered only a few hours.
    static let maximumLines = 4000
    /// Lines appended past the limit before the file is rewritten trimmed: appending one line
    /// is cheap, rewriting the whole file on every event (on the main actor, mid-call) is not.
    static let trimSlack = 500
    private static let fileName = "voice-diagnostics.log"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesLens",
        category: "VoiceDiagnostics"
    )

    private static var lines: [String] = []
    private static var loaded = false

    static var fileURL: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(fileName)
    }

    /// Append one structural event. Keep `detail` free of user content.
    static func record(_ event: String, _ detail: String = "") {
        loadIfNeeded()
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = detail.isEmpty ? "\(stamp) \(event)" : "\(stamp) \(event) \(detail)"
        lines.append(line)
        if lines.count > maximumLines + trimSlack {
            lines = trimmed(lines)
            rewrite()
        } else {
            append(line)
        }
    }

    /// The newest `maximumLines` lines.
    static func trimmed(_ lines: [String]) -> [String] {
        Array(lines.suffix(maximumLines))
    }

    private static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let existing = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }
        lines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        excludeFromBackup()
        if lines.count > maximumLines {
            lines = trimmed(lines)
            rewrite()
        }
    }

    private static func excludeFromBackup() {
        guard var fileURL else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? fileURL.setResourceValues(values)
    }

    private static func append(_ line: String) {
        guard let fileURL else { return }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { rewrite(); return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            logger.error("Could not append voice diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes the kept lines as the whole file, excluded from iCloud and device backups.
    private static func rewrite() {
        guard let fileURL else { return }
        do {
            try lines.joined(separator: "\n").appending("\n")
                .write(to: fileURL, atomically: true, encoding: .utf8)
            excludeFromBackup()
        } catch {
            logger.error("Could not persist voice diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }
}
