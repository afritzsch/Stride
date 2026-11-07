import Foundation

/// Playlists: sections follow the session, shortlists hold real library songs that fit the prompt, and assembly
/// fills every section from whatever the model picked (including nonsense numbers).
func checkPlaylists() {
    section("Playlists")
    let now = Date()
    let workouts = Scenario.demoWithHistory().snapshot.workouts
    let library = DemoMusic.library(workouts: workouts, now: now)

    func day(_ sport: String, _ intensity: SessionIntensity, _ minutes: Int, zone: Int) -> PlannedDay {
        PlannedDay(day: "Mon", sport: sport, intensity: intensity, session: "Session", durationMinutes: minutes, targetZone: zone, details: "")
    }

    // Sections.
    check(PlaylistBuilder.segments(for: day("Rest", .rest, 0, zone: 0)).isEmpty, "rest day has no sections")
    let easy = PlaylistBuilder.segments(for: day(Sport.running, .easy, 45, zone: 2))
    check(easy.map(\.role) == [.warmUp, .main, .coolDown] && easy.reduce(0) { $0 + $1.minutes } == 45, "easy run: warm-up, main, cool-down adding to 45 min, got \(easy)")
    check(easy[1].energy == .steady, "easy run main part is steady, not driving")
    let intervals = PlaylistBuilder.segments(for: day(Sport.running, .hard, 60, zone: 4))
    check(intervals.map(\.role) == [.warmUp, .push, .coolDown] && intervals[1].energy == .driving, "intervals get a driving hard part, got \(intervals)")
    check(PlaylistBuilder.segments(for: day("Yoga", .easy, 30, zone: 0)).allSatisfy { $0.energy == .calm }, "yoga stays calm")
    let short = PlaylistBuilder.segments(for: day(Sport.running, .easy, 15, zone: 2))
    check(short.count == 1 && short[0].minutes == 15, "a short session is one section")

    // Without a planned session: the usual one.
    let usual = PlaylistBuilder.usualSession(recent: workouts, now: now)
    check(usual.intensity == .easy && (20...120).contains(usual.durationMinutes) && usual.durationMinutes % 5 == 0,
          "usual session is easy and 20–120 min in 5-min steps, got \(usual.session) \(usual.durationMinutes) min")
    check(!PlaylistBuilder.segments(for: usual).isEmpty, "usual session has sections")
    let nothing = PlaylistBuilder.usualSession(recent: [], now: now)
    check(nothing.sport == Sport.running && nothing.durationMinutes == 45, "no workouts: a 45-min easy run")

    // Energy from genre.
    check(SongEnergy(genre: "Soft Rock") == .calm && SongEnergy(genre: "Alternative Rock") == .driving && SongEnergy(genre: "Pop") == .steady,
          "genre energy: soft rock calm, rock driving, pop steady")

    // Shortlists.
    let lists = PlaylistBuilder.shortlists(for: intervals, library: library, workouts: workouts, now: now)
    let all = lists.flatMap { $0 }
    check(all.count <= PlaylistBuilder.maxCandidates, "shortlist capped at \(PlaylistBuilder.maxCandidates), got \(all.count)")
    check(Set(all.map(\.id)).count == all.count, "no song in two sections")
    check(lists[1].allSatisfy { SongEnergy(genre: $0.genre) == .driving }, "hard part shortlist is driving songs")
    for (index, list) in lists.enumerated() {
        let perArtist = Dictionary(grouping: list, by: \.artist).values.map(\.count).max() ?? 0  // doubled only when the energy runs short
        check(perArtist <= PlaylistBuilder.maxPerArtist * 2, "section \(index): at most \(PlaylistBuilder.maxPerArtist * 2) songs per artist, got \(perArtist)")
        check(list.reduce(0) { $0 + $1.seconds } >= intervals[index].minutes * 60, "section \(index) has enough candidates to fill \(intervals[index].minutes) min")
    }
    let trainingSong = library.first { $0.lastPlayed.map { PlaylistBuilder.playedDuringWorkout($0, workouts: workouts) } == true }
    check(trainingSong != nil, "demo library has songs last played during a workout")
    if let trainingSong {
        let twin = LibrarySong(id: "x", title: "", artist: "", genre: "", seconds: 200, playCount: trainingSong.playCount, skipCount: trainingSong.skipCount,
                               lastPlayed: trainingSong.lastPlayed!.addingTimeInterval(-30 * 86400), added: nil)
        check(PlaylistBuilder.taste(of: trainingSong, workouts: workouts, now: now) > PlaylistBuilder.taste(of: twin, workouts: [], now: now),
              "songs played during a workout rank higher")
    }
    let again = PlaylistBuilder.shortlists(for: intervals, library: library, workouts: workouts, avoid: Set(all.map(\.id)), now: now)
    let repeated = Set(again.flatMap { $0 }.map(\.id)).intersection(all.map(\.id)).count
    check(repeated < all.count / 2, "trying again mostly avoids the last songs (\(repeated) of \(all.count) repeated)")

    // Prompt size: ~4 characters per token, well under the iPhone's 4096 with instructions and schema.
    let prompt = PlaylistBuilder.prompt(day: day(Sport.running, .hard, 60, zone: 4), segments: intervals, shortlists: lists,
                                        favouriteArtists: PlaylistBuilder.favouriteArtists(in: library))
    check(prompt.count / 4 < 1500, "playlist prompt fits the on-device window (~\(prompt.count / 4) tokens)")
    check(prompt.contains("#1 ") && prompt.contains("#\(all.count) "), "prompt numbers every candidate")

    // Assembly.
    let session = day(Sport.running, .hard, 60, zone: 4)
    let plain = PlaylistBuilder.assemble(day: session, date: now, segments: intervals, shortlists: lists, draft: nil)
    check(!plain.madeByModel && plain.name.contains("60 min"), "code-only playlist gets a session name")
    // Sections end near their planned time in the session (a song may run over; the next section then makes up for it).
    var plannedEnd = 0, actualEnd = 0
    for (section, segment) in zip(plain.sections, intervals) {
        plannedEnd += segment.minutes * 60
        actualEnd += section.seconds
        check(actualEnd >= plannedEnd - 90 && actualEnd <= plannedEnd + 6 * 60,
              "\(segment.role.rawValue) ends at \(actualEnd / 60) min, planned \(plannedEnd / 60)")
    }
    check(plain.seconds >= 60 * 60 && plain.seconds <= 60 * 60 + 5 * 60, "60-min session gets 60–65 min of music, got \(plain.seconds / 60)")
    for minutes in [30, 45, 85] {
        let run = day(Sport.running, .easy, minutes, zone: 2)
        let segments = PlaylistBuilder.segments(for: run)
        let built = PlaylistBuilder.assemble(day: run, date: now, segments: segments,
                                             shortlists: PlaylistBuilder.shortlists(for: segments, library: library, workouts: workouts, now: now), draft: nil)
        check(built.seconds >= minutes * 60 && built.seconds <= minutes * 60 + 5 * 60, "\(minutes)-min run gets \(minutes)–\(minutes + 5) min of music, got \(built.seconds / 60)")
    }
    // The model's numbers: one from another section, one out of range, a repeat. Only the valid one is kept first.
    let firstOfPush = lists[0].count + 1
    let draft = PlaylistDraft(
        sections: [SectionPicks(songs: [firstOfPush, 999]), SectionPicks(songs: [firstOfPush + 1, firstOfPush + 1, 1])],
        name: "  Fast Lane  ", note: "Builds into the reps."
    )
    let picked = PlaylistBuilder.assemble(day: session, date: now, segments: intervals, shortlists: lists, draft: draft)
    check(picked.madeByModel && picked.name == "Fast Lane", "model name kept, trimmed")
    check(picked.sections[1].songs.first?.id == lists[1][1].id, "model's first valid pick opens the hard part")
    check(!picked.sections[0].songs.contains { $0.id == lists[1][0].id }, "a pick from another section's list is ignored")
    check(Set(picked.songs.map(\.id)).count == picked.songs.count, "no song twice")
    check(picked.sections.allSatisfy { !$0.songs.isEmpty }, "every section has songs despite bad picks")

    check(PlaylistBuilder.shortlists(for: easy, library: Array(library.prefix(3)), workouts: [], now: now).flatMap { $0 }.count < PlaylistBuilder.minimumLibrary,
          "a tiny library is caught by the minimum check")
}
