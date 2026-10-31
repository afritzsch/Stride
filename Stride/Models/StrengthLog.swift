import Foundation

nonisolated enum StrengthLog {
    /// Up to this far apart, a log entry and a watch workout without overlap still count as the same session
    /// (people often start the watch in the locker room or the log after the warm-up).
    static let matchTolerance: TimeInterval = 20 * 60
    /// A 1RM estimate must beat the earlier best by more than this (kg) to count as a personal best.
    static let recordMarginKg = 0.01
    /// Prompts pass the POSIX locale so the model always sees a decimal point.
    private static let promptLocale = Locale(identifier: "en_US_POSIX")

    /// The logged session recorded at the same time as this watch workout.
    static func session(for workout: WorkoutSummary, in sessions: [StrengthSession]) -> StrengthSession? {
        let start = workout.start, end = workout.start.addingTimeInterval(workout.durationMinutes * 60)
        // Seconds the two overlap; negative is the gap between them.
        func overlap(_ session: StrengthSession) -> TimeInterval {
            min(end, session.end).timeIntervalSince(max(start, session.start))
        }
        return sessions
            .filter { overlap($0) > -matchTolerance }
            .max { overlap($0) < overlap($1) }
    }

    /// The watch workout recorded at the same time as this logged session.
    static func workout(for session: StrengthSession, in workouts: [WorkoutSummary]) -> WorkoutSummary? {
        let candidates = workouts.filter { (workout: WorkoutSummary) -> Bool in
            workout.kind == .strength && Self.session(for: workout, in: [session]) != nil
        }
        func distance(_ workout: WorkoutSummary) -> TimeInterval { abs(workout.start.timeIntervalSince(session.start)) }
        return candidates.min { distance($0) < distance($1) }
    }

    /// The exercise as it was done in the latest earlier session that had it.
    static func previous(_ exercise: StrengthExercise, before date: Date, in sessions: [StrengthSession]) -> (session: StrengthSession, exercise: StrengthExercise)? {
        sessions
            .filter { $0.start < date }
            .sorted { $0.start > $1.start }
            .lazy
            .compactMap { session in session.exercises.first { $0.templateID == exercise.templateID }.map { (session, $0) } }
            .first
    }

    /// Best estimated 1RM for the exercise in all sessions before the date.
    static func bestOneRepMax(templateID: String, before date: Date, in sessions: [StrengthSession]) -> Double? {
        sessions
            .filter { $0.start < date }
            .flatMap(\.exercises)
            .filter { $0.templateID == templateID }
            .compactMap(\.bestOneRepMax)
            .max()
    }

    /// Exercises in this session that beat every earlier session's estimated 1RM (an exercise done for the first
    /// time is no record).
    static func records(in session: StrengthSession, history: [StrengthSession]) -> Set<String> {
        Set(session.exercises.compactMap { exercise in
            guard let best = exercise.bestOneRepMax,
                  let before = bestOneRepMax(templateID: exercise.templateID, before: session.start, in: history),
                  best > before + recordMarginKg else { return nil }
            return exercise.templateID
        })
    }

    /// Lines for a coach prompt: each exercise's working sets, with the change from the last time it was done.
    static func promptLines(for session: StrengthSession, history: [StrengthSession], compact: Bool) -> [String] {
        let num = PromptBuilder.num
        var lines = ["LOGGED EXERCISES (from the athlete's Hevy log; working sets, warm-ups left out)"]
        if !session.title.isEmpty { lines.append("Workout: \(session.title)") }
        let records = records(in: session, history: history)
        for exercise in session.exercises where !exercise.workingSets.isEmpty {
            var line = "- \(exercise.title): \(exercise.setsSummary(locale: promptLocale))"
            if let best = exercise.bestOneRepMax {
                line += "; est. 1RM \(num(best, 0)) kg"
                if records.contains(exercise.templateID) { line += " (personal best)" }
            }
            if let previous = previous(exercise, before: session.start, in: history) {
                let when = PromptBuilder.dayLabel(previous.session.start, calendar: .current)
                if compact, let old = previous.exercise.bestOneRepMax {
                    line += "; last time (\(when)) est. 1RM \(num(old, 0)) kg"
                } else {
                    line += "; last time (\(when)): \(previous.exercise.setsSummary(locale: promptLocale))"
                }
            }
            if !compact, let notes = exercise.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                line += "; athlete's note: \(notes)"
            }
            lines.append(line)
        }
        var total = ["\(session.exercises.count) exercises", "\(session.workingSets.count) working sets", "\(session.totalReps) reps"]
        if session.volumeKg > 0 { total.append("volume \(num(session.volumeKg, 0)) kg") }
        lines.append("Total: " + total.joined(separator: ", "))
        if let notes = session.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append("Athlete's workout note in Hevy: \(notes)")
        }
        return lines
    }
}
