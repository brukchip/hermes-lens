import Foundation

/// A contact Luna read, usually from a business card, for the user to check and save.
/// Built from a `save_contact` tool call; nothing is saved until they tap Done in
/// Apple's new-contact sheet.
public struct LunaContactDraft: Equatable, Sendable {
    public let name: String?
    public let phone: String?
    public let email: String?
    public let company: String?
    public let jobTitle: String?
    public let website: String?
    public let address: String?

    /// Nil when the call carries neither a name nor a company.
    public init?(arguments: [String: String]) {
        func value(_ key: String, limit: Int = 200) -> String? {
            let text = (arguments[key] ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.isEmpty ? nil : String(text.prefix(limit))
        }
        name = value("name")
        company = value("company")
        guard name != nil || company != nil else { return nil }
        phone = value("phone", limit: 40)
        email = value("email").flatMap { $0.contains("@") && !$0.contains(" ") ? $0 : nil }
        jobTitle = value("job_title")
        website = value("website")
        address = value("address", limit: 300)
    }

    /// What Luna and the card call this contact.
    public var title: String { name ?? company ?? "" }
}
