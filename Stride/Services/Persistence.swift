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

    /// Updates in place so a failed write never loses the previous key. An empty value deletes it.
    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        guard !value.isEmpty else {
            delete(account)
            return true
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var attributes = query(account)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Saves Codable values as JSON files in Application Support.
nonisolated enum JSONStore {
    static let analyses = "analyses.json"
    static let runAnalyses = "run-analyses.json"

    /// nil when the file is missing or unreadable. A file that no longer decodes (e.g. after a model change)
    /// is moved aside first, so the next save doesn't overwrite the user's history.
    static func load<Value: Decodable>(_: Value.Type, from file: String) -> Value? {
        let url = URL.applicationSupportDirectory.appending(path: file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            print("Stride: couldn't decode \(file), keeping it as a backup: \(error)")
            let backup = url.appendingPathExtension("corrupt-\(Int(Date.now.timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            return nil
        }
    }

    static func save(_ value: some Encodable, to file: String) {
        do {
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(
                to: URL.applicationSupportDirectory.appending(path: file),
                options: [.atomic, .completeFileProtection]
            )
        } catch {
            print("Stride: failed to save \(file): \(error)")
        }
    }
}
