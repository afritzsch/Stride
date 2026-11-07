import Foundation
import FoundationModels

/// A song in the athlete's own music library (`MusicLibraryService`), or a made-up one in demo mode (`DemoMusic`).
nonisolated struct LibrarySong: Codable, Hashable, Identifiable, Sendable {
    /// `MPMediaItem.persistentID` as a string.
    var id: String
    var title: String
    var artist: String
    var genre: String
    var seconds: Int
    var playCount: Int
    var skipCount: Int
    var lastPlayed: Date?
    var added: Date?
}

/// How much drive a song has, guessed from its genre. Apple's library has no tempo or energy data
/// (`beatsPerMinute` is almost always 0), so this is the best code can do without guessing per song.
nonisolated enum SongEnergy: Int, Comparable, CaseIterable, Sendable {
    case calm, steady, driving

    static func < (lhs: SongEnergy, rhs: SongEnergy) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .calm: "calm"
        case .steady: "steady"
        case .driving: "high-energy"
        }
    }

    // Checked in order: "soft rock" is calm before "rock" makes it driving.
    private static let calmWords = ["ambient", "classical", "jazz", "acoustic", "folk", "singer", "new age", "piano",
                                    "soundtrack", "score", "lo-fi", "lofi", "chill", "easy listening", "meditation", "soft", "downtempo", "blues"]
    private static let drivingWords = ["metal", "punk", "rock", "dance", "electronic", "edm", "house", "techno", "trance",
                                       "drum", "dubstep", "hip-hop", "hip hop", "rap", "trap", "grime", "workout", "fitness", "hardcore"]

    init(genre: String) {
        let genre = genre.lowercased()
        if Self.calmWords.contains(where: genre.contains) {
            self = .calm
        } else if Self.drivingWords.contains(where: genre.contains) {
            self = .driving
        } else {
            self = .steady
        }
    }
}

/// A timed part of the session the music should follow.
nonisolated struct PlaylistSegment: Hashable, Sendable {
    enum Role: String, Sendable {
        case warmUp = "Warm-up", main = "Main set", push = "Hard efforts", coolDown = "Cool-down"
    }

    var role: Role
    var minutes: Int
    var energy: SongEnergy
}

/// What the model writes: song numbers per section from the shortlist, then a name. It never names songs itself,
/// so it can't invent any.
@Generable
nonisolated struct PlaylistDraft: Sendable {
    @Guide(description: "One entry per section, in the order given")
    var sections: [SectionPicks]
    @Guide(description: "Playlist name, 2 to 5 words, about the session; no song or artist names")
    var name: String
    @Guide(description: "One short sentence for the athlete on how the music follows the session's sections; mention only genres of the songs you picked")
    var note: String
}

@Generable
nonisolated struct SectionPicks: Sendable {
    @Guide(description: "Numbers of the songs picked for this section, from this section's list only, in play order")
    var songs: [Int]
}

nonisolated struct WorkoutPlaylist: Identifiable, Sendable {
    struct Section: Sendable {
        var segment: PlaylistSegment
        var songs: [LibrarySong]

        var seconds: Int { songs.reduce(0) { $0 + $1.seconds } }
    }

    var id = UUID()
    var name: String
    var note: String
    var date: Date
    var session: PlannedDay
    var sections: [Section]
    /// False when code picked the songs alone (no Apple Intelligence, or the model failed).
    var madeByModel: Bool

    var songs: [LibrarySong] { sections.flatMap(\.songs) }
    var seconds: Int { sections.reduce(0) { $0 + $1.seconds } }
}

nonisolated enum PlaylistError: LocalizedError, Equatable {
    case restDay, tooFewSongs(Int)

    var errorDescription: String? {
        switch self {
        case .restDay: "There's no session to make a playlist for."
        case .tooFewSongs(let count): "Your music library has \(count == 0 ? "no songs" : "only \(count) songs") Stride can use. Add some music to your library first."
        }
    }
}

/// Turns a planned session and the athlete's library into a playlist. Everything that needs counting is done here:
/// the sections, which songs fit each, the athlete's taste, and filling each section to its minutes.
nonisolated enum PlaylistBuilder {
    static let minimumLibrary = 10
    /// Shortlist size limits, so the prompt fits the on-device context window (~15 tokens per song line).
    static let maxCandidates = 48
    static let maxPerArtist = 2

    /// The session a playlist follows when none is planned (no plan, a rest day): an easy one in the athlete's most
    /// frequent sport of the last 4 weeks, as long as their usual session (median, in 5-minute steps, 20–120 min).
    static func usualSession(recent workouts: [WorkoutSummary], now: Date) -> PlannedDay {
        let since = now.addingTimeInterval(-28 * 86400)
        let recent = workouts.filter { $0.start >= since && $0.durationMinutes >= 10 }
        let counts = Dictionary(recent.map { ($0.sport, 1) }, uniquingKeysWith: +)
        let sport = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? Sport.running
        let minutes = recent.filter { $0.sport == sport }.map(\.durationMinutes).sorted()
        let median = minutes.isEmpty ? 45 : minutes[minutes.count / 2]
        let rounded = min(max(Int((median / 5).rounded()) * 5, 20), 120)
        let zone = WorkoutSummary.strengthSports.contains(sport) ? 0 : 2
        return PlannedDay(day: "", sport: sport, intensity: .easy, session: "Easy \(sport.lowercased())",
                          durationMinutes: rounded, targetZone: zone, details: "")
    }

    // MARK: Sections

    static func segments(for day: PlannedDay) -> [PlaylistSegment] {
        let minutes = day.durationMinutes
        guard !day.isRest, minutes > 0 else { return [] }
        if ["Yoga", "Mobility"].contains(day.sport) {
            return [PlaylistSegment(role: .main, minutes: minutes, energy: .calm)]
        }
        if [Sport.strength, "HIIT", "Cross training"].contains(day.sport) {
            let warmUp = min(5, minutes / 4)
            return [
                PlaylistSegment(role: .warmUp, minutes: warmUp, energy: .steady),
                PlaylistSegment(role: .main, minutes: minutes - warmUp, energy: .driving),
            ].filter { $0.minutes > 0 }
        }
        let zone = day.targetZone > 0 ? day.targetZone : [.easy: 2, .moderate: 3, .hard: 4][day.intensity] ?? 2
        if minutes < 20 {
            return [PlaylistSegment(role: .main, minutes: minutes, energy: zone >= 3 ? .driving : .steady)]
        }
        let (warmUp, coolDown, main): (Int, Int, PlaylistSegment.Role) = switch zone {
        case ...2: (5, 5, .main)
        case 3: (10, 5, .main)
        default: (10, 10, .push)
        }
        let warm = min(warmUp, minutes / 4)
        let cool = min(coolDown, minutes / 4)
        return [
            PlaylistSegment(role: .warmUp, minutes: warm, energy: .steady),
            PlaylistSegment(role: main, minutes: minutes - warm - cool, energy: zone >= 3 ? .driving : .steady),
            PlaylistSegment(role: .coolDown, minutes: cool, energy: .calm),
        ]
    }

    // MARK: Taste

    /// How much the athlete likes a song, from what the library records: plays, skips, recent plays, recent adds,
    /// and whether it was last played during a workout.
    static func taste(of song: LibrarySong, workouts: [WorkoutSummary], now: Date) -> Double {
        var score = log2(1 + Double(song.playCount))
        let plays = Double(max(song.playCount, 1))
        score -= 3 * min(Double(song.skipCount) / plays, 1)
        if let lastPlayed = song.lastPlayed {
            let days = now.timeIntervalSince(lastPlayed) / 86400
            if days < 30 { score += 2 } else if days < 90 { score += 1 }
            if playedDuringWorkout(lastPlayed, workouts: workouts) { score += 3 }
        }
        if let added = song.added, now.timeIntervalSince(added) < 30 * 86400 { score += 1 }
        return score
    }

    /// The library keeps only the last play, so this catches a song once, not every workout it was on.
    static func playedDuringWorkout(_ date: Date, workouts: [WorkoutSummary]) -> Bool {
        workouts.contains { date >= $0.start && date <= $0.start.addingTimeInterval($0.durationMinutes * 60 + 300) }
    }

    // MARK: Shortlists

    /// Candidate songs for each segment: matching energy (or the nearest one when there are too few), best taste
    /// first, at most `maxPerArtist` per artist, each song in one segment only. Songs in `avoid` (the last playlist)
    /// go to the back, so "try again" gives a different mix.
    static func shortlists(
        for segments: [PlaylistSegment],
        library: [LibrarySong],
        workouts: [WorkoutSummary],
        avoid: Set<String> = [],
        now: Date
    ) -> [[LibrarySong]] {
        let usable = library.filter { $0.seconds >= 90 && $0.seconds <= 12 * 60 }
        let scores = Dictionary(usable.map { ($0.id, taste(of: $0, workouts: workouts, now: now) - (avoid.contains($0.id) ? 10 : 0)) }) { a, _ in a }
        let ranked = usable.sorted { (scores[$0.id] ?? 0, $1.id) > (scores[$1.id] ?? 0, $0.id) }
        let totalMinutes = max(segments.reduce(0) { $0 + $1.minutes }, 1)
        var taken = Set<String>()

        return segments.map { segment in
            // About twice the songs the segment needs, so the model has a choice.
            let share = Double(segment.minutes) / Double(totalMinutes)
            let limit = min(max(Int((Double(maxCandidates) * share).rounded()), segment.minutes * 60 / 210 * 2, 4), maxCandidates)
            let needed = segment.minutes * 60 * 2
            var list: [LibrarySong] = []
            var perArtist: [String: Int] = [:]
            // Exact energy first, with more songs per artist before taking another energy: the right energy matters
            // more than variety. Neighbours only fill up when the library is short of it.
            let byEnergy = SongEnergy.allCases.sorted { abs($0.rawValue - segment.energy.rawValue) < abs($1.rawValue - segment.energy.rawValue) }
            let passes = byEnergy.flatMap { energy in [(energy, maxPerArtist), (energy, maxPerArtist * 2)] }
            for (energy, cap) in passes {
                if list.count >= limit || (list.reduce(0) { $0 + $1.seconds } >= needed) { break }
                for song in ranked where SongEnergy(genre: song.genre) == energy && !taken.contains(song.id) {
                    guard list.count < limit else { break }
                    let artist = song.artist.lowercased()
                    guard perArtist[artist, default: 0] < cap else { continue }
                    perArtist[artist, default: 0] += 1
                    list.append(song)
                    taken.insert(song.id)
                }
            }
            return list
        }
    }

    // MARK: Prompt

    static let instructions = """
    You build a workout playlist from the athlete's own music library. The session is split into sections, each \
    with a numbered list of songs from the library. For each section, pick songs from that section's list only, by \
    number, enough to fill about its minutes, in the order they should play. Mix artists, build energy into the \
    hardest section and wind down at the end. The lists are sorted by how much the athlete plays each song, so \
    prefer songs near the top. Then name the playlist after the session.
    """

    static func prompt(day: PlannedDay, segments: [PlaylistSegment], shortlists: [[LibrarySong]], favouriteArtists: [String]) -> String {
        var lines = ["SESSION: \(day.session), \(day.sport), \(day.durationMinutes) min" + (day.targetZone > 0 ? ", heart-rate zone \(day.targetZone)" : "")]
        if !day.details.isEmpty { lines.append("DETAILS: " + PromptBuilder.quote(day.details, limit: 160)) }
        if !favouriteArtists.isEmpty { lines.append("MOST PLAYED ARTISTS: " + favouriteArtists.joined(separator: ", ")) }
        lines.append("SECTIONS:")
        var number = 0
        for (index, segment) in segments.enumerated() {
            lines.append("\(index + 1). \(segment.role.rawValue), \(segment.minutes) min, \(segment.energy.title) songs:")
            for song in shortlists[index] {
                number += 1
                lines.append("  #\(number) \(song.artist) – \(song.title) (\(song.genre.isEmpty ? "unknown genre" : song.genre), \(clock(song.seconds)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func favouriteArtists(in library: [LibrarySong], count: Int = 5) -> [String] {
        let plays = Dictionary(library.map { ($0.artist, $0.playCount) }, uniquingKeysWith: +)
        return plays.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(count).map(\.key)
    }

    // MARK: Assembly

    /// Puts the playlist together from the model's picks (or none): keeps only numbers from each section's own list,
    /// drops repeats, then fills each section to its minutes from the shortlist in taste order. The last song may run
    /// past the section's end; a section never ends more than half a song short while candidates are left.
    static func assemble(
        day: PlannedDay,
        date: Date,
        segments: [PlaylistSegment],
        shortlists: [[LibrarySong]],
        draft: PlaylistDraft?
    ) -> WorkoutPlaylist {
        var offset = 0
        var used = Set<String>()
        // Each section aims at its end time in the session, so one that ran long shortens the next.
        var elapsed = 0
        var sectionEnd = 0
        let sections = segments.enumerated().map { index, segment in
            let list = shortlists[index]
            defer { offset += list.count }
            let picks = draft.flatMap { index < $0.sections.count ? $0.sections[index].songs : nil } ?? []
            let picked = picks.compactMap { number -> LibrarySong? in
                let local = number - 1 - offset
                return list.indices.contains(local) ? list[local] : nil
            }
            sectionEnd += segment.minutes * 60
            // Within a minute of the target counts as full, except at the end: the music mustn't stop before the session does.
            let target = sectionEnd - elapsed - (index == segments.count - 1 ? 0 : 60)
            var songs: [LibrarySong] = []
            var seconds = 0
            for song in picked + list where seconds < target && !used.contains(song.id) {
                // Skip a long song that would overshoot by more than half its length; a shorter one may fit better.
                if seconds > 0, seconds + song.seconds - target > song.seconds / 2, list.contains(where: { !used.contains($0.id) && $0.id != song.id && seconds + $0.seconds - target <= $0.seconds / 2 }) {
                    continue
                }
                songs.append(song)
                used.insert(song.id)
                seconds += song.seconds
            }
            elapsed += seconds
            return WorkoutPlaylist.Section(segment: segment, songs: songs)
        }
        let name = draft?.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "\(day.session) · \(day.durationMinutes) min"
        let note = draft?.note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Picked from the songs you play most, calmer at the edges and with more drive in the main part."
        return WorkoutPlaylist(name: name, note: note, date: date, session: day, sections: sections, madeByModel: draft != nil)
    }

    static func clock(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
