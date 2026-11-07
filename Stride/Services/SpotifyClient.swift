import CryptoKit
import Foundation

/// Spotify's Web API for playlists: the athlete's top, recently played and saved tracks, and creating a playlist.
/// Authorization is the code flow with PKCE (no client secret). The athlete registers their own app at
/// developer.spotify.com and enters its Client ID in Settings; since February 2026 a Development Mode app needs the
/// owner to have Premium and allows 5 users. Spotify only accepts https or loopback redirect URIs, so `SpotifyLogin`
/// catches the redirect on 127.0.0.1 inside the app.
nonisolated struct SpotifyClient: Sendable {
    var clientID: String
    var accessToken: String
    var session: URLSession = .shared

    static let apiURL = URL(string: "https://api.spotify.com/v1/")!
    static let authorizeURL = URL(string: "https://accounts.spotify.com/authorize")!
    static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    static let redirectPort: UInt16 = 43821
    static let redirectURI = "http://127.0.0.1:\(redirectPort)/callback"
    static let scopes = ["user-top-read", "user-read-recently-played", "user-library-read", "playlist-modify-private", "playlist-modify-public"]
    private static let requestTimeout: TimeInterval = 30

    enum Failure: LocalizedError, Equatable {
        case notAuthorized
        case notAllowed(String?)
        case rateLimited
        case server(Int)
        case login(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Spotify signed Stride out. Connect Spotify again in Settings."
            case .notAllowed(let message):
                "Spotify refused this\(message.map { " (\($0))" } ?? ""). Check that your Spotify app's owner has Premium and that your account is listed under User Management in the Spotify developer dashboard."
            case .rateLimited: "Spotify is limiting requests right now. Try again in a few minutes."
            case .server(let status): "Spotify answered with an error (\(status))."
            case .login(let reason): reason
            }
        }
    }

    // MARK: Authorization

    static func authorizationURL(clientID: String, challenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
        ]
        return components.url!
    }

    /// The code from `GET /callback?code=…&state=…`, an error from `?error=…`, or nil for other requests (e.g. a favicon).
    static func callback(request: String, state: String) -> Result<String, Error>? {
        guard let line = request.split(separator: "\r\n").first, line.hasPrefix("GET ") else { return nil }
        let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard let components = URLComponents(string: target), components.path == "/callback" else { return nil }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
        guard items["state"] == state else { return .failure(Failure.login("Spotify's answer didn't match this login. Try again.")) }
        if let error = items["error"] {
            return .failure(error == "access_denied" ? CancellationError() : Failure.login("Spotify refused the login (\(error))."))
        }
        guard let code = items["code"], !code.isEmpty else { return .failure(Failure.login("Spotify sent no login code.")) }
        return .success(code)
    }

    static func exchange(code: String, verifier: String, clientID: String, session: URLSession = .shared) async throws -> SpotifyTokens {
        try await token([
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": clientID, "code_verifier": verifier,
        ], previous: nil, session: session)
    }

    static func refresh(_ tokens: SpotifyTokens, clientID: String, session: URLSession = .shared) async throws -> SpotifyTokens {
        try await token(["grant_type": "refresh_token", "refresh_token": tokens.refreshToken, "client_id": clientID], previous: tokens, session: session)
    }

    private static func token(_ form: [String: String], previous: SpotifyTokens?, session: URLSession) async throws -> SpotifyTokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(form)
        request.timeoutInterval = requestTimeout
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // A revoked or expired refresh token, or a wrong Client ID / redirect URI.
            if status == 400 || status == 401 {
                let reason = (try? JSONDecoder().decode(TokenError.self, from: data)).map { $0.error_description ?? $0.error }
                throw previous == nil ? Failure.login("Spotify didn't accept the login\(reason.map { " (\($0))" } ?? ""). Check the Client ID and that the redirect URI is \(redirectURI).") : Failure.notAuthorized
            }
            throw Failure.server(status)
        }
        return try decodeTokens(data, previous: previous, now: .now)
    }

    /// A token response. Spotify may leave out the refresh token when refreshing; the previous one then stays valid.
    static func decodeTokens(_ data: Data, previous: SpotifyTokens?, now: Date) throws -> SpotifyTokens {
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refresh = response.refresh_token ?? previous?.refreshToken else { throw Failure.notAuthorized }
        // A minute early, so a request never starts with a token about to expire.
        return SpotifyTokens(accessToken: response.access_token, refreshToken: refresh, expiresAt: now.addingTimeInterval(TimeInterval(response.expires_in - 60)))
    }

    static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
    }

    // MARK: Reading

    func displayName() async throws -> String {
        let me: Me = try await get("me")
        return me.display_name?.nilIfEmpty ?? me.id
    }

    /// `range`: short_term (~4 weeks), medium_term (~6 months) or long_term.
    func topTracks(range: String) async throws -> [Track] {
        let page: Page<Track> = try await get("me/top/tracks", query: ["time_range": range, "limit": "50"])
        return page.items
    }

    func recentlyPlayed() async throws -> [Play] {
        let page: Page<Play> = try await get("me/player/recently-played", query: ["limit": "50"])
        return page.items
    }

    /// Liked songs, newest first, up to `pages` × 50.
    func savedTracks(pages: Int) async throws -> [Saved] {
        var saved: [Saved] = []
        for page in 0..<pages {
            let response: Page<Saved> = try await get("me/tracks", query: ["limit": "50", "offset": "\(page * 50)"])
            saved += response.items
            if response.next == nil { break }
        }
        return saved
    }

    /// An artist's genres. Spotify removed the batch artists endpoint for Development Mode apps and marks `genres`
    /// deprecated, so this is one request per artist and may come back empty.
    func genres(ofArtist id: String) async throws -> [String] {
        let artist: Artist = try await get("artists/\(id)")
        return artist.genres ?? []
    }

    // MARK: Writing

    /// Creates a private playlist and adds the tracks (Spotify URIs). Returns its link.
    func createPlaylist(name: String, description: String, uris: [String]) async throws -> URL {
        let created: CreatedPlaylist = try await send("me/playlists", body: ["name": name, "description": description, "public": false])
        for chunk in stride(from: 0, to: uris.count, by: 100).map({ Array(uris[$0..<min($0 + 100, uris.count)]) }) {
            let _: Snapshot = try await send("playlists/\(created.id)/items", body: ["uris": chunk])
        }
        return created.external_urls.spotify.flatMap(URL.init(string:)) ?? URL(string: "https://open.spotify.com/playlist/\(created.id)")!
    }

    // MARK: Requests

    private func get<Response: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> Response {
        var components = URLComponents(url: Self.apiURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return try await perform(URLRequest(url: components.url!))
    }

    private func send<Response: Decodable>(_ path: String, body: [String: Any]) async throws -> Response {
        var request = URLRequest(url: Self.apiURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        var request = request
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.requestTimeout
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: break
        case 401: throw Failure.notAuthorized
        case 403: throw Failure.notAllowed((try? JSONDecoder().decode(APIError.self, from: data))?.error.message)
        case 429: throw Failure.rateLimited
        default: throw Failure.server(status)
        }
        return try Self.decoder.decode(Response.self, from: data)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // played_at has milliseconds, added_at doesn't.
            if let date = try? Date(text, strategy: .iso8601) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
        }
        return decoder
    }()

    // MARK: Wire format (snake_case as in the API)

    struct Track: Decodable, Sendable {
        struct ArtistRef: Decodable, Sendable {
            var id: String?
            var name: String
        }
        var id: String?
        var uri: String
        var name: String
        var duration_ms: Int
        var artists: [ArtistRef]
        var is_local: Bool?
    }

    struct Play: Decodable, Sendable {
        var track: Track
        var played_at: Date
    }

    struct Saved: Decodable, Sendable {
        var track: Track
        var added_at: Date
    }

    private struct Page<Item: Decodable>: Decodable {
        var items: [Item]
        var next: String?
    }

    private struct Me: Decodable {
        var id: String
        var display_name: String?
    }

    private struct Artist: Decodable {
        var genres: [String]?
    }

    private struct CreatedPlaylist: Decodable {
        struct Links: Decodable { var spotify: String? }
        var id: String
        var external_urls: Links
    }

    private struct Snapshot: Decodable {
        var snapshot_id: String?
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Int
        var refresh_token: String?
    }

    private struct TokenError: Decodable {
        var error: String
        var error_description: String?
    }

    private struct APIError: Decodable {
        struct Body: Decodable { var message: String? }
        var error: Body
    }
}

nonisolated struct SpotifyTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    func isExpired(now: Date = .now) -> Bool { now >= expiresAt }
}

/// PKCE (RFC 7636): a random verifier kept in the app, and its SHA-256 challenge sent with the login.
nonisolated enum SpotifyPKCE {
    static func verifier() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<64).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

nonisolated enum SpotifyKeychain {
    private static let item = KeychainItem(service: "Stride.spotify", account: "tokens")

    static func load() -> SpotifyTokens? {
        item.load().flatMap { try? JSONDecoder().decode(SpotifyTokens.self, from: $0) }
    }

    @discardableResult
    static func save(_ tokens: SpotifyTokens) -> Bool {
        (try? JSONEncoder().encode(tokens)).map(item.save) ?? false
    }

    static func delete() { item.delete() }
}

/// Turns what Spotify knows about the athlete's listening into `LibrarySong`s for `PlaylistBuilder`. Spotify has no
/// play counts, so `playCount` holds taste points instead: rank in the 4-week and 6-month top tracks, plays among the
/// last 50, and being a liked song. `lastPlayed` comes from recently played, so a song heard during a workout is
/// still recognised.
nonisolated enum SpotifyLibrary {
    static func songs(
        shortTerm: [SpotifyClient.Track],
        mediumTerm: [SpotifyClient.Track],
        recent: [SpotifyClient.Play],
        saved: [SpotifyClient.Saved],
        genres: [String: [String]]
    ) -> [LibrarySong] {
        var songs: [String: LibrarySong] = [:]
        var order: [String] = []

        func add(_ track: SpotifyClient.Track, points: Int, played: Date? = nil, added: Date? = nil) {
            // Local files can't be added to a playlist through the API.
            guard track.is_local != true, track.uri.hasPrefix("spotify:track:") else { return }
            if songs[track.uri] == nil {
                let artistIDs = track.artists.compactMap(\.id)
                songs[track.uri] = LibrarySong(
                    id: track.uri,
                    title: track.name,
                    artist: track.artists.map(\.name).joined(separator: ", ").nilIfEmpty ?? "Unknown artist",
                    genre: artistIDs.lazy.compactMap { genres[$0]?.first }.first ?? "",
                    seconds: track.duration_ms / 1000,
                    playCount: 0, skipCount: 0, lastPlayed: nil, added: nil
                )
                order.append(track.uri)
            }
            songs[track.uri]!.playCount += points
            if let played, played > (songs[track.uri]!.lastPlayed ?? .distantPast) { songs[track.uri]!.lastPlayed = played }
            if let added { songs[track.uri]!.added = added }
        }

        for (rank, track) in shortTerm.enumerated() { add(track, points: 50 - min(rank, 49)) }
        for (rank, track) in mediumTerm.enumerated() { add(track, points: (50 - min(rank, 49)) / 2) }
        for play in recent { add(play.track, points: 5, played: play.played_at) }
        for item in saved { add(item.track, points: 3, added: item.added_at) }
        return order.compactMap { songs[$0] }
    }

    /// The artists worth a genre lookup (one request each): those with the most taste points.
    static func artistsToLookUp(shortTerm: [SpotifyClient.Track], mediumTerm: [SpotifyClient.Track], recent: [SpotifyClient.Play], saved: [SpotifyClient.Saved], limit: Int = 40) -> [String] {
        let tracks = shortTerm + mediumTerm + recent.map(\.track) + saved.map(\.track)
        let counts = Dictionary(tracks.flatMap { $0.artists.compactMap(\.id) }.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit).map(\.key)
    }
}
