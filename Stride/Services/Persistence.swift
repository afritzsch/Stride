import Foundation
import Security

/// The Anthropic API key earlier versions kept in the Keychain; only ever deleted now.
nonisolated enum LegacyKeychain {
    static func deleteAnthropicKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Stride.anthropic",
            kSecAttrAccount as String: "anthropicAPIKey",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Saves Codable values as JSON files in Application Support.
nonisolated enum JSONStore {
    static let analyses = "analyses.json"
    static let runAnalyses = "run-analyses.json"
    static let archive = "history-archive.json"

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
