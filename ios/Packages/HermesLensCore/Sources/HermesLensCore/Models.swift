import Foundation

/// A note the user saved. Kept on this iPhone only.
public struct MemoryRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public var note: String
    public var summary: String

    public init(id: UUID = UUID(), capturedAt: Date = .now, note: String, summary: String) {
        self.id = id
        self.capturedAt = capturedAt
        self.note = note
        self.summary = summary
    }
}

public enum CaptureArtifactKind: String, Codable, Hashable, Sendable {
    case photo
    case video

    public var displayName: String {
        switch self {
        case .photo: "Photo"
        case .video: "Recording"
        }
    }
}

/// A photo or clip from the glasses. The original stays in the local Library.
public struct CaptureArtifact: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public var kind: CaptureArtifactKind
    public var localFilename: String
    /// Where the capture came from, e.g. "Photo from a Luna call".
    public var request: String

    public init(
        id: UUID = UUID(),
        capturedAt: Date = .now,
        kind: CaptureArtifactKind,
        localFilename: String,
        request: String
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.kind = kind
        self.localFilename = localFilename
        self.request = request
    }
}

/// A reminder with a local notification. Kept on this iPhone only.
public struct ReminderRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var note: String
    public var dueAt: Date
    public var isCompleted: Bool
    public var completedAt: Date?
    public var notificationIdentifier: String

    public init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        dueAt: Date,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        notificationIdentifier: String? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.dueAt = dueAt
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.notificationIdentifier = notificationIdentifier ?? "hermes-lens-reminder-\(id.uuidString)"
    }
}

public struct HermesHealth: Codable, Hashable, Sendable {
    public var isHealthy: Bool
    public var detail: String

    public init(isHealthy: Bool, detail: String) {
        self.isHealthy = isHealthy
        self.detail = detail
    }
}

/// `GET v1/lens/config`. The app reads only what it needs; unknown fields are
/// ignored and missing ones fall back to "live voice off".
public struct HermesLensConfiguration: Codable, Hashable, Sendable {
    public struct Voice: Codable, Hashable, Sendable {
        public var nativeAudioEnabled: Bool
        public var nativeAudioProtocol: String

        public init(nativeAudioEnabled: Bool = false, nativeAudioProtocol: String = "") {
            self.nativeAudioEnabled = nativeAudioEnabled
            self.nativeAudioProtocol = nativeAudioProtocol
        }

        private enum CodingKeys: String, CodingKey { case nativeAudioEnabled, nativeAudioProtocol }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nativeAudioEnabled = try container.decodeIfPresent(Bool.self, forKey: .nativeAudioEnabled) ?? false
            nativeAudioProtocol = try container.decodeIfPresent(String.self, forKey: .nativeAudioProtocol) ?? ""
        }
    }

    public var build: Int?
    public var voice: Voice

    public init(build: Int? = nil, voice: Voice = Voice()) {
        self.build = build
        self.voice = voice
    }

    private enum CodingKeys: String, CodingKey { case build, voice }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        build = try container.decodeIfPresent(Int.self, forKey: .build)
        voice = try container.decodeIfPresent(Voice.self, forKey: .voice) ?? Voice()
    }

    /// Used until the server answers: live voice stays off.
    public static let fallback = HermesLensConfiguration()

    /// True when the server offers the native voice protocol this app speaks.
    public var supportsNativeVoice: Bool {
        voice.nativeAudioEnabled && voice.nativeAudioProtocol == LunaNativeVoice.protocolName
    }
}
