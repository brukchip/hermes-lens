import Foundation

// The Wi-Fi half of bringing a HeyCyan photo to the phone, as documented by the community
// (not yet tried on hardware by this app): in transfer mode the glasses run a plain HTTP server
// on their own Wi-Fi network. `GET /files/media.config` lists the file names, one per line;
// `GET /files/<name>` returns a file. Pure Swift so it can be tested without a network.

/// Where the glasses' HTTP server may be.
///
/// The glasses have no Bluetooth pairing, so anything nearby can pretend to be them and report
/// any address. The app therefore fetches only from a private (RFC 1918) address inside the
/// subnet the phone's Wi-Fi is on right now (`HeyCyanPhoneSubnet`): the glasses' own network
/// once the user joined it. Never a public address, never another network.
public enum HeyCyanGlassesAddress {
    /// The address the L802 reported for its own hotspot (event 0x73/08, `c0 a8 1f 01`). Tried
    /// right after a reported address.
    public static let knownGlassesAddress = "192.168.31.1"

    /// Four decimal octets, not the "any" or broadcast address.
    public static func isUsableIPv4(_ text: String) -> Bool {
        guard let octets = octets(text) else { return false }
        return octets != [0, 0, 0, 0] && octets != [255, 255, 255, 255]
    }

    /// A private-range IPv4 address (RFC 1918: 10/8, 172.16/12, 192.168/16).
    public static func isPrivateIPv4(_ text: String) -> Bool {
        guard isUsableIPv4(text), let o = octets(text) else { return false }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
    }

    /// The addresses to try, in order: what the glasses reported, then `knownGlassesAddress`.
    /// Only addresses inside `phone`, the subnet the phone's Wi-Fi is on, are kept, so nothing
    /// is asked while the phone is still on another network (or on none).
    public static func candidates(reported: String?, phone: HeyCyanPhoneSubnet?) -> [String] {
        guard let phone else { return [] }
        var result: [String] = []
        for address in [reported, knownGlassesAddress].compactMap({ $0 })
        where phone.contains(address) && !result.contains(address) {
            result.append(address)
        }
        return result
    }

    /// `http://<host>/files/media.config`.
    public static func mediaListURL(host: String) -> URL? { fileURL(host: host, name: "media.config") }

    /// `http://<host>/files/<name>`, for a private IPv4 host and a safe file name only.
    public static func fileURL(host: String, name: String) -> URL? {
        guard isPrivateIPv4(host), HeyCyanMediaList.isSafeName(name) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.path = "/files/" + name
        return components.url
    }

    static func octets(_ text: String) -> [UInt8]? {
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

/// The subnet the phone's Wi-Fi is on (its address and netmask). Nil when the phone's address
/// is not private or the netmask is not a real one with room for other hosts.
public struct HeyCyanPhoneSubnet: Equatable, Sendable {
    let address: UInt32
    let mask: UInt32

    public init?(address: String, netmask: String) {
        guard HeyCyanGlassesAddress.isPrivateIPv4(address), let a = Self.value(address), let m = Self.value(netmask)
        else { return nil }
        // A real netmask is contiguous ones then zeros; /31 and /32 leave no room for the glasses.
        guard m != 0, (~m) & (~m &+ 1) == 0, ~m >= 3 else { return nil }
        self.address = a
        self.mask = m
    }

    /// A private address of another host in this subnet: not the phone itself, not the
    /// subnet's network or broadcast address.
    public func contains(_ host: String) -> Bool {
        guard HeyCyanGlassesAddress.isPrivateIPv4(host), let h = Self.value(host) else { return false }
        let network = address & mask
        return h & mask == network && h != network && h != network | ~mask && h != address
    }

    static func value(_ text: String) -> UInt32? {
        HeyCyanGlassesAddress.octets(text).map { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    }
}

/// The glasses' file list and the choice of photo to download.
public enum HeyCyanMediaList {
    /// A photo larger than this is not downloaded.
    public static let maximumPhotoBytes = 15 * 1024 * 1024
    /// `media.config` larger than this is not read.
    public static let maximumListBytes = 256 * 1024

    /// Characters a file list never holds: markup (a router's or captive portal's HTML page
    /// answers any path with 200), quotes and braces (JSON), and U+FFFD (bytes that were not
    /// UTF-8).
    static let nonListCharacters: Set<Unicode.Scalar> = ["<", ">", "\"", "{", "}", "\u{FFFD}"]

    /// The file names in `media.config`: one per line, blank lines skipped. A line holding a
    /// path keeps only its last part; a line with ".." and unsafe names are dropped. Nil when
    /// the text is not a file list at all (`nonListCharacters`, or a control character other
    /// than a line break or tab): whatever answered is not the glasses.
    public static func fileNames(in text: String) -> [String]? {
        let lineBreaksAndTab: Set<Unicode.Scalar> = ["\n", "\r", "\t"]
        for scalar in text.unicodeScalars {
            if nonListCharacters.contains(scalar) { return nil }
            if scalar.properties.generalCategory == .control, !lineBreaksAndTab.contains(scalar) { return nil }
        }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
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
/// glasses' HTTP server every `pollInterval` until it lists a photo or `maximumWait` has passed.
/// Only an address inside the phone's current subnet is asked (`HeyCyanGlassesAddress
/// .candidates`), so polls while the phone is still on its usual Wi-Fi count as unanswered.
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

    /// One poll's result: an answer (a file list naming a photo) moves to `connected`; no
    /// answer after `maximumWait` moves to `gaveUp`. Ignored unless waiting.
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
