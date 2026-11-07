import Foundation

/// A made-up music library for demo data and the eval harness (the Simulator has no music library). Artists and
/// titles are invented; some songs were last played during the demo workouts, like a real training playlist would be.
nonisolated enum DemoMusic {
    private static let artists: [(name: String, genre: String)] = [
        ("Northbound Static", "Alternative Rock"), ("The Copper Lines", "Indie Rock"), ("Velvet Engine", "Hard Rock"),
        ("Kilowatt Kids", "Punk"), ("Iron Meridian", "Metal"), ("Neon Harbour", "Electronic"), ("Pulse Theory", "Dance"),
        ("Lowlight District", "House"), ("MC Tidewater", "Hip-Hop/Rap"), ("Sora & The Sundays", "Pop"),
        ("Maple Avenue", "Pop"), ("Juniper Fields", "Indie Pop"), ("Odette Rain", "R&B/Soul"), ("The Brass Orchard", "Funk"),
        ("Halvard Lund", "Singer/Songwriter"), ("Quiet Tides", "Ambient"), ("Elm Street Trio", "Jazz"), ("Wren Ashby", "Folk"),
    ]
    private static let first = ["Run", "Golden", "Midnight", "Paper", "Electric", "Slow", "Wild", "Silver", "Open", "Last",
                                "Brave", "Cold", "Higher", "Second", "Long", "Burning", "Quiet", "Faster"]
    private static let second = ["Road", "Hearts", "Signal", "Lights", "Summer", "Ground", "Horizon", "River", "Echo", "Streets",
                                 "Fire", "Morning", "Machine", "Waves", "Line", "Skies", "Miles", "Gravity"]

    static func library(workouts: [WorkoutSummary], now: Date = .now) -> [LibrarySong] {
        var random = SeededGenerator(seed: 0x6D75_7369_6321)
        let runs = workouts.filter { $0.durationMinutes >= 20 }
        var songs: [LibrarySong] = []
        for (index, artist) in artists.enumerated() {
            // Some artists are favourites, some barely played.
            let popularity = Double.random(in: 0.1...1, using: &random)
            for track in 0..<9 {
                let title = "\(first.randomElement(using: &random)!) \(second.randomElement(using: &random)!)"
                let plays = Int(Double.random(in: 0...60, using: &random) * popularity * popularity)
                var lastPlayed = plays == 0 ? nil : now.addingTimeInterval(-Double.random(in: 1...200, using: &random) * 86400)
                // High-energy favourites were last heard on a run.
                if SongEnergy(genre: artist.genre) == .driving, popularity > 0.5, track % 3 == 0, let run = runs.randomElement(using: &random) {
                    lastPlayed = run.start.addingTimeInterval(Double.random(in: 0...(run.durationMinutes * 60), using: &random))
                }
                songs.append(LibrarySong(
                    id: String(1000 + index * 100 + track),
                    title: title,
                    artist: artist.name,
                    genre: artist.genre,
                    seconds: Int.random(in: 150...330, using: &random),
                    playCount: plays,
                    skipCount: Int.random(in: 0...max(plays / 4, 0), using: &random),
                    lastPlayed: lastPlayed,
                    added: now.addingTimeInterval(-Double.random(in: 5...900, using: &random) * 86400)
                ))
            }
        }
        return songs
    }
}
