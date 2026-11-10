import Foundation

/// Build-time defaults from Info.plist (set in project.yml).
enum HermesAppEnvironment {
    /// Optional server address baked into a build. Empty by default: the user adds
    /// their own Hermes server during onboarding or in Settings.
    static var defaultBridgeURL: String {
        (Bundle.main.object(forInfoDictionaryKey: "HermesDefaultBridgeURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var usesMocksByDefault: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "HermesUsesMocksByDefault") else {
            return false
        }
        if let boolean = value as? Bool { return boolean }
        if let string = value as? String {
            return ["yes", "true", "1"].contains(string.lowercased())
        }
        return false
    }
}
