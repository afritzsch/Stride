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

/// Every UserDefaults key the app uses, so a key can't drift between the place that writes it and the one that reads it.
/// The values are what earlier versions already saved: don't change them.
nonisolated enum DefaultsKey {
    static let profile = "profile"
    static let useDemoData = "useDemoData"
    static let allowPrivateCloud = "allowPrivateCloud"
    static let autoReviewWorkouts = "autoReviewWorkouts"
    static let autoReviewAttempted = "autoReviewAttempted"
    static let todayAdjustment = "todayAdjustment"
    static let scheduleSettings = "scheduleSettings"
    static let hevyAccountName = "hevyAccountName"
    static let hevyLastSync = "hevyLastSync"
    static let removedClaudeSettings = "removedClaudeSettings"
    /// Set by the earliest versions, which could use Claude; removed on first launch.
    static let legacyEngine = "engine"

    // Launch arguments (`-route chat`, see AppModel+Debug); debug builds only read them.
    static let route = "route"
    static let scrollTo = "scrollTo"
    static let planSheet = "planSheet"
    static let analyze = "analyze"
    static let fixture = "fixture"
    static let exportFixture = "exportFixture"
    static let probeModel = "probeModel"
    static let demoHevy = "demoHevy"
}

extension UserDefaults {
    /// `bool(forKey:)` also understands "YES"/"NO" strings (launch arguments arrive as strings), but returns false
    /// for a missing key; this returns `value` for that.
    func bool(forKey key: String, default value: Bool) -> Bool {
        object(forKey: key) != nil ? bool(forKey: key) : value
    }

    func decoded<Value: Decodable>(_: Value.Type, forKey key: String) -> Value? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    /// Stores the value as JSON, or removes the key for nil.
    func setEncoded(_ value: (some Encodable)?, forKey key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            removeObject(forKey: key)
            return
        }
        set(data, forKey: key)
    }
}

/// Saves Codable values as JSON files in Application Support.
nonisolated enum JSONStore {
    static let analyses = "analyses.json"
    static let runAnalyses = "run-analyses.json"
    static let archive = "history-archive.json"
    static let athletePlan = "athlete-plan.json"
    static let hevyWorkouts = "hevy-workouts.json"

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

    static func delete(_ file: String) {
        try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: file))
    }

    /// Returns false (after printing why) when the file couldn't be written, so callers can record it.
    @discardableResult
    static func save(_ value: some Encodable, to file: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(
                to: URL.applicationSupportDirectory.appending(path: file),
                options: [.atomic, .completeFileProtection]
            )
            return true
        } catch {
            print("Stride: failed to save \(file): \(error)")
            return false
        }
    }
}

extension HealthFixture {
    /// Fixture dates are ISO 8601, so exports are readable and stable.
    nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
