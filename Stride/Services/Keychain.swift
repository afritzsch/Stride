import Foundation
import Security

/// One generic-password item in this device's Keychain (not synced, readable after the first unlock).
nonisolated struct KeychainItem: Sendable {
    var service: String
    var account: String

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Replaces the stored value. Returns false when the Keychain refused it (the value then isn't kept across launches).
    @discardableResult
    func save(_ data: Data) -> Bool {
        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        // Update in place so a failed write doesn't also lose the previous value.
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            attributes.merge(query) { $1 }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
