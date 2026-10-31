import Foundation

/// Long-term progress: XP, levels, period totals, records and achievements, from all available history.
nonisolated struct ProgressReport: Sendable {
    /// One day's worth of everything a metric or skill needs.
    struct Day: Sendable {
        var date: Date
        var sessions = 0
        var trainingMinutes = 0.0
        var load = 0.0
        var distanceKm = 0.0
        var runKm = 0.0
        var strengthMinutes = 0.0
        var steps: Double?
        var activeEnergyKcal: Double?
        var sleepHours: Double?
        var restingHR: Double?
        var hrv: Double?
        var weightKg: Double?
        var skillXP: [Skill: Double] = [:]

        var xp: Double { skillXP.values.reduce(0, +) }

        /// XP for one skill, or for all of them when `skill` is nil.
        func earned(_ skill: Skill?) -> Double {
            skill.map { skillXP[$0] ?? 0 } ?? xp
        }
    }

    private(set) var days: [Date: Day]
    /// The same days, ascending by date, for range lookups.
    private let orderedDays: [Day]
    private(set) var firstDate: Date?
    private(set) var lastDate: Date
    private(set) var athlete: LevelProgress
    private(set) var skills: [Skill: LevelProgress]
    private(set) var records: [PersonalRecord]
    private(set) var achievements: [Achievement]
    /// Consecutive ISO weeks with at least `activeWeekDays` training days, ending this week (or last, if this one isn't there yet).
    private(set) var currentWeekStreak: Int
    private(set) var longestWeekStreak: Int
    private(set) var totalWorkouts: Int
    private(set) var totalHours: Double
    private(set) var totalKm: Double
    private let calendar: Calendar

    /// A week counts toward the streak with this many training days.
    static let activeWeekDays = 2
    /// The window behind `recentStats`.
    static let recentDays = 28
    private static let recentWeeks = Double(recentDays) / 7
    /// Load needs a resting HR; this stands in when a month has no readings at all.
    private static let fallbackRestingHR = 60.0

    init(snapshot: HealthSnapshot, profile: UserProfile, calendar: Calendar = .current) {
        let iso = calendar.iso
        self.calendar = iso
        lastDate = iso.startOfDay(for: snapshot.fetchedAt)

        var days = Self.dailyRecords(snapshot: snapshot, profile: profile, calendar: iso)
        let trainingDaysByWeek = Self.addDiscipline(to: &days, profile: profile, calendar: iso)
        self.days = days
        orderedDays = days.values.sorted { $0.date < $1.date }
        firstDate = orderedDays.first?.date

        var skillTotals: [Skill: Double] = [:]
        for day in days.values {
            for (skill, xp) in day.skillXP { skillTotals[skill, default: 0] += xp }
        }
        skills = Dictionary(uniqueKeysWithValues: Skill.allCases.map { ($0, LevelProgress(xp: skillTotals[$0] ?? 0, base: LevelProgress.skillBase)) })
        athlete = LevelProgress(xp: skillTotals.values.reduce(0, +), base: LevelProgress.athleteBase)

        totalWorkouts = snapshot.workouts.count
        totalHours = snapshot.workouts.map(\.durationMinutes).reduce(0, +) / 60
        totalKm = snapshot.workouts.compactMap(\.distanceKm).reduce(0, +)

        let activeWeeks = Set(trainingDaysByWeek.filter { $0.value.count >= Self.activeWeekDays }.keys)
        (currentWeekStreak, longestWeekStreak) = Self.weekStreaks(activeWeeks: activeWeeks, through: lastDate, calendar: iso)

        records = Self.findRecords(snapshot: snapshot, days: days, calendar: iso)
        achievements = Self.findAchievements(snapshot: snapshot, days: days, profile: profile, activeWeeks: activeWeeks, calendar: iso)
    }

    // MARK: - Building

    /// Per-day metrics and the XP every skill but Discipline earns from them.
    private static func dailyRecords(snapshot: HealthSnapshot, profile: UserProfile, calendar iso: Calendar) -> [Date: Day] {
        // Load needs a resting HR; use each month's median so years-old workouts aren't scored against today's fitness.
        let rhrByMonth = Dictionary(grouping: snapshot.days.filter { $0.restingHeartRate != nil }) { iso.startOfMonth(for: $0.date) }
            .mapValues { MetricsReport.median($0.compactMap(\.restingHeartRate)) ?? fallbackRestingHR }
        let overallRHR = MetricsReport.median(snapshot.days.compactMap(\.restingHeartRate)) ?? fallbackRestingHR
        let maxHR = profile.effectiveMaxHeartRate

        var days: [Date: Day] = [:]
        func update(_ date: Date, _ change: (inout Day) -> Void) {
            let key = iso.startOfDay(for: date)
            var day = days[key] ?? Day(date: key)
            change(&day)
            days[key] = day
        }

        for metrics in snapshot.days {
            update(metrics.date) { day in
                day.steps = metrics.steps
                day.activeEnergyKcal = metrics.activeEnergyKcal
                day.restingHR = metrics.restingHeartRate
                day.hrv = metrics.hrvMs
                day.weightKg = metrics.bodyMassKg
                if let steps = metrics.steps { day.skillXP[.vitality] = XPRules.vitality(steps: steps) }
            }
        }
        for night in snapshot.sleep {
            update(night.date) { day in
                day.sleepHours = night.asleepHours
                day.skillXP[.rest] = XPRules.rest(asleepHours: night.asleepHours, targetHours: profile.sleepTargetHours)
            }
        }
        for workout in snapshot.workouts {
            let restingHR = rhrByMonth[iso.startOfMonth(for: workout.start)] ?? overallRHR
            let load = MetricsReport.trimp(workout, restingHR: restingHR, maxHR: maxHR)
            let km = workout.distanceKm ?? 0
            update(workout.start) { day in
                day.sessions += 1
                day.trainingMinutes += workout.durationMinutes
                day.load += load
                day.distanceKm += km
                if workout.sport == Sport.running { day.runKm += km }
                day.skillXP[.endurance, default: 0] += workout.durationMinutes
                day.skillXP[.power, default: 0] += load
                if XPRules.strengthSports.contains(workout.sport) {
                    day.strengthMinutes += workout.durationMinutes
                    day.skillXP[.strength, default: 0] += workout.durationMinutes * XPRules.strengthPerMinute
                }
                day.skillXP[.explorer, default: 0] += km * XPRules.explorerPerKm(sport: workout.sport)
            }
        }
        return days
    }

    /// Discipline XP: per training day, plus a bonus for each week that reaches the target. Returns the training
    /// days of each week, keyed by the week's start.
    private static func addDiscipline(to days: inout [Date: Day], profile: UserProfile, calendar iso: Calendar) -> [Date: [Date]] {
        let trainingDays = days.values.filter { $0.sessions > 0 }.map(\.date)
        for date in trainingDays { days[date]?.skillXP[.discipline, default: 0] += XPRules.disciplineDay }
        let daysByWeek = Dictionary(grouping: trainingDays) { iso.startOfWeek(for: $0) }
        for (_, dates) in daysByWeek where dates.count >= profile.trainingDaysPerWeek {
            // Credit the bonus on the day the target was reached.
            if let day = dates.sorted()[safe: profile.trainingDaysPerWeek - 1] { days[day]?.skillXP[.discipline, default: 0] += XPRules.disciplineWeekBonus }
        }
        return daysByWeek
    }

    /// The streak of active weeks ending this week (or last week, if this one isn't active yet) and the longest ever.
    private static func weekStreaks(activeWeeks: Set<Date>, through lastDate: Date, calendar iso: Calendar) -> (current: Int, longest: Int) {
        let thisWeek = iso.startOfWeek(for: lastDate)
        var longest = 0, run = 0
        var week = activeWeeks.min()
        while let current = week, current <= thisWeek {
            run = activeWeeks.contains(current) ? run + 1 : 0
            longest = max(longest, run)
            week = iso.date(byAdding: .weekOfYear, value: 1, to: current)
        }
        var streak = 0
        var cursor = activeWeeks.contains(thisWeek) ? thisWeek : iso.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
        while activeWeeks.contains(cursor) {
            streak += 1
            cursor = iso.date(byAdding: .weekOfYear, value: -1, to: cursor) ?? cursor
        }
        return (streak, longest)
    }

    // MARK: - Periods

    func interval(_ granularity: ProgressGranularity, containing date: Date) -> DateInterval {
        calendar.dateInterval(of: granularity.component, for: date) ?? DateInterval(start: date, duration: 86400)
    }

    /// The days in [start, end), found by binary search since `orderedDays` is sorted.
    private func days(from start: Date, to end: Date) -> ArraySlice<Day> {
        let lower = orderedDays.partitionPoint { $0.date < start }
        let upper = orderedDays.partitionPoint { $0.date < end }
        return orderedDays[lower..<max(lower, upper)]
    }

    /// Sum or per-day average over [start, end); nil when no day in it has a value.
    func value(_ metric: ProgressMetric, from start: Date, to end: Date) -> Double? {
        let inRange = days(from: start, to: end)
        if metric.isSum {
            // A period before the first record is "no data", not zero.
            guard let firstDate, end > firstDate else { return nil }
            return inRange.map { Self.daily(metric, $0) ?? 0 }.reduce(0, +)
        }
        return MetricsReport.mean(inRange.compactMap { Self.daily(metric, $0) })
    }

    private static func daily(_ metric: ProgressMetric, _ day: Day) -> Double? {
        switch metric {
        case .xp: day.xp
        case .distance: day.distanceKm
        case .trainingTime: day.trainingMinutes / 60
        case .sessions: Double(day.sessions)
        case .load: day.load
        case .runDistance: day.runKm
        case .steps: day.steps
        case .activeEnergy: day.activeEnergyKcal
        case .sleep: day.sleepHours
        case .restingHR: day.restingHR
        case .hrv: day.hrv
        case .weight: day.weightKg
        }
    }

    /// The last `count` periods, oldest first, never starting before the first day of data.
    func buckets(_ metric: ProgressMetric, granularity: ProgressGranularity, count: Int? = nil) -> [(start: Date, value: Double?)] {
        buckets(granularity: granularity, count: count) { value(metric, from: $0, to: $1) }
    }

    /// XP a skill earned per period, oldest first.
    func skillBuckets(_ skill: Skill, granularity: ProgressGranularity) -> [(start: Date, value: Double?)] {
        buckets(granularity: granularity, count: nil) { start, end in
            days(from: start, to: end).map { $0.earned(skill) }.reduce(0, +)
        }
    }

    private func buckets(granularity: ProgressGranularity, count: Int?, value: (Date, Date) -> Double?) -> [(start: Date, value: Double?)] {
        let current = interval(granularity, containing: lastDate)
        var result: [(Date, Double?)] = []
        var start = current.start
        let firstPeriod = firstDate.map { interval(granularity, containing: $0).start } ?? current.start
        for _ in 0..<(count ?? granularity.chartCount) {
            guard start >= firstPeriod else { break }
            let end = calendar.date(byAdding: granularity.component, value: 1, to: start) ?? start
            result.append((start, value(start, end)))
            guard let previous = calendar.date(byAdding: granularity.component, value: -1, to: start) else { break }
            start = previous
        }
        return result.reversed()
    }

    /// The current period so far against the same stretch of the previous one (e.g. Mon–Wed vs last Mon–Wed).
    func comparison(_ metric: ProgressMetric, granularity: ProgressGranularity) -> PeriodComparison {
        let current = interval(granularity, containing: lastDate)
        let end = calendar.date(byAdding: .day, value: 1, to: lastDate) ?? lastDate
        let elapsed = calendar.dateComponents([.day], from: current.start, to: end).day ?? 1
        let previousStart = calendar.date(byAdding: granularity.component, value: -1, to: current.start) ?? current.start
        let previousEnd = min(calendar.date(byAdding: .day, value: elapsed, to: previousStart) ?? current.start, current.start)
        return PeriodComparison(
            metric: metric,
            current: value(metric, from: current.start, to: end),
            previous: value(metric, from: previousStart, to: previousEnd)
        )
    }

    /// XP per skill earned in the current period, for "+120 this week" labels.
    func skillXP(_ skill: Skill?, in granularity: ProgressGranularity) -> Double {
        let start = interval(granularity, containing: lastDate).start
        return days(from: start, to: .distantFuture).map { $0.earned(skill) }.reduce(0, +)
    }

    /// Level (with the fraction toward the next) at the end of every week, oldest first. nil skill = athlete level.
    func levelHistory(_ skill: Skill?) -> [(date: Date, level: Double)] {
        guard let firstDate else { return [] }
        let base = skill == nil ? LevelProgress.athleteBase : LevelProgress.skillBase
        let xpByWeek = Dictionary(grouping: orderedDays) { interval(.week, containing: $0.date).start }
            .mapValues { days in days.map { $0.earned(skill) }.reduce(0, +) }
        var points: [(Date, Double)] = []
        var total = 0.0
        var week = interval(.week, containing: firstDate).start
        while week <= lastDate {
            total += xpByWeek[week] ?? 0
            let level = LevelProgress(xp: total, base: base)
            points.append((week, Double(level.level) + level.fraction))
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: week) else { break }
            week = next
        }
        return points
    }

    /// The skill's underlying numbers over the last 28 days, so "how am I doing" has an answer beyond XP.
    func recentStats(_ skill: Skill, profile: UserProfile) -> [(label: String, value: String)] {
        let start = calendar.date(byAdding: .day, value: -(Self.recentDays - 1), to: lastDate) ?? lastDate
        let recent = days(from: start, to: .distantFuture)
        let weeks = Self.recentWeeks
        func sum(_ key: KeyPath<Day, Double>) -> Double { recent.map { $0[keyPath: key] }.reduce(0, +) }
        let trainingDays = recent.filter { $0.sessions > 0 }.count
        switch skill {
        case .endurance:
            let hours = sum(\.trainingMinutes) / 60
            return [("Training time", Self.hours(hours)), ("Per week", Self.hours(hours / weeks)), ("Workouts", "\(recent.map(\.sessions).reduce(0, +))")]
        case .power:
            let load = sum(\.load), sessions = recent.map(\.sessions).reduce(0, +)
            return [("Training load", Self.number(load)), ("Per week", Self.number(load / weeks)), ("Per workout", sessions > 0 ? Self.number(load / Double(sessions)) : "–")]
        case .strength:
            let minutes = sum(\.strengthMinutes)
            return [("Strength time", Self.hours(minutes / 60)), ("Strength days", "\(recent.filter { $0.strengthMinutes > 0 }.count)"), ("Per week", Self.hours(minutes / 60 / weeks))]
        case .explorer:
            let km = sum(\.distanceKm)
            return [("Distance", "\(Self.number(km, digits: 1)) km"), ("Per week", "\(Self.number(km / weeks, digits: 1)) km"), ("Running", "\(Self.number(sum(\.runKm), digits: 1)) km")]
        case .vitality:
            let steps = recent.compactMap(\.steps)
            return [
                ("Steps per day", MetricsReport.mean(steps).map { Self.number($0) } ?? "–"),
                ("Days at your \(profile.dailyStepTarget.formatted()) target", "\(steps.filter { $0 >= Double(profile.dailyStepTarget) }.count) of \(steps.count)"),
                ("Days at the \(Int(XPRules.stepsCap).formatted()) XP cap", "\(steps.filter { $0 >= XPRules.stepsCap }.count)"),
            ]
        case .rest:
            let nights = recent.compactMap(\.sleepHours)
            return [
                ("Nights on target", "\(nights.filter { $0 >= profile.sleepTargetHours - XPRules.sleepOnTargetToleranceHours }.count) of \(nights.count)"),
                ("Within an hour", "\(nights.filter { $0 >= profile.sleepTargetHours - XPRules.sleepNearTargetToleranceHours }.count) of \(nights.count)"),
                ("Average sleep", MetricsReport.mean(nights).map { Self.hours($0) } ?? "–"),
            ]
        case .discipline:
            return [
                ("Training days", "\(trainingDays) of \(Self.recentDays)"),
                ("Per week", "\(Self.number(Double(trainingDays) / weeks, digits: 1)) (target \(profile.trainingDaysPerWeek))"),
                ("Week streak", "\(currentWeekStreak) (best \(longestWeekStreak))"),
            ]
        }
    }
}

nonisolated extension ProgressReport {
    static func number(_ value: Double, digits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// "7h 05m" from hours.
    static func hours(_ value: Double) -> String {
        let minutes = Int((value * 60).rounded())
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }
}

private nonisolated extension Array {
    /// The element at `index`, or nil when it's out of range.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private extension RandomAccessCollection {
    /// The index of the first element for which `isBefore` is false, in a collection ordered so that all
    /// elements before it satisfy it (binary search).
    nonisolated func partitionPoint(_ isBefore: (Element) -> Bool) -> Index {
        var low = startIndex, high = endIndex
        while low < high {
            let mid = index(low, offsetBy: distance(from: low, to: high) / 2)
            if isBefore(self[mid]) { low = index(after: mid) } else { high = mid }
        }
        return low
    }
}
