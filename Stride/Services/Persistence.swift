import Foundation
import Security

nonisolated enum KeychainStore {
    private static let service = "Stride.anthropic"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        delete(account)
        guard !value.isEmpty else { return true }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Saves Codable values as JSON files in Application Support.
nonisolated enum JSONStore {
    static let analyses = "analyses.json"
    static let runAnalyses = "run-analyses.json"

    static func load<Value: Decodable>(_: Value.Type, from file: String) -> Value? {
        guard let data = try? Data(contentsOf: URL.applicationSupportDirectory.appending(path: file)) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    static func save(_ value: some Encodable, to file: String) {
        do {
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(
                to: URL.applicationSupportDirectory.appending(path: file),
                options: [.atomic, .completeFileProtection]
            )
        } catch {
            assertionFailure("Failed to save \(file): \(error)")
        }
    }
}
