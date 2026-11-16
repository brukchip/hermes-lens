import Foundation

// The Wi-Fi half of bringing a HeyCyan photo to the phone, as documented by the community
// (not yet tried on hardware by this app): in transfer mode the glasses run a plain HTTP server
// on their own Wi-Fi network. `GET /files/media.config` lists the file names, one per line;
// `GET /files/<name>` returns a file. Pure Swift so it can be tested without a network.

/// Where the glasses' HTTP server may be.
public enum HeyCyanGlassesAddress {
    /// The address the L802 reported for its own hotspot (event 0x73/08, `c0 a8 1f 01`). Tried
    /// right after a reported address.
    public static let knownGlassesAddress = "192.168.31.1"

    /// Tried when the glasses never report their address: common addresses of a device that
    /// runs its own network (Wi-Fi Direct groups, Android-style hotspots, small access points).
    public static let commonCandidates = ["192.168.49.1", "192.168.43.1", "192.168.4.1", "10.0.0.1", "192.168.1.1"]

    /// Four decimal octets, not the "any" or broadcast address.
    public static func isUsableIPv4(_ text: String) -> Bool {
        guard let octets = octets(text) else { return false }
        return octets != [0, 0, 0, 0] && octets != [255, 255, 255, 255]
    }

    /// The usual gateway of the network the phone joined: the first host address of its subnet
    /// (`address & netmask` + 1). Nil for malformed input or a subnet too small to have one.
    public static func firstHost(address: String, netmask: String) -> String? {
        guard let a = octets(address), let m = octets(netmask) else { return nil }
        let addressValue = a.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let maskValue = m.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        // A real netmask is contiguous ones then zeros; /31 and /32 have no separate gateway.
        guard maskValue != 0, (~maskValue) & (~maskValue &+ 1) == 0, ~maskValue >= 3 else { return nil }
        let host = (addressValue & maskValue) + 1
        guard host != addressValue else { return nil }
        let result = (0..<4).reversed().map { String((host >> (UInt32($0) * 8)) & 0xFF) }.joined(separator: ".")
        return isUsableIPv4(result) ? result : nil
    }

    /// The addresses to try, in order: what the glasses reported, `knownGlassesAddress`, the
    /// joined network's gateway, then `commonCandidates`. Unusable and repeated addresses are
    /// left out.
    public static func candidates(reported: String?, gateway: String?) -> [String] {
        var result: [String] = []
        for address in [reported, knownGlassesAddress, gateway].compactMap({ $0 }) + commonCandidates
        where isUsableIPv4(address) && !result.contains(address) {
            result.append(address)
        }
        return result
    }

    /// `http://<host>/files/media.config`.
    public static func mediaListURL(host: String) -> URL? { fileURL(host: host, name: "media.config") }

    /// `http://<host>/files/<name>`, for a usable IPv4 host and a safe file name only.
    public static func fileURL(host: String, name: String) -> URL? {
        guard isUsableIPv4(host), HeyCyanMediaList.isSafeName(name) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.path = "/files/" + name
        return components.url
    }

    private static func octets(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = UInt8(part) else { return nil }
            result.append(value)
        }
        return result
    }
}

/// The glasses' file list and the choice of photo to download.
public enum HeyCyanMediaList {
    /// A photo larger than this is not downloaded.
    public static let maximumPhotoBytes = 15 * 1024 * 1024
    /// `media.config` larger than this is not read.
    public static let maximumListBytes = 256 * 1024

    /// The file names in `media.config`: one per line, blank lines skipped. A line holding a
    /// path keeps only its last part; a line with ".." and unsafe names are dropped.
    public static func fileNames(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.contains("..") else { return nil }
            let name = trimmed.split(separator: "/").last.map(String.init) ?? ""
            return isSafeName(name) ? name : nil
        }
    }

    /// A plain file name: no path separators, no "..", no control characters, not too long.
    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 128, name != ".", !name.contains("..") else { return false }
        return !name.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0.properties.generalCategory == .control }
    }

    /// A JPEG by its name (`.jpg` or `.jpeg`, any case).
    public static func isPhoto(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
    }

    /// The newest photo: names usually hold a capture timestamp (e.g. `20250102155119977.JPG`),
    /// so the photo with the latest one wins; without timestamps, the last photo in the list.
    public static func newestPhoto(in names: [String]) -> String? {
        let photos = names.filter(isPhoto)
        let stamped = photos.compactMap { name in timestamp(of: name).map { (name, $0) } }
        guard !stamped.isEmpty else { return photos.last }
        // Equal-length digit strings compare like numbers; a longer stamp counts as later.
        return stamped.reduce(stamped[0]) { best, next in
            (next.1.count, next.1) >= (best.1.count, best.1) ? next : best
        }.0
    }

    /// The longest run of at least 8 digits in a name (a date and time), or nil.
    static func timestamp(of name: String) -> String? {
        var best = ""
        var current = ""
        for character in name {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else {
                if current.count > best.count { best = current }
                current = ""
            }
        }
        if current.count > best.count { best = current }
        return best.count >= 8 ? best : nil
    }

    /// The bytes start like a JPEG (`FF D8 FF`).
    public static func looksLikeJPEG<Bytes: Collection>(_ bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
        Array(bytes.prefix(3)) == [0xFF, 0xD8, 0xFF]
    }
}

/// How a photo comes from the glasses, by where it is asked for and what the build may do.
///
/// Joining the glasses' Wi-Fi from the app needs the Hotspot Configuration entitlement, which
/// personal (free) developer teams cannot use. Without it the user joins the network in
/// Settings › Wi-Fi while the app shows its name and password, which is fine because the Photo
/// flow and the Settings test happen with the user looking at the screen. (A call's look does
/// not use Wi-Fi: it pulls the small AI photo over Bluetooth, `HeyCyanAIPhoto`.)
public enum HeyCyanFetchPlan: Equatable, Sendable {
    /// The app joins the glasses' Wi-Fi itself (one system prompt).
    case automaticJoin(budgetSeconds: Int)
    /// The user joins it in Settings › Wi-Fi; the app waits for the glasses to answer.
    case manualJoin(budgetSeconds: Int)

    public static let automaticBudgetSeconds = 45
    /// The photo (up to ~10 s), the credentials (up to 6 s), the 3-minute join wait and the
    /// download.
    public static let manualBudgetSeconds = 220

    public static func plan(automaticJoinAvailable: Bool) -> HeyCyanFetchPlan {
        automaticJoinAvailable ? .automaticJoin(budgetSeconds: automaticBudgetSeconds)
            : .manualJoin(budgetSeconds: manualBudgetSeconds)
    }

    /// For `heycyan.transfer stage=plan result=…`.
    public var traceLabel: String {
        switch self {
        case .automaticJoin: "automatic_join"
        case .manualJoin: "manual_join"
        }
    }

    /// The whole budget in seconds, counted from the request.
    public var budgetSeconds: Int {
        switch self {
        case .automaticJoin(let seconds), .manualJoin(let seconds): seconds
        }
    }
}

/// The manual join card: the app shows the glasses' Wi-Fi name and password and asks the
/// glasses' HTTP server every `pollInterval` until it answers or `maximumWait` has passed.
/// The glasses' hotspot is hidden, so the user types its name in Settings › Wi-Fi › Other…:
/// that takes a while, hence 3 minutes.
/// Times are seconds on one monotonic clock.
public struct HeyCyanManualJoin: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The card asks the user to join; the app is polling.
        case waitingForJoin
        /// The glasses answered on Wi-Fi; the photo is coming over.
        case connected
        /// Done (the photo came over or the download failed): the user may switch back.
        case finished
        /// The glasses never answered in time, or the attempt was stopped.
        case gaveUp
    }

    public static let pollInterval: TimeInterval = 1.5
    /// Each poll's HTTP timeout: shorter than the interval, so polls never pile up.
    public static let probeTimeout: TimeInterval = 1.2
    public static let maximumWait: TimeInterval = 180

    public let startedAt: TimeInterval
    public private(set) var phase: Phase = .waitingForJoin
    public private(set) var polls = 0

    public init(startedAt: TimeInterval) {
        self.startedAt = startedAt
    }

    /// Whether to poll at `now`: still waiting and within `maximumWait`.
    public func shouldPoll(at now: TimeInterval) -> Bool {
        phase == .waitingForJoin && now - startedAt < Self.maximumWait
    }

    /// The pause after a poll that started at `pollStartedAt` and ended at `now`, so polls
    /// start every `pollInterval`.
    public func delayBeforeNextPoll(pollStartedAt: TimeInterval, now: TimeInterval) -> TimeInterval {
        max(0, Self.pollInterval - (now - pollStartedAt))
    }

    /// One poll's result: an answer moves to `connected`; no answer after `maximumWait`
    /// moves to `gaveUp`. Ignored unless waiting.
    public mutating func recordPoll(answered: Bool, at now: TimeInterval) {
        guard phase == .waitingForJoin else { return }
        polls += 1
        if answered {
            phase = .connected
        } else if now - startedAt >= Self.maximumWait {
            phase = .gaveUp
        }
    }

    /// The transfer ended: a connected card is finished, a waiting one gave up.
    public mutating func end() {
        switch phase {
        case .connected: phase = .finished
        case .waitingForJoin: phase = .gaveUp
        case .finished, .gaveUp: break
        }
    }
}
