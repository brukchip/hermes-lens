import Foundation
import Testing
@testable import HermesLensCore

private let token = "fixture-token-0123456789abcdef"

/// Builds a code the way `hermes lens setup` does: HL1- + unpadded base64url of the JSON.
private func code(server: String = "https://lens.example.test", token: String = token, padded: Bool = false) -> String {
    let json = try! JSONSerialization.data(withJSONObject: ["s": server, "t": token], options: [.sortedKeys])
    var text = json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    if !padded { while text.hasSuffix("=") { text.removeLast() } }
    return "HL1-" + text
}

@Test func aValidSetupCodeGivesTheServerAndToken() throws {
    let parsed = try #require(LunaSetupCode.parse("  \n" + code() + "\n "))
    #expect(parsed.server == URL(string: "https://lens.example.test"))
    #expect(parsed.token == token)
}

@Test func aSetupLinkIsAcceptedLikeTheBareCode() throws {
    let link = "hermeslens://setup?code=" + code()
    let parsed = try #require(LunaSetupCode.parse(link))
    #expect(parsed.token == token)
    let url = try #require(URL(string: link))
    #expect(LunaSetupCode.isSetupLink(url))
    #expect(LunaSetupCode.parse(link: url) == parsed)
}

@Test func aPaddedCodeIsAccepted() throws {
    // Find a token length whose encoding needs padding, so the test really covers it.
    let padded = (0..<3).map { code(token: token + String(repeating: "x", count: $0), padded: true) }
        .first { $0.hasSuffix("=") }
    let text = try #require(padded)
    #expect(LunaSetupCode.parse(text) != nil)
}

@Test func setupCodesThatBreakTheFormatAreRejected() {
    #expect(LunaSetupCode.parse("HL2-" + code().dropFirst(4)) == nil)          // wrong prefix
    #expect(LunaSetupCode.parse(String(code().dropFirst(4))) == nil)          // no prefix
    #expect(LunaSetupCode.parse(code(server: "http://lens.example.test")) == nil)
    #expect(LunaSetupCode.parse(code(server: "lens.example.test")) == nil)
    #expect(LunaSetupCode.parse(code(server: "https://user:pw@lens.example.test")) == nil)
    #expect(LunaSetupCode.parse(code(token: "too-short-token")) == nil)        // under 24
    #expect(LunaSetupCode.parse(code(token: String(repeating: "a", count: 257))) == nil)
    #expect(LunaSetupCode.parse(code(token: "tökén-with-non-ascii-characters")) == nil)
    #expect(LunaSetupCode.parse(code(token: "a token with spaces in it, 24+")) == nil)
    #expect(LunaSetupCode.parse(code(token: String(repeating: "a", count: 256))) != nil)
    #expect(LunaSetupCode.parse(code(token: String(repeating: "a", count: 24))) != nil)
}

@Test func junkIsNotASetupCode() {
    for junk in ["", "   ", "HL1-", "HL1-!!!!", "HL1-" + Data("not json".utf8).base64EncodedString(),
                 "HL1-" + Data(#"{"s":"https://a.test"}"#.utf8).base64EncodedString(),
                 "https://lens.example.test/setup?code=" + code(), "hermeslens://other?code=" + code(),
                 "hermeslens://setup", "hello", String(repeating: "A", count: 10_000)] {
        #expect(LunaSetupCode.parse(junk) == nil, "\(junk.prefix(40))")
    }
}

@Test func theConfirmationNamesHostAndPort() throws {
    #expect(LunaSetupCode.parse(code())?.displayHost == "lens.example.test")
    #expect(LunaSetupCode.parse(code(server: "https://lens.example.test:8443/base"))?.displayHost == "lens.example.test:8443")
}

@Test func anOverlongSetupLinkIsRejectedLikeAnOverlongPaste() throws {
    let link = try #require(URL(string: "hermeslens://setup?code=" + code() + "&pad=" + String(repeating: "x", count: 5_000)))
    #expect(LunaSetupCode.parse(link: link) == nil)
}

@Test func onlySetupLinksAreTreatedAsSetup() throws {
    #expect(!LunaSetupCode.isSetupLink(try #require(URL(string: "hermeslens://?metaWearablesAction=register"))))
    #expect(!LunaSetupCode.isSetupLink(try #require(URL(string: "https://setup/?code=x"))))
    #expect(LunaSetupCode.isSetupLink(try #require(URL(string: "hermeslens://setup?code=bad"))))
    #expect(LunaSetupCode.parse(link: try #require(URL(string: "hermeslens://setup?code=bad"))) == nil)
}
