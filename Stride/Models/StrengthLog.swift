import Foundation

/// One lifting session from a workout log (Hevy): what Apple Health never gets, the exercises, sets, reps and weights.
nonisolated struct StrengthSession: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var notes: String?
    var start: Date
    var end: Date
    var exercises: [StrengthExercise]

    var durationMinutes: Double { max(end.timeIntervalSince(start) / 60, 0) }
    var workingSets: [StrengthSet] { exercises.flatMap(\.workingSets) }
    /// Weight × reps over working sets, in kg. Bodyweight and timed sets add nothing.
    var volumeKg: Double { exercises.map(\.volumeKg).reduce(0, +) }
    var totalReps: Int { workingSets.compactMap(\.reps).reduce(0, +) }
}

nonisolated struct StrengthExercise: Codable, Hashable, Identifiable, Sendable {
    var index: Int
    var title: String
    /// Hevy's exercise template; the same exercise across sessions shares it.
    var templateID: String
    var notes: String?
    var supersetID: Int?
    var sets: [StrengthSet]

    var id: Int { index }
    var workingSets: [StrengthSet] { sets.filter { $0.kind != .warmup } }
    var volumeKg: Double { workingSets.compactMap(\.volumeKg).reduce(0, +) }
    /// Best estimated one-rep max of the working sets, for weighted sets of 12 reps or fewer.
    var bestOneRepMax: Double? { workingSets.compactMap(\.estimatedOneRepMax).max() }

    /// The set that stands for the exercise: the heaviest by estimated 1RM, else most reps, else longest.
    var topSet: StrengthSet? {
        let sets = workingSets
        if let weighted = sets.filter({ $0.estimatedOneRepMax != nil }).max(by: { $0.estimatedOneRepMax! < $1.estimatedOneRepMax! }) {
            return weighted
        }
        if let reps = sets.filter({ ($0.reps ?? 0) > 0 }).max(by: { ($0.reps ?? 0) < ($1.reps ?? 0) }) { return reps }
        return sets.max { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }
    }

    /// Working sets with identical sets merged: "3×5 @ 80 kg, 1×4 @ 80 kg (RPE 9)".
    func setsSummary(locale: Locale = .current) -> String {
        var groups: [(set: StrengthSet, count: Int)] = []
        for set in workingSets {
            if let last = groups.last, last.set.sameWork(as: set) {
                groups[groups.count - 1].count += 1
                // Keep the last RPE of a group: the hardest one.
                if set.rpe != nil { groups[groups.count - 1].set.rpe = set.rpe }
            } else {
                groups.append((set, 1))
            }
        }
        return groups.map { group in
            let prefix = group.count > 1 ? "\(group.count)×" : ""
            let rpe = group.set.rpe.map { " (RPE \($0.formatted(.number.precision(.fractionLength(0...1)).locale(locale))))" } ?? ""
            let kind = group.set.kind == .warmup || group.set.kind == .normal ? "" : " \(group.set.kind.rawValue)"
            return prefix + group.set.workText(compactWeight: group.count > 1, locale: locale) + kind + rpe
        }.joined(separator: ", ")
    }
}

nonisolated struct StrengthSet: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case normal, warmup, dropset, failure
    }

    var index: Int
    var kind: Kind
    var weightKg: Double?
    var reps: Int?
    var distanceMeters: Double?
    var durationSeconds: Double?
    var rpe: Double?

    var id: Int { index }

    var volumeKg: Double? {
        guard let weightKg, let reps, weightKg > 0, reps > 0 else { return nil }
        return weightKg * Double(reps)
    }

    /// Epley's estimate; past 12 reps it says more about endurance than strength, so there's none.
    var estimatedOneRepMax: Double? {
        guard let weightKg, let reps, weightKg > 0, (1...12).contains(reps) else { return nil }
        return reps == 1 ? weightKg : weightKg * (1 + Double(reps) / 30)
    }

    func sameWork(as other: StrengthSet) -> Bool {
        weightKg == other.weightKg && reps == other.reps && distanceMeters == other.distanceMeters
            && durationSeconds == other.durationSeconds && kind == other.kind
    }

    /// "80 kg × 5", "12 reps", "45 s", "500 m". With `compactWeight`, "5 @ 80 kg" so a count can go in front.
    func workText(compactWeight: Bool = false, locale: Locale = .current) -> String {
        var parts: [String] = []
        if let reps, reps > 0 {
            if let weightKg, weightKg > 0 {
                parts.append(compactWeight ? "\(reps) @ \(Self.kg(weightKg, locale: locale))" : "\(Self.kg(weightKg, locale: locale)) × \(reps)")
            } else {
                parts.append("\(reps) reps")
            }
        } else if let weightKg, weightKg > 0 {
            parts.append(Self.kg(weightKg, locale: locale))
        }
        if let durationSeconds, durationSeconds > 0 { parts.append(Self.duration(durationSeconds)) }
        if let distanceMeters, distanceMeters > 0 {
            parts.append(distanceMeters >= 1000 ? "\(PromptBuilder.num(distanceMeters / 1000, 2)) km" : "\(Int(distanceMeters)) m")
        }
        return parts.isEmpty ? "–" : parts.joined(separator: ", ")
    }

    /// "80 kg", "76.25 kg". Prompts pass the POSIX locale so the model always sees a decimal point.
    static func kg(_ value: Double, locale: Locale = .current) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(locale))) kg"
    }

    static func duration(_ seconds: Double) -> String {
        seconds >= 60 ? WorkoutFormat.duration(seconds) : "\(Int(seconds)) s"
    }
}

// MARK: - Matching and history

nonisolated enum StrengthLog {
    /// Up to this far apart, a log entry and a watch workout without overlap still count as the same session
    /// (people often start the watch in the locker room or the log after the warm-up).
    static let matchTolerance: TimeInterval = 20 * 60

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
                  best > before + 0.01 else { return nil }
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
            let posix = Locale(identifier: "en_US_POSIX")
            var line = "- \(exercise.title): \(exercise.setsSummary(locale: posix))"
            if let best = exercise.bestOneRepMax {
                line += "; est. 1RM \(num(best, 0)) kg"
                if records.contains(exercise.templateID) { line += " (personal best)" }
            }
            if let previous = previous(exercise, before: session.start, in: history) {
                let when = PromptBuilder.dayLabel(previous.session.start, calendar: .current)
                if compact, let old = previous.exercise.bestOneRepMax {
                    line += "; last time (\(when)) est. 1RM \(num(old, 0)) kg"
                } else {
                    line += "; last time (\(when)): \(previous.exercise.setsSummary(locale: posix))"
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

// MARK: - Overview

/// Strength training over the last weeks: from the watch alone (sessions, minutes, heart rate), and with a
/// lifting log also volume, sets and how the main lifts move.
nonisolated struct StrengthReport: Sendable {
    nonisolated struct Week: Identifiable, Sendable {
        var start: Date
        var sessions: Int
        var minutes: Double
        /// nil without a lifting log.
        var volumeKg: Double?
        var sets: Int?

        var id: Date { start }
    }

    nonisolated struct Lift: Identifiable, Sendable {
        var templateID: String
        var title: String
        var timesDone: Int
        /// Best estimated 1RM per session, oldest first.
        var history: [(date: Date, oneRepMax: Double)]
        var latestTopSet: StrengthSet?

        var id: String { templateID }
        var best: Double? { history.map(\.oneRepMax).max() }
        var latest: Double? { history.last?.oneRepMax }
        /// Latest versus the first session in the window, in kg.
        var change: Double? {
            guard history.count > 1, let first = history.first?.oneRepMax, let latest else { return nil }
            return latest - first
        }
    }

    nonisolated struct Record: Identifiable, Sendable {
        var date: Date
        var title: String
        var oneRepMax: Double
        var set: StrengthSet
        var id: String { "\(date.timeIntervalSince1970)-\(title)" }
    }

    /// A strength session as either source knows it.
    nonisolated struct Entry: Identifiable, Sendable {
        var workout: WorkoutSummary?
        var session: StrengthSession?

        var date: Date { session?.start ?? workout?.start ?? .distantPast }
        var title: String {
            if let title = session?.title, !title.isEmpty { return title }
            return workout?.sport ?? "Strength"
        }
        var minutes: Double { workout?.durationMinutes ?? session?.durationMinutes ?? 0 }
        var id: String { session?.id ?? workout?.id.uuidString ?? "" }
    }

    var hasLog: Bool
    var weeks: [Week]
    var lifts: [Lift]
    var records: [Record]
    /// Newest first.
    var entries: [Entry]

    var last28Days: [Entry]
    var sessionsPerWeek: Double { Double(last28Days.count) / 4 }
    var minutesPerWeek: Double { last28Days.map(\.minutes).reduce(0, +) / 4 }
    var volumeLast28Days: Double? { hasLog ? last28Days.compactMap(\.session).map(\.volumeKg).reduce(0, +) : nil }
    var lastSession: Date? { entries.first?.date }

    /// `sessions` nil means no lifting log is connected; then everything comes from the watch's workouts.
    init(workouts: [WorkoutSummary], sessions: [StrengthSession]?, now: Date = .now, weekCount: Int = 8, calendar: Calendar = .current) {
        let strengthWorkouts = workouts.filter { $0.kind == .strength && $0.start <= now }
        let logged = (sessions ?? []).filter { $0.start <= now }.sorted { $0.start < $1.start }
        hasLog = sessions != nil

        // Pair log entries with watch workouts; unpaired ones of either kind still count as sessions.
        var entries: [Entry] = []
        var pairedWorkouts = Set<UUID>()
        for session in logged {
            let workout = StrengthLog.workout(for: session, in: strengthWorkouts.filter { !pairedWorkouts.contains($0.id) })
            if let workout { pairedWorkouts.insert(workout.id) }
            entries.append(Entry(workout: workout, session: session))
        }
        entries += strengthWorkouts.filter { !pairedWorkouts.contains($0.id) }.map { Entry(workout: $0, session: nil) }
        entries.sort { $0.date > $1.date }
        self.entries = entries

        let today = calendar.startOfDay(for: now)
        let monthAgo = calendar.date(byAdding: .day, value: -27, to: today) ?? today
        last28Days = entries.filter { $0.date >= monthAgo }

        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let hasLog = self.hasLog
        weeks = (0..<weekCount).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            let inWeek = entries.filter { $0.date >= start && $0.date < end }
            let sessions = inWeek.compactMap(\.session)
            return Week(
                start: start,
                sessions: inWeek.count,
                minutes: inWeek.map(\.minutes).reduce(0, +),
                volumeKg: hasLog ? sessions.map(\.volumeKg).reduce(0, +) : nil,
                sets: hasLog ? sessions.map(\.workingSets.count).reduce(0, +) : nil
            )
        }

        // Main lifts: weighted exercises done most often in the window, by estimated 1RM per session.
        let windowStart = weeks.first?.start ?? monthAgo
        var byTemplate: [String: [(session: StrengthSession, exercise: StrengthExercise)]] = [:]
        for session in logged where session.start >= windowStart {
            for exercise in session.exercises where exercise.bestOneRepMax != nil {
                byTemplate[exercise.templateID, default: []].append((session, exercise))
            }
        }
        lifts = byTemplate.map { templateID, done in
            Lift(
                templateID: templateID,
                title: done.last?.exercise.title ?? "",
                timesDone: done.count,
                history: done.compactMap { item in item.exercise.bestOneRepMax.map { (item.session.start, $0) } },
                latestTopSet: done.last?.exercise.topSet
            )
        }
        .sorted { ($0.timesDone, $0.best ?? 0) > ($1.timesDone, $1.best ?? 0) }
        .prefix(6)
        .map(\.self)

        // Personal bests (against all earlier history) in the window, newest first.
        var records: [Record] = []
        for session in logged where session.start >= windowStart {
            let beaten = StrengthLog.records(in: session, history: logged)
            for exercise in session.exercises where beaten.contains(exercise.templateID) {
                guard let best = exercise.bestOneRepMax, let set = exercise.topSet else { continue }
                records.append(Record(date: session.start, title: exercise.title, oneRepMax: best, set: set))
            }
        }
        self.records = records.sorted { $0.date > $1.date }
    }
}
