import Foundation
import Security

/// Hevy's public API (https://api.hevyapp.com/docs, Hevy Pro only). The key comes from
/// https://hevy.com/settings?developer and goes in the `api-key` header.
nonisolated struct HevyClient: Sendable {
    var apiKey: String
    var session: URLSession = .shared

    static let baseURL = URL(string: "https://api.hevyapp.com/v1/")!
    /// The API's maximum for workouts and events.
    static let pageSize = 10

    nonisolated struct Account: Sendable {
        var name: String
        var isPro: Bool?
    }

    enum Event: Sendable {
        case updated(StrengthSession)
        case deleted(id: String)
    }

    enum Failure: LocalizedError {
        case rejectedKey
        case rateLimited
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .rejectedKey: "Hevy didn't accept this API key. Copy it again from hevy.com → Settings → Developer (it needs Hevy Pro)."
            case .rateLimited: "Hevy is limiting requests right now. Try again in a few minutes."
            case .server(let status): "Hevy answered with an error (\(status))."
            }
        }
    }

    func account() async throws -> Account {
        let response: UserInfoResponse = try await get("user/info")
        let name = [response.data.name, response.data.username].compactMap { $0?.nilIfEmpty }.first ?? "Hevy"
        return Account(name: name, isPro: response.data.is_pro)
    }

    /// One page of workouts, newest first.
    func workouts(page: Int) async throws -> (sessions: [StrengthSession], pageCount: Int) {
        try Self.decodeWorkouts(await data("workouts", query: ["page": "\(page)", "pageSize": "\(Self.pageSize)"]))
    }

    /// A `GET /v1/workouts` response body.
    static func decodeWorkouts(_ data: Data) throws -> (sessions: [StrengthSession], pageCount: Int) {
        let response = try decoder.decode(WorkoutsPage.self, from: data)
        return (response.workouts.map(\.session), response.page_count)
    }

    /// One page of workouts changed or deleted since the date, oldest first.
    func events(since date: Date, page: Int) async throws -> (events: [Event], pageCount: Int) {
        let since = ISO8601DateFormatter().string(from: date)
        let response: EventsPage = try await get("workouts/events", query: ["page": "\(page)", "pageSize": "\(Self.pageSize)", "since": since])
        let events: [Event] = response.events.compactMap { event in
            switch event.type {
            case "updated": event.workout.map { .updated($0.session) }
            case "deleted": event.id.map { .deleted(id: $0) }
            default: nil
            }
        }
        return (events, response.page_count)
    }

    private func get<Response: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> Response {
        try Self.decoder.decode(Response.self, from: await data(path, query: query))
    }

    private func data(_ path: String, query: [String: String]) async throws -> Data {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: break
        case 401, 403: throw Failure.rejectedKey
        case 429: throw Failure.rateLimited
        default: throw Failure.server(status)
        }
        return data
    }

    /// Hevy writes ISO 8601, with or without fractional seconds.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = plain.date(from: text) ?? fractional.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
        }
        return decoder
    }()

    // MARK: - Wire format (snake_case as in the API)

    private struct UserInfoResponse: Decodable {
        struct UserInfo: Decodable {
            var name: String?
            var username: String?
            var is_pro: Bool?
        }
        var data: UserInfo
    }

    private struct WorkoutsPage: Decodable {
        var page: Int
        var page_count: Int
        var workouts: [Workout]
    }

    private struct EventsPage: Decodable {
        struct Event: Decodable {
            var type: String
            var workout: Workout?
            var id: String?
        }
        var page: Int
        var page_count: Int
        var events: [Event]
    }

    private struct Workout: Decodable {
        struct Exercise: Decodable {
            var index: Double?
            var title: String
            var notes: String?
            var exercise_template_id: String
            var superset_id: Double?
            var sets: [Set]
        }

        struct Set: Decodable {
            var index: Double?
            var type: String?
            var weight_kg: Double?
            var reps: Double?
            var distance_meters: Double?
            var duration_seconds: Double?
            var rpe: Double?
        }

        var id: String
        var title: String?
        var description: String?
        var start_time: Date
        var end_time: Date
        var exercises: [Exercise]

        var session: StrengthSession {
            StrengthSession(
                id: id,
                title: title ?? "",
                notes: description?.nilIfEmpty,
                start: start_time,
                end: end_time,
                exercises: exercises.enumerated().map { position, exercise in
                    StrengthExercise(
                        index: exercise.index.map { Int($0) } ?? position,
                        title: exercise.title,
                        templateID: exercise.exercise_template_id,
                        notes: exercise.notes?.nilIfEmpty,
                        supersetID: exercise.superset_id.map { Int($0) },
                        sets: exercise.sets.enumerated().map { setPosition, set in
                            StrengthSet(
                                index: set.index.map { Int($0) } ?? setPosition,
                                kind: set.type.flatMap(StrengthSet.Kind.init(rawValue:)) ?? .normal,
                                weightKg: set.weight_kg,
                                reps: set.reps.map { Int($0.rounded()) },
                                distanceMeters: set.distance_meters,
                                durationSeconds: set.duration_seconds,
                                rpe: set.rpe
                            )
                        }
                    )
                }
            )
        }
    }
}

/// The Hevy API key, kept in the Keychain on this device only.
nonisolated enum HevyKeychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Stride.hevy",
        kSecAttrAccount as String: "apiKey",
    ]

    static func load() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
