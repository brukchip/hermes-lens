import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let mockHermes = "settings.mockHermes"
        static let mockGlasses = "settings.mockGlasses"
        static let bridgeURL = "settings.bridgeURL"
        static let sessionKey = "settings.sessionKey"
        static let deviceID = "settings.deviceID"
        static let cameraInCalls = "settings.cameraInCalls"
        static let keepCameraReady = "settings.keepCameraReady"
        static let developerSettings = "settings.developerSettings"
        static let onboardingComplete = "settings.onboardingComplete"
        static let compressedGlassesStream = GlassesStreamPreferences.compressedKey
        static let glassesGestures = "settings.glassesGestures"
    }

    private let defaults: UserDefaults
    private let secureStore: SecureStore

    var usesMockHermes: Bool { didSet { defaults.set(usesMockHermes, forKey: Key.mockHermes) } }
    var usesMockGlasses: Bool { didSet { defaults.set(usesMockGlasses, forKey: Key.mockGlasses) } }
    var bridgeURL: String { didSet { defaults.set(bridgeURL, forKey: Key.bridgeURL) } }
    var sessionKey: String { didSet { defaults.set(sessionKey, forKey: Key.sessionKey) } }
    /// Luna may take photos and clips with the glasses during calls (look / record).
    var allowsCameraInCalls: Bool { didSet { defaults.set(allowsCameraInCalls, forKey: Key.cameraInCalls) } }
    /// After the first look in a call, keep the glasses camera streaming so later
    /// looks are instant. Off: the camera stops after every photo.
    var keepsCameraReadyInCalls: Bool { didSet { defaults.set(keepsCameraReadyInCalls, forKey: Key.keepCameraReady) } }
    /// Shows demo and diagnostic controls (revealed by tapping the version 7 times).
    var showsDeveloperSettings: Bool { didSet { defaults.set(showsDeveloperSettings, forKey: Key.developerSettings) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboardingComplete) } }
    /// During a call: capture button = Look, hold = record, touchpad double tap = mute
    /// (or approve a card that has been shown for 1.5 s).
    var usesGlassesGestures: Bool { didSet { defaults.set(usesGlassesGestures, forKey: Key.glassesGestures) } }
    /// Developer test: ask the glasses for a compressed (HEVC) camera stream instead of raw.
    /// Raw 720p may not fit the Bluetooth link, so the glasses lower its quality.
    var usesCompressedGlassesStream: Bool {
        didSet { defaults.set(usesCompressedGlassesStream, forKey: Key.compressedGlassesStream) }
    }
    let deviceID: UUID
    var accessToken: String

    init(
        defaults: UserDefaults = .standard,
        secureStore: SecureStore = SecureStore()
    ) {
        self.defaults = defaults
        self.secureStore = secureStore

        if defaults.object(forKey: Key.mockHermes) == nil {
            defaults.set(HermesAppEnvironment.usesMocksByDefault, forKey: Key.mockHermes)
        }
        if defaults.object(forKey: Key.mockGlasses) == nil {
            defaults.set(HermesAppEnvironment.usesMocksByDefault, forKey: Key.mockGlasses)
        }

        usesMockHermes = defaults.bool(forKey: Key.mockHermes)
        usesMockGlasses = defaults.bool(forKey: Key.mockGlasses)
        allowsCameraInCalls = defaults.object(forKey: Key.cameraInCalls) as? Bool ?? true
        // Off by default: on DAT 0.9 a held stream stops delivering frames within ~15 s, so a
        // later look needed a ~12 s restart; a cold start takes ~4 s (2026-11-01).
        keepsCameraReadyInCalls = defaults.object(forKey: Key.keepCameraReady) as? Bool ?? false
        showsDeveloperSettings = defaults.bool(forKey: Key.developerSettings)
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboardingComplete)
        usesCompressedGlassesStream = defaults.bool(forKey: Key.compressedGlassesStream)
        usesGlassesGestures = defaults.object(forKey: Key.glassesGestures) as? Bool ?? true
        bridgeURL = defaults.string(forKey: Key.bridgeURL) ?? HermesAppEnvironment.defaultBridgeURL
        sessionKey = defaults.string(forKey: Key.sessionKey) ?? "hermes-lens"

        if let rawID = defaults.string(forKey: Key.deviceID), let id = UUID(uuidString: rawID) {
            deviceID = id
        } else {
            let id = UUID()
            deviceID = id
            defaults.set(id.uuidString, forKey: Key.deviceID)
        }
        accessToken = (try? secureStore.value(for: "hermes-server-token")) ?? ""
    }

    /// True once a server address and an access token are both entered.
    var hasServerConfiguration: Bool {
        !bridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveAccessToken() throws {
        try secureStore.set(accessToken, for: "hermes-server-token")
    }
}
