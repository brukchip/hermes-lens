import Foundation
import Security

enum SecureStoreError: Error {
    case unhandledStatus(OSStatus)
}

struct SecureStore: Sendable {
    private let service = Bundle.main.bundleIdentifier ?? "com.example.hermeslens"

    func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Update in place, so a failed write never erases the value already stored; add only
        // when there is none yet.
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SecureStoreError.unhandledStatus(updated) }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStoreError.unhandledStatus(status)
        }
    }

    func value(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecureStoreError.unhandledStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }
}
