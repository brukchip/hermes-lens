import Foundation

/// The glasses networks this iPhone has joined successfully, by paired glasses (remembered
/// after a successful Take and fetch; a call's look does not need it). Only the
/// network name (SSID) is kept, never its password: iOS keeps the password itself after the
/// user joined in Settings › Wi-Fi. Saved as JSON in the app's settings.
public struct HeyCyanKnownNetworks: Codable, Equatable, Sendable {
    /// SSID by the paired glasses' identifier (the app's Bluetooth identifier string).
    public private(set) var ssidByGlasses: [String: String]

    public init(ssidByGlasses: [String: String] = [:]) {
        self.ssidByGlasses = ssidByGlasses
    }

    /// The network this iPhone joined for these glasses, if any.
    public func ssid(for glassesID: String?) -> String? {
        glassesID.flatMap { ssidByGlasses[$0] }
    }

    public func knows(_ glassesID: String?) -> Bool { ssid(for: glassesID) != nil }

    /// A fetch over this network worked. An empty name or identifier is ignored.
    public mutating func remember(ssid: String, for glassesID: String?) {
        guard let glassesID, !glassesID.isEmpty, !ssid.isEmpty else { return }
        ssidByGlasses[glassesID] = ssid
    }

    public mutating func forget(_ glassesID: String?) {
        guard let glassesID else { return }
        ssidByGlasses[glassesID] = nil
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Unreadable or missing data is an empty store.
    public static func decoded(from data: Data?) -> HeyCyanKnownNetworks {
        data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
}
