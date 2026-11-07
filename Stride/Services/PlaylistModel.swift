import Foundation
import Observation

/// A playlist for a planned session from the athlete's own music (owned by `AppModel` like `strength`): the iPhone's
/// music library or their Spotify listening, as chosen in Settings. Code picks the sections and a shortlist of real
/// songs (`PlaylistBuilder`); the on-device model only chooses among them and names the playlist. Without Apple
/// Intelligence, code picks alone. Demo data uses `DemoMusic` whatever the source.
@Observable
final class PlaylistModel {
    /// Shows the playlist sheet (the Today card's button, or the `playlist` route).
    var isShowing = false
    private(set) var playlist: WorkoutPlaylist?
    private(set) var isBuilding = false
    private(set) var isSaving = false
    private(set) var error: String?
    private(set) var notice: String?
    /// The saved playlist's link (Spotify), or a placeholder once saved to Apple Music.
    private(set) var savedURL: URL?

    var source: MusicSource {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: DefaultsKey.musicSource) }
    }
    var spotifyClientID: String {
        didSet { UserDefaults.standard.set(spotifyClientID, forKey: DefaultsKey.spotifyClientID) }
    }
    private(set) var isSpotifyConnected: Bool
    private(set) var spotifyAccountName: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var login: SpotifyLogin?
    @ObservationIgnored private var spotifyCache: (fetchedAt: Date, songs: [LibrarySong])?
    @ObservationIgnored private var genreCache: [String: [String]] = [:]
    /// How long Spotify listening is reused before it's read again.
    private static let spotifyCacheLife: TimeInterval = 3600

    init(model: AppModel) {
        self.model = model
        let defaults = UserDefaults.standard
        source = defaults.string(forKey: DefaultsKey.musicSource).flatMap(MusicSource.init) ?? .appleMusic
        spotifyClientID = defaults.string(forKey: DefaultsKey.spotifyClientID) ?? ""
        isSpotifyConnected = SpotifyKeychain.load() != nil
        spotifyAccountName = defaults.string(forKey: DefaultsKey.spotifyAccountName)
    }

    private var isDemo: Bool { model?.snapshot?.isDemo == true }
    var isSaved: Bool { savedURL != nil }

    /// Today's planned session, or the athlete's usual one on a rest day or without a plan.
    var todaysSession: PlannedDay {
        if let planned = model?.todaysPlan, !planned.isRest, planned.durationMinutes > 0 { return planned }
        return PlaylistBuilder.usualSession(recent: model?.snapshot?.workouts ?? [], now: .now)
    }

    // MARK: Building

    func build(for day: PlannedDay, on date: Date = .now) async {
        guard let model, !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }
        error = nil
        notice = nil
        savedURL = nil
        // A second try avoids the last playlist's songs.
        let avoid = Set(playlist?.songs.map(\.id) ?? [])
        let source = source

        let library: [LibrarySong]
        do {
            library = try await self.library(from: source)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            return
        }

        let segments = PlaylistBuilder.segments(for: day)
        guard !segments.isEmpty else { error = PlaylistError.restDay.localizedDescription; return }
        let workouts = model.snapshot?.workouts ?? []
        let shortlists = PlaylistBuilder.shortlists(for: segments, library: library, workouts: workouts, avoid: avoid, now: date)
        let candidates = shortlists.reduce(0) { $0 + $1.count }
        guard candidates >= PlaylistBuilder.minimumLibrary else {
            error = source == .spotify && !isDemo
                ? "Spotify gave Stride only \(candidates) songs to pick from. Listen to and like a few more songs, then try again."
                : PlaylistError.tooFewSongs(candidates).localizedDescription
                    + " In Apple Music, add songs with + / Add to Library, and turn on Settings → Apps → Music → Sync Library."
            return
        }

        var draft: PlaylistDraft?
        if let blocker = model.currentAIBlocker() {
            notice = "Picked by what you play most. \(blocker)"
        } else {
            let prompt = PlaylistBuilder.prompt(
                day: day, segments: segments, shortlists: shortlists,
                favouriteArtists: PlaylistBuilder.favouriteArtists(in: library)
            )
            do {
                draft = try await model.generate(
                    PlaylistDraft.self,
                    instructions: PlaylistBuilder.instructions,
                    fullPrompt: prompt,
                    compactPrompt: prompt,
                    options: AppleAnalyzer.precise
                ).output
            } catch {
                model.debugLog("Playlist generation failed: \(error.localizedDescription)")
                notice = "Apple Intelligence couldn't pick the songs, so Stride picked by what you play most."
            }
        }
        var built = PlaylistBuilder.assemble(day: day, date: date, segments: segments, shortlists: shortlists, draft: draft)
        built.source = source
        playlist = built
    }

    private func library(from source: MusicSource) async throws -> [LibrarySong] {
        if isDemo { return DemoMusic.library(workouts: model?.snapshot?.workouts ?? []) }
        switch source {
        case .appleMusic:
            guard await MusicLibraryService.requestAccess() else {
                throw SpotifyClient.Failure.login("Stride can't read your music library. Allow it in Settings → Apps → Stride → Media & Apple Music.")
            }
            return MusicLibraryService.songs()
        case .spotify:
            return try await spotifyLibrary()
        }
    }

    // MARK: Saving and playing

    func save() async {
        guard let playlist, !isSaving, savedURL == nil else { return }
        isSaving = true
        defer { isSaving = false }
        error = nil
        if isDemo {
            notice = "Demo data: the playlist isn't saved to \(playlist.source.title)."
            savedURL = URL(string: "https://example.com")
            return
        }
        do {
            switch playlist.source {
            case .appleMusic:
                try await MusicLibraryService.save(playlist)
                savedURL = URL(string: "music://")
            case .spotify:
                savedURL = try await withSpotify { client in
                    try await client.createPlaylist(name: playlist.name, description: playlist.note, uris: playlist.songs.map(\.id))
                }
            }
            notice = "Saved to \(playlist.source.title) as “\(playlist.name)”."
        } catch {
            self.error = "Couldn't save the playlist: \(error.localizedDescription)"
        }
    }

    /// Starts the playlist. Apple Music plays in the system player; Spotify can only be played in its app, so the
    /// playlist is saved first and the returned link opens it there.
    func play() async -> URL? {
        guard let playlist else { return nil }
        if isDemo {
            notice = "Demo data: there's nothing to play."
            return nil
        }
        switch playlist.source {
        case .appleMusic:
            MusicLibraryService.play(playlist)
            return nil
        case .spotify:
            await save()
            return savedURL
        }
    }

    // MARK: Spotify

    func connectSpotify() async throws {
        let clientID = spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw SpotifyClient.Failure.login("Enter your Spotify app's Client ID first.") }
        spotifyClientID = clientID
        let verifier = SpotifyPKCE.verifier()
        let state = UUID().uuidString
        let login = SpotifyLogin()
        self.login = login
        defer { self.login = nil }
        let code = try await login.run(
            url: SpotifyClient.authorizationURL(clientID: clientID, challenge: SpotifyPKCE.challenge(for: verifier), state: state),
            state: state
        )
        let tokens = try await SpotifyClient.exchange(code: code, verifier: verifier, clientID: clientID)
        let name = try await SpotifyClient(clientID: clientID, accessToken: tokens.accessToken).displayName()
        guard SpotifyKeychain.save(tokens) else { throw SpotifyClient.Failure.login("Stride couldn't store the Spotify login in the Keychain.") }
        isSpotifyConnected = true
        spotifyAccountName = name
        UserDefaults.standard.set(name, forKey: DefaultsKey.spotifyAccountName)
        spotifyCache = nil
        source = .spotify
    }

    func disconnectSpotify() {
        SpotifyKeychain.delete()
        isSpotifyConnected = false
        spotifyAccountName = nil
        spotifyCache = nil
        genreCache = [:]
        UserDefaults.standard.removeObject(forKey: DefaultsKey.spotifyAccountName)
        if playlist?.source == .spotify { playlist = nil }
    }

    private func spotifyLibrary() async throws -> [LibrarySong] {
        if let spotifyCache, Date.now.timeIntervalSince(spotifyCache.fetchedAt) < Self.spotifyCacheLife { return spotifyCache.songs }
        let songs = try await withSpotify { client in
            async let short = client.topTracks(range: "short_term")
            async let medium = client.topTracks(range: "medium_term")
            async let recent = client.recentlyPlayed()
            async let saved = client.savedTracks(pages: 4)
            let (shortTerm, mediumTerm, played, liked) = try await (short, medium, recent, saved)
            let artists = SpotifyLibrary.artistsToLookUp(shortTerm: shortTerm, mediumTerm: mediumTerm, recent: played, saved: liked)
            let genres = await self.genres(of: artists, client: client)
            return SpotifyLibrary.songs(shortTerm: shortTerm, mediumTerm: mediumTerm, recent: played, saved: liked, genres: genres)
        }
        spotifyCache = (.now, songs)
        return songs
    }

    /// Genres for the artists, one request each (Spotify removed the batch endpoint), cached while the app runs.
    /// A failed lookup just leaves the artist without a genre.
    private func genres(of artists: [String], client: SpotifyClient) async -> [String: [String]] {
        let missing = artists.filter { genreCache[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: 8) {
            let batch = missing[start..<min(start + 8, missing.count)]
            let found = await withTaskGroup(of: (String, [String]?).self) { group in
                for id in batch { group.addTask { (id, try? await client.genres(ofArtist: id)) } }
                var found: [(String, [String]?)] = []
                for await result in group { found.append(result) }
                return found
            }
            for (id, genres) in found { if let genres { genreCache[id] = genres } }
        }
        return genreCache
    }

    /// Runs the requests with a fresh access token, refreshing it (and once more after a 401) as needed.
    private func withSpotify<Result>(_ body: (SpotifyClient) async throws -> Result) async throws -> Result {
        guard isSpotifyConnected, var tokens = SpotifyKeychain.load() else {
            throw SpotifyClient.Failure.login("Connect Spotify in Settings → Music first.")
        }
        let clientID = spotifyClientID
        do {
            if tokens.isExpired() { tokens = try await refreshed(tokens, clientID: clientID) }
            do {
                return try await body(SpotifyClient(clientID: clientID, accessToken: tokens.accessToken))
            } catch SpotifyClient.Failure.notAuthorized {
                tokens = try await refreshed(tokens, clientID: clientID)
                return try await body(SpotifyClient(clientID: clientID, accessToken: tokens.accessToken))
            }
        } catch SpotifyClient.Failure.notAuthorized {
            disconnectSpotify()
            throw SpotifyClient.Failure.notAuthorized
        }
    }

    private func refreshed(_ tokens: SpotifyTokens, clientID: String) async throws -> SpotifyTokens {
        let fresh = try await SpotifyClient.refresh(tokens, clientID: clientID)
        SpotifyKeychain.save(fresh)
        return fresh
    }
}
