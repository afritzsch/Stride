import Foundation

/// Spotify: PKCE, the login URL and redirect, tokens, and turning API responses into songs for `PlaylistBuilder`.
func checkSpotify() {
    section("Spotify")

    // RFC 7636, appendix B.
    check(SpotifyPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE S256 challenge matches RFC 7636")
    let verifier = SpotifyPKCE.verifier()
    check((43...128).contains(verifier.count) && verifier.allSatisfy { $0.isLetter || $0.isNumber || "-_".contains($0) }, "PKCE verifier is 43–128 URL-safe characters, got \(verifier.count)")
    check(SpotifyPKCE.verifier() != verifier, "PKCE verifiers are random")

    let url = SpotifyClient.authorizationURL(clientID: "abc123", challenge: "CH", state: "ST")
    let items = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") }) { a, _ in a }
    check(url.host() == "accounts.spotify.com" && items["response_type"] == "code" && items["code_challenge_method"] == "S256"
          && items["redirect_uri"] == "http://127.0.0.1:43821/callback" && items["state"] == "ST" && items["client_id"] == "abc123",
          "authorize URL has code, PKCE, loopback redirect and state: \(url)")
    check(items["scope"]?.contains("playlist-modify-private") == true && items["scope"]?.contains("user-top-read") == true, "authorize URL asks for the needed scopes")
    check(String(data: SpotifyClient.formBody(["redirect_uri": "http://127.0.0.1:1/callback", "a": "x y"]), encoding: .utf8) == "a=x%20y&redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback",
          "token form body is percent-encoded")

    // The redirect caught by the loopback listener.
    func code(_ request: String) -> String? { if case .success(let code)? = SpotifyClient.callback(request: request, state: "ST") { code } else { nil } }
    check(code("GET /callback?code=AQB&state=ST HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n") == "AQB", "callback code is read")
    check(SpotifyClient.callback(request: "GET /favicon.ico HTTP/1.1\r\n\r\n", state: "ST") == nil, "other requests are ignored")
    if case .failure? = SpotifyClient.callback(request: "GET /callback?code=AQB&state=EVIL HTTP/1.1\r\n\r\n", state: "ST") {} else {
        check(false, "a callback with the wrong state is refused")
    }
    if case .failure(let error)? = SpotifyClient.callback(request: "GET /callback?error=access_denied&state=ST HTTP/1.1\r\n\r\n", state: "ST") {
        check(error is CancellationError, "denying the login counts as cancelling")
    } else {
        check(false, "a denied login is an error")
    }

    // Tokens.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let first = try? SpotifyClient.decodeTokens(Data(#"{"access_token":"A1","token_type":"Bearer","expires_in":3600,"refresh_token":"R1","scope":"x"}"#.utf8), previous: nil, now: now)
    check(first?.refreshToken == "R1" && first?.expiresAt == now.addingTimeInterval(3540), "tokens expire a minute early")
    let refreshed = first.flatMap { try? SpotifyClient.decodeTokens(Data(#"{"access_token":"A2","expires_in":3600}"#.utf8), previous: $0, now: now) }
    check(refreshed?.accessToken == "A2" && refreshed?.refreshToken == "R1", "a refresh without a new refresh token keeps the old one")

    // API responses → songs.
    let decoder = SpotifyClient.decoder
    func track(_ id: String, _ name: String, artist: String, artistID: String, seconds: Int = 200) -> String {
        #"{"id":"\#(id)","uri":"spotify:track:\#(id)","name":"\#(name)","duration_ms":\#(seconds * 1000),"artists":[{"id":"\#(artistID)","name":"\#(artist)"}],"is_local":false}"#
    }
    let topJSON = #"{"items":[\#(track("t1", "First", artist: "Alpha", artistID: "a1")),\#(track("t2", "Second", artist: "Beta", artistID: "b1"))],"next":null}"#
    let localJSON = #"{"items":[{"id":null,"uri":"spotify:local:x","name":"Local","duration_ms":200000,"artists":[{"id":null,"name":"Me"}],"is_local":true}]}"#
    let recentJSON = #"{"items":[{"track":\#(track("t2", "Second", artist: "Beta", artistID: "b1")),"played_at":"2026-11-06T07:15:12.345Z"},{"track":\#(track("t3", "Third", artist: "Alpha", artistID: "a1")),"played_at":"2026-11-05T18:00:00.000Z"}],"next":null}"#
    let savedJSON = #"{"items":[{"added_at":"2026-10-01T10:00:00Z","track":\#(track("t3", "Third", artist: "Alpha", artistID: "a1"))}],"next":null}"#

    struct Page<Item: Decodable>: Decodable { var items: [Item] }
    do {
        let top = try decoder.decode(Page<SpotifyClient.Track>.self, from: Data(topJSON.utf8)).items
        let local = try decoder.decode(Page<SpotifyClient.Track>.self, from: Data(localJSON.utf8)).items
        let recent = try decoder.decode(Page<SpotifyClient.Play>.self, from: Data(recentJSON.utf8)).items
        let saved = try decoder.decode(Page<SpotifyClient.Saved>.self, from: Data(savedJSON.utf8)).items
        let songs = SpotifyLibrary.songs(shortTerm: top + local, mediumTerm: [top[1]], recent: recent, saved: saved, genres: ["a1": ["metalcore", "rock"]])
        check(songs.map(\.id) == ["spotify:track:t1", "spotify:track:t2", "spotify:track:t3"], "one song per track, local files left out: \(songs.map(\.id))")
        let second = songs.first { $0.id == "spotify:track:t2" }
        check(second?.playCount == 49 + 25 + 5, "taste points add top ranks and recent plays, got \(second?.playCount ?? -1)")
        check(second?.lastPlayed == (try? Date("2026-11-06T07:15:12.345Z", strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))), "played_at with milliseconds becomes lastPlayed")
        let third = songs.first { $0.id == "spotify:track:t3" }
        check(third?.added != nil && third?.genre == "metalcore" && SongEnergy(genre: third?.genre ?? "") == .driving, "liked date and the artist's first genre are kept")
        check(songs.first { $0.id == "spotify:track:t2" }?.genre == "", "an artist without genres leaves the genre empty (steady)")
        check(SpotifyLibrary.artistsToLookUp(shortTerm: top, mediumTerm: [], recent: recent, saved: saved).first == "a1", "the most frequent artist is looked up first")

        // A workout during a recent play makes that song a training favourite.
        let run = WorkoutSummary(id: UUID(), start: try Date("2026-11-06T07:00:00Z", strategy: .iso8601), durationMinutes: 45, sport: Sport.running,
                                 distanceKm: 8, activeEnergyKcal: nil, averageHeartRate: nil, maxHeartRate: nil, sourceName: "Garmin")
        check(second?.lastPlayed.map { PlaylistBuilder.playedDuringWorkout($0, workouts: [run]) } == true, "a song played during a run is recognised")
    } catch {
        check(false, "Spotify sample responses decode: \(error)")
    }
}
