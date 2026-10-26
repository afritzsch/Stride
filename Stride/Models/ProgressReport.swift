import Foundation

/// Bucket size for progress charts and period comparisons.
nonisolated enum ProgressGranularity: String, CaseIterable, Identifiable, Sendable {
    case week, month, year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "Weeks"
        case .month: "Months"
        case .year: "Years"
        }
    }

    var currentTitle: String {
        switch self {
        case .week: "This week"
        case .month: "This month"
        case .year: "This year"
        }
    }

    var previousTitle: String {
        switch self {
        case .week: "last week"
        case .month: "last month"
        case .year: "last year"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// How many buckets the chart shows.
    var chartCount: Int {
        switch self {
        case .week: 26
        case .month: 24
        case .year: 10
        }
    }
}

/// Every number the progress screen can chart. Sums add up over a period; averages average the days that have a value.
nonisolated enum ProgressMetric: String, CaseIterable, Identifiable, Sendable {
    case xp, distance, trainingTime, sessions, load, runDistance, steps, activeEnergy, sleep, restingHR, hrv, weight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xp: "XP earned"
        case .distance: "Distance"
        case .trainingTime: "Training time"
        case .sessions: "Workouts"
        case .load: "Training load"
        case .runDistance: "Running distance"
        case .steps: "Steps per day"
        case .activeEnergy: "Active energy per day"
        case .sleep: "Sleep per night"
        case .restingHR: "Resting HR"
        case .hrv: "HRV"
        case .weight: "Weight"
        }
    }

    var unit: String {
        switch self {
        case .xp: "XP"
        case .distance, .runDistance: "km"
        case .trainingTime: "h"
        case .sessions: ""
        case .load: "TRIMP"
        case .steps: "steps"
        case .activeEnergy: "kcal"
        case .sleep: "h"
        case .restingHR: "bpm"
        case .hrv: "ms"
        case .weight: "kg"
        }
    }

    var digits: Int {
        switch self {
        case .trainingTime, .sleep, .weight, .distance, .runDistance: 1
        default: 0
        }
    }

    var systemImage: String {
        switch self {
        case .xp: "star.fill"
        case .distance: "map.fill"
        case .trainingTime: "stopwatch.fill"
        case .sessions: "figure.mixed.cardio"
        case .load: "flame.fill"
        case .runDistance: "figure.run"
        case .steps: "shoeprints.fill"
        case .activeEnergy: "bolt.heart.fill"
        case .sleep: "bed.double.fill"
        case .restingHR: "heart.fill"
        case .hrv: "waveform.path.ecg"
        case .weight: "scalemass.fill"
        }
    }

    /// Sums grow with the period's length, so they're compared over the same elapsed time.
    var isSum: Bool {
        switch self {
        case .xp, .distance, .trainingTime, .sessions, .load, .runDistance: true
        case .steps, .activeEnergy, .sleep, .restingHR, .hrv, .weight: false
        }
    }

    /// nil when neither direction is better (weight depends on the goal).
    var higherIsBetter: Bool? {
        switch self {
        case .restingHR: false
        case .weight: nil
        default: true
        }
    }
}

/// A trainable attribute, RPG style. Each earns XP from one kind of effort; the athlete level adds them all up.
nonisolated enum Skill: String, CaseIterable, Identifiable, Sendable {
    case endurance, power, strength, explorer, vitality, rest, discipline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .endurance: "Endurance"
        case .power: "Power"
        case .strength: "Strength"
        case .explorer: "Explorer"
        case .vitality: "Vitality"
        case .rest: "Rest"
        case .discipline: "Discipline"
        }
    }

    var systemImage: String {
        switch self {
        case .endurance: "lungs.fill"
        case .power: "bolt.fill"
        case .strength: "dumbbell.fill"
        case .explorer: "map.fill"
        case .vitality: "shoeprints.fill"
        case .rest: "moon.zzz.fill"
        case .discipline: "calendar.badge.checkmark"
        }
    }

    var meaning: String {
        switch self {
        case .endurance: "Your aerobic base: how much time you spend training. Volume is the foundation every other kind of fitness is built on."
        case .power: "How hard you train. Training load weights every minute by heart rate, so a minute in Z4–5 counts several times more than an easy one."
        case .strength: "Resistance and functional work that keeps muscles, tendons and bones resilient, which makes you faster and less injury-prone."
        case .explorer: "Ground covered. A km on foot counts most; cycling counts less per km because it's faster, swimming more because it's slower."
        case .vitality: "Everyday movement outside training. Lots of light activity helps recovery and long-term health, and it adds up."
        case .rest: "Sleep, where training turns into fitness. Without enough of it, hard sessions mostly just make you tired."
        case .discipline: "Consistency. Showing up most days, week after week, beats occasional big efforts."
        }
    }

    /// Where the numbers come from, with the user's own settings filled in.
    func tracking(profile: UserProfile) -> String {
        switch self {
        case .endurance:
            "Duration of every workout in Apple Health, any sport and any intensity."
        case .power:
            "Banister TRIMP from each workout's average heart rate, your max HR (\(Int(profile.effectiveMaxHeartRate)) bpm) and your resting HR in that month. Workouts without heart rate count as moderate effort."
        case .strength:
            "Minutes of workouts recorded as Strength, HIIT, Core, Climbing or Cross training. A gym session saved as \"Other\" or \"Cardio\" doesn't count."
        case .explorer:
            "The distance your watch saved with each workout. Workouts without a distance, like strength or yoga, earn nothing here."
        case .vitality:
            "Daily step count from Apple Health (watch and phone combined, without double counting). Steps above 30,000 a day don't add XP."
        case .rest:
            "Time asleep per night from Apple Health, against your sleep target in Settings (\(ProgressReport.hours(profile.sleepTargetHours))). Naps don't count."
        case .discipline:
            "Any day with at least one workout is a training day. The weekly bonus comes once a week reaches your training days per week in Settings (\(profile.trainingDaysPerWeek))."
        }
    }

    var tips: [String] {
        switch self {
        case .endurance: [
            "Add time before intensity: make one session a week, often the long run, 10 minutes longer.",
            "Keep most sessions easy (Z1–2). Easy volume is what you can sustain and recover from.",
            "Grow weekly time by about 10% at most, with a lighter week every 3–4 weeks.",
        ]
        case .power: [
            "One or two quality sessions a week (intervals, tempo, hills) earn the most load per minute.",
            "Keep the acute:chronic ratio on the Dashboard within 0.8–1.3. Sudden spikes raise the injury risk.",
            "Keep the easy days truly easy, so the hard days can be hard.",
        ]
        case .strength: [
            "Two 30–45 minute sessions a week are enough to see results.",
            "Record them on your watch as a strength workout so they count here.",
            "For runners, focus on legs, hips and core: squats, lunges, deadlifts, calf raises, planks.",
        ]
        case .explorer: [
            "Make one long run or ride a week your anchor session.",
            "Walks and hikes count too, if you record them as workouts.",
            "Check that Garmin Connect shares workout distance with Apple Health.",
        ]
        case .vitality: [
            "Walk for short trips, take calls on foot, add a 10-minute walk after meals.",
            "Set a realistic step target in Settings and aim to hit it on most days.",
            "Rest days are a good time for an easy walk: movement without training stress.",
        ]
        case .rest: [
            "Keep your bedtime within about 30 minutes, also on weekends.",
            "Count back from your wake-up time and start winding down 30 minutes before.",
            "Avoid caffeine after early afternoon, alcohol, and hard sessions late in the evening.",
        ]
        case .discipline: [
            "Spread training over more days. Even a 20-minute session counts as a training day.",
            "Set training days per week in Settings to what you can really do, then hit it.",
            "Plan the week ahead (the Plan tab helps) so sessions don't depend on motivation.",
        ]
        }
    }

    /// How the skill earns XP, shown in the UI so the numbers aren't a black box.
    var rule: String {
        switch self {
        case .endurance: "1 XP per minute of any workout"
        case .power: "1 XP per point of training load (TRIMP), so hard sessions count more"
        case .strength: "3 XP per minute of strength, HIIT, core or climbing"
        case .explorer: "10 XP per km on foot, 3 per km cycling, 40 per km swimming"
        case .vitality: "2 XP per 1,000 daily steps, up to 60 a day"
        case .rest: "20 XP per night at your sleep target, 10 within an hour of it"
        case .discipline: "25 XP per training day, +50 for each week you hit your training days"
        }
    }
}

/// Level from cumulative XP. Reaching level L takes `base × L²` XP, so each level takes a bit longer than the last.
nonisolated struct LevelProgress: Sendable, Equatable {
    var xp: Double
    var level: Int
    var levelStartXP: Double
    var nextLevelXP: Double

    init(xp: Double, base: Double) {
        self.xp = xp
        level = Int((max(xp, 0) / base).squareRoot())
        levelStartXP = base * Double(level * level)
        nextLevelXP = base * Double((level + 1) * (level + 1))
    }

    var fraction: Double { min(max((xp - levelStartXP) / (nextLevelXP - levelStartXP), 0), 1) }
    var xpToNext: Double { nextLevelXP - xp }

    static let athleteBase = 100.0
    static let skillBase = 20.0

    /// A rank name every 10 levels.
    var title: String { Self.rankTitle(level: level) }

    static func rankTitle(level: Int) -> String {
        let titles = ["Novice", "Apprentice", "Contender", "Athlete", "Veteran", "Elite", "Champion", "Master", "Grandmaster", "Legend"]
        return titles[min(max(level, 0) / 10, titles.count - 1)]
    }
}

nonisolated struct PersonalRecord: Identifiable, Sendable {
    var id: String
    var title: String
    var value: String
    var date: Date
    var systemImage: String
}

nonisolated struct Achievement: Identifiable, Sendable {
    var id: String
    var title: String
    var detail: String
    var systemImage: String
    var target: Double
    var current: Double
    var unlockedAt: Date?

    var isUnlocked: Bool { unlockedAt != nil }
    var fraction: Double { min(current / target, 1) }
}

nonisolated struct PeriodComparison: Identifiable, Sendable {
    var metric: ProgressMetric
    var current: Double?
    var previous: Double?

    var id: ProgressMetric { metric }
}

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
    }

    var days: [Date: Day]
    var firstDate: Date?
    var lastDate: Date
    var athlete: LevelProgress
    var skills: [Skill: LevelProgress]
    var records: [PersonalRecord]
    var achievements: [Achievement]
    /// Consecutive ISO weeks with at least `activeWeekDays` training days, ending this week (or last, if this one isn't there yet).
    var currentWeekStreak: Int
    var longestWeekStreak: Int
    var totalWorkouts: Int
    var totalHours: Double
    var totalKm: Double
    private let calendar: Calendar

    /// A week counts toward the streak with this many training days.
    static let activeWeekDays = 2

    init(snapshot: HealthSnapshot, profile: UserProfile, calendar: Calendar = .current) {
        var iso = calendar
        iso.firstWeekday = 2
        iso.minimumDaysInFirstWeek = 4
        self.calendar = iso
        lastDate = iso.startOfDay(for: snapshot.fetchedAt)

        // Load needs a resting HR; use each month's median so years-old workouts aren't scored against today's fitness.
        func monthStart(_ date: Date) -> Date { iso.dateInterval(of: .month, for: date)?.start ?? date }
        let rhrByMonth = Dictionary(grouping: snapshot.days.filter { $0.restingHeartRate != nil }) { monthStart($0.date) }
            .mapValues { MetricsReport.median($0.compactMap(\.restingHeartRate)) ?? 60 }
        let overallRHR = MetricsReport.median(snapshot.days.compactMap(\.restingHeartRate)) ?? 60
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
                if let steps = metrics.steps { day.skillXP[.vitality] = min(steps / 1000 * 2, 60) }
            }
        }
        for night in snapshot.sleep {
            update(night.date) { day in
                day.sleepHours = night.asleepHours
                let short = profile.sleepTargetHours - night.asleepHours
                day.skillXP[.rest] = short <= 0.25 ? 20 : short <= 1 ? 10 : 0
            }
        }
        for workout in snapshot.workouts {
            let restingHR = rhrByMonth[monthStart(workout.start)] ?? overallRHR
            let load = MetricsReport.trimp(workout, restingHR: restingHR, maxHR: maxHR)
            let km = workout.distanceKm ?? 0
            update(workout.start) { day in
                day.sessions += 1
                day.trainingMinutes += workout.durationMinutes
                day.load += load
                day.distanceKm += km
                if workout.sport == "Running" { day.runKm += km }
                day.skillXP[.endurance, default: 0] += workout.durationMinutes
                day.skillXP[.power, default: 0] += load
                if Self.strengthSports.contains(workout.sport) {
                    day.strengthMinutes += workout.durationMinutes
                    day.skillXP[.strength, default: 0] += workout.durationMinutes * 3
                }
                day.skillXP[.explorer, default: 0] += km * Self.kmXP(sport: workout.sport)
            }
        }

        // Discipline: per training day, plus a bonus for each week that reaches the target.
        func weekStart(_ date: Date) -> Date { iso.dateInterval(of: .weekOfYear, for: date)?.start ?? date }
        let trainingDays = days.values.filter { $0.sessions > 0 }.map(\.date)
        for date in trainingDays { days[date]?.skillXP[.discipline, default: 0] += 25 }
        let daysByWeek = Dictionary(grouping: trainingDays, by: weekStart)
        for (_, dates) in daysByWeek where dates.count >= profile.trainingDaysPerWeek {
            // Credit the bonus on the day the target was reached.
            if let day = dates.sorted()[safe: profile.trainingDaysPerWeek - 1] { days[day]?.skillXP[.discipline, default: 0] += 50 }
        }

        self.days = days
        firstDate = days.keys.min()

        var skillTotals: [Skill: Double] = [:]
        for day in days.values {
            for (skill, xp) in day.skillXP { skillTotals[skill, default: 0] += xp }
        }
        skills = Dictionary(uniqueKeysWithValues: Skill.allCases.map { ($0, LevelProgress(xp: skillTotals[$0] ?? 0, base: LevelProgress.skillBase)) })
        athlete = LevelProgress(xp: skillTotals.values.reduce(0, +), base: LevelProgress.athleteBase)

        totalWorkouts = snapshot.workouts.count
        totalHours = snapshot.workouts.map(\.durationMinutes).reduce(0, +) / 60
        totalKm = snapshot.workouts.compactMap(\.distanceKm).reduce(0, +)

        // Week streaks.
        let activeWeeks = Set(daysByWeek.filter { $0.value.count >= Self.activeWeekDays }.keys)
        var longest = 0, run = 0
        var week = activeWeeks.min()
        let thisWeek = weekStart(lastDate)
        while let current = week, current <= thisWeek {
            run = activeWeeks.contains(current) ? run + 1 : 0
            longest = max(longest, run)
            week = iso.date(byAdding: .weekOfYear, value: 1, to: current)
        }
        longestWeekStreak = longest
        var streak = 0
        var cursor = activeWeeks.contains(thisWeek) ? thisWeek : iso.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
        while activeWeeks.contains(cursor) {
            streak += 1
            cursor = iso.date(byAdding: .weekOfYear, value: -1, to: cursor) ?? cursor
        }
        currentWeekStreak = streak

        records = Self.findRecords(snapshot: snapshot, days: days, weekStart: weekStart, longestStreak: longest)
        achievements = Self.findAchievements(snapshot: snapshot, days: days, profile: profile, activeWeeks: activeWeeks, calendar: iso)
    }

    static let strengthSports: Set<String> = ["Strength", "HIIT", "Core", "Climbing", "Cross training"]

    static func kmXP(sport: String) -> Double {
        switch sport {
        case "Running", "Walking", "Hiking": 10
        case "Swimming": 40
        case "Cycling": 3
        default: 5
        }
    }

    // MARK: - Periods

    func interval(_ granularity: ProgressGranularity, containing date: Date) -> DateInterval {
        calendar.dateInterval(of: granularity.component, for: date) ?? DateInterval(start: date, duration: 86400)
    }

    /// Sum or per-day average over [start, end); nil when no day in it has a value.
    func value(_ metric: ProgressMetric, from start: Date, to end: Date) -> Double? {
        let inRange = days.values.filter { $0.date >= start && $0.date < end }
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
            days.values.filter { $0.date >= start && $0.date < end }.map { $0.skillXP[skill] ?? 0 }.reduce(0, +)
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
        return days.values.filter { $0.date >= start }.map { day in
            skill.map { day.skillXP[$0] ?? 0 } ?? day.xp
        }.reduce(0, +)
    }

    /// Level (with the fraction toward the next) at the end of every week, oldest first. nil skill = athlete level.
    func levelHistory(_ skill: Skill?) -> [(date: Date, level: Double)] {
        guard let firstDate else { return [] }
        let base = skill == nil ? LevelProgress.athleteBase : LevelProgress.skillBase
        let xpByWeek = Dictionary(grouping: days.values) { interval(.week, containing: $0.date).start }
            .mapValues { days in days.map { day in skill.map { day.skillXP[$0] ?? 0 } ?? day.xp }.reduce(0, +) }
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
        let start = calendar.date(byAdding: .day, value: -27, to: lastDate) ?? lastDate
        let recent = days.values.filter { $0.date >= start }
        func sum(_ key: KeyPath<Day, Double>) -> Double { recent.map { $0[keyPath: key] }.reduce(0, +) }
        let trainingDays = recent.filter { $0.sessions > 0 }.count
        switch skill {
        case .endurance:
            let hours = sum(\.trainingMinutes) / 60
            return [("Training time", Self.hours(hours)), ("Per week", Self.hours(hours / 4)), ("Workouts", "\(recent.map(\.sessions).reduce(0, +))")]
        case .power:
            let load = sum(\.load), sessions = recent.map(\.sessions).reduce(0, +)
            return [("Training load", Self.number(load)), ("Per week", Self.number(load / 4)), ("Per workout", sessions > 0 ? Self.number(load / Double(sessions)) : "–")]
        case .strength:
            let minutes = sum(\.strengthMinutes)
            return [("Strength time", Self.hours(minutes / 60)), ("Strength days", "\(recent.filter { $0.strengthMinutes > 0 }.count)"), ("Per week", Self.hours(minutes / 60 / 4))]
        case .explorer:
            let km = sum(\.distanceKm)
            return [("Distance", "\(Self.number(km, digits: 1)) km"), ("Per week", "\(Self.number(km / 4, digits: 1)) km"), ("Running", "\(Self.number(sum(\.runKm), digits: 1)) km")]
        case .vitality:
            let steps = recent.compactMap(\.steps)
            return [
                ("Steps per day", MetricsReport.mean(steps).map { Self.number($0) } ?? "–"),
                ("Days at your \(profile.dailyStepTarget.formatted()) target", "\(steps.filter { $0 >= Double(profile.dailyStepTarget) }.count) of \(steps.count)"),
                ("Days at the 30,000 XP cap", "\(steps.filter { $0 >= 30_000 }.count)"),
            ]
        case .rest:
            let nights = recent.compactMap(\.sleepHours)
            return [
                ("Nights on target", "\(nights.filter { $0 >= profile.sleepTargetHours - 0.25 }.count) of \(nights.count)"),
                ("Within an hour", "\(nights.filter { $0 >= profile.sleepTargetHours - 1 }.count) of \(nights.count)"),
                ("Average sleep", MetricsReport.mean(nights).map { Self.hours($0) } ?? "–"),
            ]
        case .discipline:
            return [
                ("Training days", "\(trainingDays) of 28"),
                ("Per week", "\(Self.number(Double(trainingDays) / 4, digits: 1)) (target \(profile.trainingDaysPerWeek))"),
                ("Week streak", "\(currentWeekStreak) (best \(longestWeekStreak))"),
            ]
        }
    }

    // MARK: - Records

    private static func findRecords(
        snapshot: HealthSnapshot,
        days: [Date: Day],
        weekStart: (Date) -> Date,
        longestStreak: Int
    ) -> [PersonalRecord] {
        var records: [PersonalRecord] = []
        let workouts = snapshot.workouts
        func km(_ value: Double) -> String { "\(number(value, digits: 1)) km" }

        if let run = workouts.filter({ $0.sport == "Running" }).max(by: { ($0.distanceKm ?? 0) < ($1.distanceKm ?? 0) }), let distance = run.distanceKm {
            records.append(PersonalRecord(id: "longestRun", title: "Longest run", value: km(distance), date: run.start, systemImage: "figure.run"))
        }
        // Average pace only: Apple Health doesn't carry best-effort splits.
        if let run = workouts.filter({ $0.sport == "Running" && ($0.distanceKm ?? 0) >= 5 }).min(by: { ($0.paceSecondsPerKm ?? .infinity) < ($1.paceSecondsPerKm ?? .infinity) }) {
            records.append(PersonalRecord(id: "fastestRun", title: "Fastest run ≥ 5 km (avg pace)", value: "\(WorkoutFormat.pace(run.paceSecondsPerKm)) /km", date: run.start, systemImage: "hare.fill"))
        }
        if let ride = workouts.filter({ $0.sport == "Cycling" }).max(by: { ($0.distanceKm ?? 0) < ($1.distanceKm ?? 0) }), let distance = ride.distanceKm {
            records.append(PersonalRecord(id: "longestRide", title: "Longest ride", value: km(distance), date: ride.start, systemImage: "figure.outdoor.cycle"))
        }
        if let longest = workouts.max(by: { $0.durationMinutes < $1.durationMinutes }) {
            records.append(PersonalRecord(id: "longestWorkout", title: "Longest workout", value: hours(longest.durationMinutes / 60), date: longest.start, systemImage: "stopwatch.fill"))
        }

        let weeks = Dictionary(grouping: days.values) { weekStart($0.date) }
        if let best = weeks.max(by: { $0.value.map(\.distanceKm).reduce(0, +) < $1.value.map(\.distanceKm).reduce(0, +) }) {
            let total = best.value.map(\.distanceKm).reduce(0, +)
            if total > 0 { records.append(PersonalRecord(id: "biggestWeek", title: "Biggest week (distance)", value: km(total), date: best.key, systemImage: "map.fill")) }
        }
        if let best = weeks.max(by: { $0.value.map(\.trainingMinutes).reduce(0, +) < $1.value.map(\.trainingMinutes).reduce(0, +) }) {
            let total = best.value.map(\.trainingMinutes).reduce(0, +)
            if total > 0 { records.append(PersonalRecord(id: "busiestWeek", title: "Biggest week (time)", value: hours(total / 60), date: best.key, systemImage: "calendar")) }
        }
        if let best = days.values.filter({ $0.steps != nil }).max(by: { $0.steps! < $1.steps! }), let steps = best.steps {
            records.append(PersonalRecord(id: "mostSteps", title: "Most steps in a day", value: number(steps), date: best.date, systemImage: "shoeprints.fill"))
        }
        // Weekly averages for recovery markers, so one odd reading doesn't set the record.
        func weeklyAverage(_ key: KeyPath<Day, Double?>) -> [(Date, Double)] {
            weeks.compactMap { week, days in
                let values = days.compactMap { $0[keyPath: key] }
                return values.count >= 4 ? MetricsReport.mean(values).map { (week, $0) } : nil
            }
        }
        if let best = weeklyAverage(\.restingHR).min(by: { $0.1 < $1.1 }) {
            records.append(PersonalRecord(id: "lowestRHR", title: "Lowest resting HR (week avg)", value: "\(number(best.1)) bpm", date: best.0, systemImage: "heart.fill"))
        }
        if let best = weeklyAverage(\.hrv).max(by: { $0.1 < $1.1 }) {
            records.append(PersonalRecord(id: "highestHRV", title: "Highest HRV (week avg)", value: "\(number(best.1)) ms", date: best.0, systemImage: "waveform.path.ecg"))
        }
        return records
    }

    // MARK: - Achievements

    private static func findAchievements(
        snapshot: HealthSnapshot,
        days: [Date: Day],
        profile: UserProfile,
        activeWeeks: Set<Date>,
        calendar: Calendar
    ) -> [Achievement] {
        var list: [Achievement] = []
        let workouts = snapshot.workouts

        /// Unlocks on the date the running total first reaches each target.
        func cumulative(_ id: String, _ targets: [Double], title: (Double) -> String, detail: (Double) -> String, image: String, values: [(Date, Double)]) {
            var total = 0.0
            var reached: [Double: Date] = [:]
            for (date, value) in values.sorted(by: { $0.0 < $1.0 }) {
                total += value
                for target in targets where reached[target] == nil && total >= target { reached[target] = date }
            }
            for target in targets {
                list.append(Achievement(id: "\(id)\(Int(target))", title: title(target), detail: detail(target), systemImage: image, target: target, current: total, unlockedAt: reached[target]))
            }
        }

        cumulative("workouts", [1, 10, 50, 100, 250, 500, 1000],
                   title: { $0 == 1 ? "First step" : "\(Int($0)) workouts" },
                   detail: { $0 == 1 ? "Log your first workout" : "Log \(Int($0)) workouts" },
                   image: "figure.mixed.cardio", values: workouts.map { ($0.start, 1) })
        cumulative("km", [100, 500, 1000, 2500, 5000, 10000],
                   title: { "\(Int($0).formatted()) km club" },
                   detail: { "Cover \(Int($0).formatted()) km in workouts" },
                   image: "map.fill", values: workouts.map { ($0.start, $0.distanceKm ?? 0) })
        cumulative("hours", [10, 100, 250, 500, 1000],
                   title: { "\(Int($0).formatted()) hours" },
                   detail: { "Train for \(Int($0).formatted()) hours in total" },
                   image: "stopwatch.fill", values: workouts.map { ($0.start, $0.durationMinutes / 60) })

        // Single-run distances.
        let runs = workouts.filter { $0.sport == "Running" }.sorted { $0.start < $1.start }
        let longestRun = runs.compactMap(\.distanceKm).max() ?? 0
        for (km, name) in [(5.0, "5K"), (10, "10K"), (21.0975, "Half marathon"), (42.195, "Marathon")] {
            // Small tolerance: watches often stop a few metres short of the official distance.
            let first = runs.first { ($0.distanceKm ?? 0) >= km * 0.99 }
            list.append(Achievement(id: "run\(Int(km))", title: name, detail: "Run \(number(km, digits: km < 20 ? 0 : 1)) km in one go", systemImage: "figure.run", target: km, current: longestRun, unlockedAt: first?.start))
        }

        // Steps in a day.
        let stepDays = days.values.filter { $0.steps != nil }.sorted { $0.date < $1.date }
        let maxSteps = stepDays.compactMap(\.steps).max() ?? 0
        for target in [10_000.0, 20_000, 30_000] {
            list.append(Achievement(id: "steps\(Int(target))", title: "\(Int(target / 1000))k day", detail: "Walk \(Int(target).formatted()) steps in a day", systemImage: "shoeprints.fill", target: target, current: maxSteps, unlockedAt: stepDays.first { ($0.steps ?? 0) >= target }?.date))
        }

        /// Unlocks when a run of consecutive qualifying units first reaches each target.
        func streak(_ id: String, _ targets: [Int], title: (Int) -> String, detail: (Int) -> String, image: String, units: [Date], qualifies: (Date) -> Bool) {
            var run = 0, best = 0
            var reached: [Int: Date] = [:]
            for unit in units {
                run = qualifies(unit) ? run + 1 : 0
                best = max(best, run)
                for target in targets where reached[target] == nil && run >= target { reached[target] = unit }
            }
            for target in targets {
                list.append(Achievement(id: "\(id)\(target)", title: title(target), detail: detail(target), systemImage: image, target: Double(target), current: Double(best), unlockedAt: reached[target]))
            }
        }

        let first = days.keys.min() ?? calendar.startOfDay(for: snapshot.fetchedAt)
        let last = calendar.startOfDay(for: snapshot.fetchedAt)
        var allDays: [Date] = []
        var cursor = first
        while cursor <= last {
            allDays.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? last.addingTimeInterval(86400)
        }
        streak("sleep", [7, 30, 100],
               title: { "Well rested ×\($0)" },
               detail: { "\($0) nights in a row within 15 min of your \(hours(profile.sleepTargetHours)) target" },
               image: "moon.zzz.fill", units: allDays) { (days[$0]?.sleepHours ?? 0) >= profile.sleepTargetHours - 0.25 }

        var allWeeks: [Date] = []
        if let firstWeek = activeWeeks.min() ?? calendar.dateInterval(of: .weekOfYear, for: first)?.start {
            var week = firstWeek
            while week <= last {
                allWeeks.append(week)
                week = calendar.date(byAdding: .weekOfYear, value: 1, to: week) ?? last.addingTimeInterval(86400)
            }
        }
        streak("weeks", [4, 12, 26, 52, 104],
               title: { "\($0)-week streak" },
               detail: { "\($0) weeks in a row with \(Self.activeWeekDays)+ training days" },
               image: "flame.fill", units: allWeeks) { activeWeeks.contains($0) }

        return list
    }
}

nonisolated extension ProgressReport {
    static func number(_ value: Double, digits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    static func hours(_ value: Double) -> String {
        let minutes = Int((value * 60).rounded())
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }
}

private nonisolated extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
