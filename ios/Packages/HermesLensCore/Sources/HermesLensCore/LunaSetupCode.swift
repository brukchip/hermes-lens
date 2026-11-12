import Foundation

/// The setup code `hermes lens setup` prints (and puts in a QR code), so nobody has to type
/// the server address and the long access token.
///
/// Format: `HL1-` + base64url (padding optional) of the UTF-8 JSON
/// `{"s":"<server address>","t":"<token>"}`. The QR code holds the link
/// `hermeslens://setup?code=HL1-…`. A code is accepted only when `s` is an https URL and
/// `t` is 24 to 256 printable ASCII characters (no spaces).
///
/// The code carries the token: never log it, the link or the decoded values.
public struct LunaSetupCode: Equatable, Sendable {
    public let server: URL
    public let token: String

    public static let prefix = "HL1-"
    /// The host of the setup link (`<scheme>://setup?code=…`).
    public static let linkHost = "setup"
    public static let invalidMessage = "That isn't a valid Hermes Lens setup code. Run hermes lens setup on your "
        + "server and copy the code again."

    /// A pasted code or setup link, with surrounding whitespace and newlines; nil when invalid.
    public static func parse(_ text: String) -> LunaSetupCode? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4_096 else { return nil }
        if text.hasPrefix(prefix) { return decode(text) }
        guard let url = URL(string: text), isSetupLink(url) else { return nil }
        return code(in: url).flatMap(decode)
    }

    /// A link meant for setup (`<scheme>://setup?…`), valid or not. Other links to the app
    /// (the glasses' callbacks) are not setup links.
    public static func isSetupLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https" else { return false }
        return url.host?.lowercased() == linkHost
    }

    /// The code in a setup link; nil when the link carries none.
    public static func parse(link url: URL) -> LunaSetupCode? {
        guard isSetupLink(url) else { return nil }
        return code(in: url).flatMap(decode)
    }

    private static func code(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "code" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode(_ code: String) -> LunaSetupCode? {
        guard code.hasPrefix(prefix) else { return nil }
        var body = String(code.dropFirst(prefix.count))
        while body.hasSuffix("=") { body.removeLast() }
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !body.isEmpty, body.allSatisfy(alphabet.contains), body.count % 4 != 1 else { return nil }
        var base64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = object["s"] as? String, let token = object["t"] as? String,
              let url = URL(string: server.trimmingCharacters(in: .whitespaces)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              (24...256).contains(token.count),
              token.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) })
        else { return nil }
        return LunaSetupCode(server: url, token: token)
    }
}
