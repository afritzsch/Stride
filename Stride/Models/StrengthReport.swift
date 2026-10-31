import Foundation

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

    /// How many main lifts the overview shows.
    private static let maxLifts = 6

    var hasLog: Bool
    var weeks: [Week]
    var lifts: [Lift]
    var records: [Record]
    /// Newest first.
    var entries: [Entry]

    /// Sessions in the last 28 days, the window behind the per-week figures.
    var last28Days: [Entry]
    private static let recentWeeks = 4.0
    var sessionsPerWeek: Double { Double(last28Days.count) / Self.recentWeeks }
    var minutesPerWeek: Double { last28Days.map(\.minutes).reduce(0, +) / Self.recentWeeks }
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
        let recentStart = calendar.date(byAdding: .day, value: -27, to: today) ?? today
        last28Days = entries.filter { $0.date >= recentStart }

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
        let windowStart = weeks.first?.start ?? recentStart
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
        .prefix(Self.maxLifts)
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
