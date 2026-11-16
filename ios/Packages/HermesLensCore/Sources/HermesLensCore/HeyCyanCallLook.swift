import Foundation

/// The glasses networks this iPhone has joined successfully, by paired glasses. Only the
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

/// What Luna says when a look in a call took the photo but could not bring it over. The photo
/// is saved on the glasses in every case.
public enum HeyCyanCallLookFallback: Equatable, Sendable {
    /// This iPhone has not joined the glasses' Wi-Fi yet (or the glasses now use another
    /// network): the one-time setup in You › Glasses is needed.
    case setupNeeded
    /// Time ran out while the phone was on a Wi-Fi that is not the glasses': iOS does not leave
    /// a working Wi-Fi for the glasses' network by itself.
    case onOtherWiFi
    /// Time ran out and the phone was not on any Wi-Fi: the glasses' network never came up or
    /// iOS did not join it in time.
    case notReachable
    /// Anything else (the glasses did not open their Wi-Fi, the download failed).
    case failed

    /// Why the transfer stopped, as the app knows it.
    public enum Cause: Equatable, Sendable {
        /// The glasses never answered on Wi-Fi within the budget.
        case glassesNotFound
        /// The glasses reported a network other than the remembered one.
        case networkChanged
        case other
    }

    /// `networkKnown`: the phone knew the glasses' network. `onWiFi`: the phone was on some
    /// Wi-Fi when time ran out (interface type only). `onGlassesWiFi`: that Wi-Fi was the
    /// glasses' own (its subnet holds the glasses' address).
    public static func choose(networkKnown: Bool, cause: Cause, onWiFi: Bool, onGlassesWiFi: Bool) -> Self {
        guard networkKnown, cause != .networkChanged else { return .setupNeeded }
        switch cause {
        case .glassesNotFound: return onWiFi && !onGlassesWiFi ? .onOtherWiFi : .notReachable
        case .networkChanged: return .setupNeeded
        case .other: return .failed
        }
    }

    /// The fixed code a call's look reports (`LunaCameraError`).
    public var lookCode: String {
        switch self {
        case .setupNeeded: "heycyan_look_setup_needed"
        case .onOtherWiFi: "heycyan_look_other_wifi"
        case .notReachable: "heycyan_look_not_reachable"
        case .failed: "heycyan_look_failed"
        }
    }

    /// What the user should hear (and read on screen).
    public var sentence: String {
        switch self {
        case .setupNeeded:
            "I took the photo; it's saved on the glasses. To bring photos over during calls, do the one-time setup in You › Glasses: Take and fetch a test photo."
        case .onOtherWiFi:
            "I took the photo but couldn't bring it over. Your iPhone is probably on another Wi-Fi. It's saved on the glasses."
        case .notReachable:
            "I took the photo but couldn't bring it over: your iPhone didn't connect to the glasses' Wi-Fi in time. It's saved on the glasses."
        case .failed:
            "I took the photo but couldn't bring it over. It's saved on the glasses."
        }
    }

    /// For `heycyan.transfer stage=fallback result=…`.
    public var traceLabel: String {
        switch self {
        case .setupNeeded: "setup_needed"
        case .onOtherWiFi: "other_wifi"
        case .notReachable: "not_reachable"
        case .failed: "failed"
        }
    }
}

extension HeyCyanGlassesAddress {
    /// Whether the phone's Wi-Fi (its address and netmask) is the glasses' network: the same
    /// subnet as the glasses' reported address, or as `knownGlassesAddress` when none came.
    public static func isOnGlassesNetwork(address: String?, netmask: String?, glassesAddress: String?) -> Bool {
        guard let address, let netmask else { return false }
        let target = glassesAddress.flatMap { isUsableIPv4($0) ? $0 : nil } ?? knownGlassesAddress
        guard isUsableIPv4(address), let own = network(address: address, netmask: netmask),
              let theirs = network(address: target, netmask: netmask) else { return false }
        return own == theirs
    }
}
