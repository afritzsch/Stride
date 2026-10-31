import Foundation

/// Hevy's wire format, matching logged sessions to watch workouts, records, the overview and the review prompt.
func checkStrength() {
    section("Strength log")
    // Shaped like the example in Hevy's API docs, with a fractional-seconds date and an unknown set type.
    let page = """
    {"page":1,"page_count":3,"workouts":[{"id":"b459cba5","title":"Morning Workout 💪","routine_id":null,
      "description":"Felt strong","start_time":"2026-10-27T17:04:00Z","end_time":"2026-10-27T17:52:30.000Z",
      "updated_at":"2026-10-27T18:00:00Z","created_at":"2026-10-27T18:00:00Z","exercises":[
        {"index":0,"title":"Bench Press (Barbell)","notes":"","exercise_template_id":"79D0BB3A","superset_id":null,"sets":[
          {"index":0,"type":"warmup","weight_kg":40,"reps":10,"distance_meters":null,"duration_seconds":null,"rpe":null,"custom_metric":null},
          {"index":1,"type":"normal","weight_kg":80,"reps":5,"distance_meters":null,"duration_seconds":null,"rpe":8,"custom_metric":null},
          {"index":2,"type":"normal","weight_kg":80,"reps":5,"distance_meters":null,"duration_seconds":null,"rpe":9,"custom_metric":null},
          {"index":3,"type":"cluster","weight_kg":70,"reps":8,"distance_meters":null,"duration_seconds":null,"rpe":null,"custom_metric":null}]},
        {"index":1,"title":"Plank","notes":null,"exercise_template_id":"C6C9B8A0","superset_id":0,"sets":[
          {"index":0,"type":"normal","weight_kg":null,"reps":null,"distance_meters":null,"duration_seconds":60,"rpe":null,"custom_metric":null}]}]}]}
    """
    guard let decoded = try? HevyClient.decodeWorkouts(Data(page.utf8)), let session = decoded.sessions.first else {
        check(false, "Hevy workouts page decodes")
        return
    }
    check(decoded.pageCount == 3, "page count")
    check(session.exercises.count == 2 && session.exercises[0].sets.count == 4, "exercises and sets")
    check(session.exercises[0].sets[0].kind == .warmup && session.exercises[0].sets[3].kind == .normal, "set types, unknown ones as normal")
    check(session.exercises[0].notes == nil && session.exercises[1].supersetID == 0, "empty notes dropped, superset kept")
    check(abs(session.durationMinutes - 48.5) < 0.01, "fractional-second end date")
    check(session.workingSets.count == 4 && session.totalReps == 18, "warm-ups don't count: \(session.workingSets.count) sets, \(session.totalReps) reps")
    check(session.volumeKg == 80 * 5 * 2 + 70 * 8, "volume from working sets: \(session.volumeKg)")
    check(session.exercises[0].setsSummary(locale: Locale(identifier: "en_US_POSIX")) == "2×5 @ 80 kg (RPE 9), 70 kg × 8", "sets summary: \(session.exercises[0].setsSummary())")
    check(session.exercises[1].setsSummary() == "1:00", "timed set: \(session.exercises[1].setsSummary())")
    check(StrengthSet(index: 0, kind: .normal, weightKg: 100, reps: 15).estimatedOneRepMax == nil, "no 1RM past 12 reps")

    // Matching: the watch started a few minutes before the log, a run the same evening doesn't match.
    let gym = WorkoutSummary(id: UUID(), start: session.start.addingTimeInterval(-300), durationMinutes: 55, sport: "Strength", sourceName: "Garmin")
    let lateRun = WorkoutSummary(id: UUID(), start: session.end.addingTimeInterval(3 * 3600), durationMinutes: 40, sport: "Running", sourceName: "Garmin")
    let farGym = WorkoutSummary(id: UUID(), start: session.end.addingTimeInterval(2 * 3600), durationMinutes: 40, sport: "Strength", sourceName: "Garmin")
    check(StrengthLog.session(for: gym, in: decoded.sessions)?.id == session.id, "overlapping workout matches")
    check(StrengthLog.session(for: farGym, in: decoded.sessions) == nil, "workout hours later doesn't match")
    check(StrengthLog.workout(for: session, in: [lateRun, farGym, gym])?.id == gym.id, "session finds its watch workout")

    // Demo log: one session per demo gym workout, weights going up, so there are records and lifts.
    let scenario = Scenario.demoWithHistory()
    let demo = DemoStrength.sessions(for: scenario.snapshot.workouts)
    let gymWorkouts = scenario.snapshot.workouts.filter { $0.kind == .strength }
    check(demo.count == gymWorkouts.count && !demo.isEmpty, "demo log covers the demo gym sessions")
    check(gymWorkouts.allSatisfy { StrengthLog.session(for: $0, in: demo) != nil }, "every demo gym workout has its log")
    let report = StrengthReport(workouts: scenario.snapshot.workouts, sessions: demo, now: scenario.snapshot.fetchedAt)
    check(report.hasLog && !report.lifts.isEmpty, "demo: main lifts")
    check(!report.records.isEmpty, "demo: personal bests")
    check(report.entries.allSatisfy { $0.workout != nil && $0.session != nil }, "demo: log and watch paired")
    check(report.weeks.count == 8 && report.weeks.contains { ($0.volumeKg ?? 0) > 0 }, "demo: weekly volume")
    let squat = report.lifts.first { $0.title.hasPrefix("Squat") }
    check((squat?.change ?? 0) > 0, "demo: squat goes up (\(squat?.change ?? -1))")

    let watchOnly = StrengthReport(workouts: scenario.snapshot.workouts, sessions: nil, now: scenario.snapshot.fetchedAt)
    check(!watchOnly.hasLog && watchOnly.lifts.isEmpty && watchOnly.volumeLast28Days == nil, "without a log: no lifts or volume")
    check(watchOnly.entries.count == gymWorkouts.filter { $0.start <= scenario.snapshot.fetchedAt }.count, "without a log: every gym workout listed")
    check(watchOnly.weeks.allSatisfy { $0.volumeKg == nil }, "without a log: weeks have no volume")

    // Review prompt: exercises with a log, the watch-only rules without.
    guard let lastGym = gymWorkouts.last, let logged = StrengthLog.session(for: lastGym, in: demo) else { return }
    func prompt(_ session: StrengthSession?, compact: Bool) -> String {
        RunPromptBuilder(
            detail: DemoData.detail(for: lastGym), snapshot: scenario.snapshot, metrics: scenario.metrics,
            profile: scenario.profile, plannedSession: nil, note: "", compact: compact,
            strengthSession: session, strengthHistory: demo
        ).prompt
    }
    let full = prompt(logged, compact: false), compact = prompt(logged, compact: true), bare = prompt(nil, compact: false)
    check(full.contains("LOGGED EXERCISES") && full.contains("last time ("), "prompt: logged exercises with last time")
    check(compact.contains("LOGGED EXERCISES") && compact.count < full.count, "compact prompt is shorter")
    check(!bare.contains("LOGGED EXERCISES"), "prompt without a log has no exercises")
    check(RunPromptBuilder.instructions(for: .strength).contains("LOGGED EXERCISES"), "strength instructions explain the log")
    let roundTrip = try? JSONDecoder().decode([StrengthSession].self, from: JSONEncoder().encode(demo))
    check(roundTrip == demo, "cached log round-trips")
}
