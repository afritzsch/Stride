import Foundation

// Personal records and achievements: what the progress screen celebrates.

nonisolated extension ProgressReport {
    /// A run counts toward a distance milestone within this share of it: watches often stop a few metres short.
    static let distanceTolerance = 0.99
    /// A week needs this many days with a reading to be eligible for a resting HR or HRV record.
    static let minDaysForWeeklyAverage = 4
    /// Fastest-run record only looks at runs at least this long.
    static let minFastestRunKm = 5.0
    static let singleRunMilestones: [(km: Double, name: String)] = [(5, "5K"), (10, "10K"), (21.0975, "Half marathon"), (42.195, "Marathon")]

    // MARK: - Records

    static func findRecords(snapshot: HealthSnapshot, days: [Date: Day], calendar: Calendar) -> [PersonalRecord] {
        var records: [PersonalRecord] = []
        let workouts = snapshot.workouts
        func km(_ value: Double) -> String { "\(number(value, digits: 1)) km" }
        func longest(_ sport: String, by key: (WorkoutSummary) -> Double) -> WorkoutSummary? {
            workouts.filter { $0.sport == sport }.max { key($0) < key($1) }
        }

        if let run = longest(Sport.running, by: { $0.distanceKm ?? 0 }), let distance = run.distanceKm {
            records.append(PersonalRecord(id: "longestRun", title: "Longest run", value: km(distance), date: run.start, systemImage: "figure.run"))
        }
        // Average pace only: Apple Health doesn't carry best-effort splits.
        if let run = workouts.filter({ $0.sport == Sport.running && ($0.distanceKm ?? 0) >= minFastestRunKm }).min(by: { ($0.paceSecondsPerKm ?? .infinity) < ($1.paceSecondsPerKm ?? .infinity) }) {
            records.append(PersonalRecord(id: "fastestRun", title: "Fastest run ≥ \(Int(minFastestRunKm)) km (avg pace)", value: "\(WorkoutFormat.pace(run.paceSecondsPerKm)) /km", date: run.start, systemImage: "hare.fill"))
        }
        if let ride = longest(Sport.cycling, by: { $0.distanceKm ?? 0 }), let distance = ride.distanceKm {
            records.append(PersonalRecord(id: "longestRide", title: "Longest ride", value: km(distance), date: ride.start, systemImage: "figure.outdoor.cycle"))
        }
        if let longest = workouts.max(by: { $0.durationMinutes < $1.durationMinutes }) {
            records.append(PersonalRecord(id: "longestWorkout", title: "Longest workout", value: hours(longest.durationMinutes / 60), date: longest.start, systemImage: "stopwatch.fill"))
        }

        let weeks = Dictionary(grouping: days.values) { calendar.startOfWeek(for: $0.date) }
        /// The week with the highest total, as (week start, total).
        func bestWeek(_ key: KeyPath<Day, Double>) -> (Date, Double)? {
            weeks.map { ($0.key, $0.value.map { $0[keyPath: key] }.reduce(0, +)) }.max { $0.1 < $1.1 }
        }
        if let best = bestWeek(\.distanceKm), best.1 > 0 {
            records.append(PersonalRecord(id: "biggestWeek", title: "Biggest week (distance)", value: km(best.1), date: best.0, systemImage: "map.fill"))
        }
        if let best = bestWeek(\.trainingMinutes), best.1 > 0 {
            records.append(PersonalRecord(id: "busiestWeek", title: "Biggest week (time)", value: hours(best.1 / 60), date: best.0, systemImage: "calendar"))
        }
        if let best = days.values.max(by: { ($0.steps ?? -1) < ($1.steps ?? -1) }), let steps = best.steps {
            records.append(PersonalRecord(id: "mostSteps", title: "Most steps in a day", value: number(steps), date: best.date, systemImage: "shoeprints.fill"))
        }
        // Weekly averages for recovery markers, so one odd reading doesn't set the record.
        func weeklyAverage(_ key: KeyPath<Day, Double?>) -> [(Date, Double)] {
            weeks.compactMap { week, days in
                let values = days.compactMap { $0[keyPath: key] }
                return values.count >= minDaysForWeeklyAverage ? MetricsReport.mean(values).map { (week, $0) } : nil
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

    static func findAchievements(
        snapshot: HealthSnapshot,
        days: [Date: Day],
        profile: UserProfile,
        activeWeeks: Set<Date>,
        calendar: Calendar
    ) -> [Achievement] {
        let workouts = snapshot.workouts
        var list: [Achievement] = []

        list += cumulative("workouts", [1, 10, 50, 100, 250, 500, 1000],
                           title: { $0 == 1 ? "First step" : "\(Int($0)) workouts" },
                           detail: { $0 == 1 ? "Log your first workout" : "Log \(Int($0)) workouts" },
                           image: "figure.mixed.cardio", values: workouts.map { ($0.start, 1) })
        list += cumulative("km", [100, 500, 1000, 2500, 5000, 10000],
                           title: { "\(Int($0).formatted()) km club" },
                           detail: { "Cover \(Int($0).formatted()) km in workouts" },
                           image: "map.fill", values: workouts.map { ($0.start, $0.distanceKm ?? 0) })
        list += cumulative("hours", [10, 100, 250, 500, 1000],
                           title: { "\(Int($0).formatted()) hours" },
                           detail: { "Train for \(Int($0).formatted()) hours in total" },
                           image: "stopwatch.fill", values: workouts.map { ($0.start, $0.durationMinutes / 60) })
        list += singleRunAchievements(workouts: workouts)
        list += stepAchievements(days: days)

        let first = days.keys.min() ?? calendar.startOfDay(for: snapshot.fetchedAt)
        let last = calendar.startOfDay(for: snapshot.fetchedAt)
        let toleranceMinutes = Int((XPRules.sleepOnTargetToleranceHours * 60).rounded())
        list += streak("sleep", [7, 30, 100],
                       title: { "Well rested ×\($0)" },
                       detail: { "\($0) nights in a row within \(toleranceMinutes) min of your \(hours(profile.sleepTargetHours)) target" },
                       image: "moon.zzz.fill", units: dates(from: first, through: last, step: .day, calendar: calendar)) {
            (days[$0]?.sleepHours ?? 0) >= profile.sleepTargetHours - XPRules.sleepOnTargetToleranceHours
        }
        let firstWeek = activeWeeks.min() ?? calendar.startOfWeek(for: first)
        list += streak("weeks", [4, 12, 26, 52, 104],
                       title: { "\($0)-week streak" },
                       detail: { "\($0) weeks in a row with \(activeWeekDays)+ training days" },
                       image: "flame.fill", units: dates(from: firstWeek, through: last, step: .weekOfYear, calendar: calendar)) { activeWeeks.contains($0) }
        return list
    }

    /// Unlocks on the date the running total first reaches each target.
    private static func cumulative(
        _ id: String, _ targets: [Double], title: (Double) -> String, detail: (Double) -> String, image: String, values: [(Date, Double)]
    ) -> [Achievement] {
        var total = 0.0
        var reached: [Double: Date] = [:]
        for (date, value) in values.sorted(by: { $0.0 < $1.0 }) {
            total += value
            for target in targets where reached[target] == nil && total >= target { reached[target] = date }
        }
        return targets.map { target in
            Achievement(id: "\(id)\(Int(target))", title: title(target), detail: detail(target), systemImage: image, target: target, current: total, unlockedAt: reached[target])
        }
    }

    /// Unlocks when a run of consecutive qualifying units first reaches each target.
    private static func streak(
        _ id: String, _ targets: [Int], title: (Int) -> String, detail: (Int) -> String, image: String, units: [Date], qualifies: (Date) -> Bool
    ) -> [Achievement] {
        var run = 0, best = 0
        var reached: [Int: Date] = [:]
        for unit in units {
            run = qualifies(unit) ? run + 1 : 0
            best = max(best, run)
            for target in targets where reached[target] == nil && run >= target { reached[target] = unit }
        }
        return targets.map { target in
            Achievement(id: "\(id)\(target)", title: title(target), detail: detail(target), systemImage: image, target: Double(target), current: Double(best), unlockedAt: reached[target])
        }
    }

    /// Single-run distances: 5K up to a marathon.
    private static func singleRunAchievements(workouts: [WorkoutSummary]) -> [Achievement] {
        let runs = workouts.filter { $0.sport == Sport.running }.sorted { $0.start < $1.start }
        let longestRun = runs.compactMap(\.distanceKm).max() ?? 0
        return singleRunMilestones.map { km, name in
            let first = runs.first { ($0.distanceKm ?? 0) >= km * distanceTolerance }
            return Achievement(id: "run\(Int(km))", title: name, detail: "Run \(number(km, digits: km < 20 ? 0 : 1)) km in one go", systemImage: "figure.run", target: km, current: longestRun, unlockedAt: first?.start)
        }
    }

    /// Steps in a day.
    private static func stepAchievements(days: [Date: Day]) -> [Achievement] {
        let stepDays = days.values.filter { $0.steps != nil }.sorted { $0.date < $1.date }
        let maxSteps = stepDays.compactMap(\.steps).max() ?? 0
        return [10_000.0, 20_000, 30_000].map { target in
            Achievement(id: "steps\(Int(target))", title: "\(Int(target / 1000))k day", detail: "Walk \(Int(target).formatted()) steps in a day", systemImage: "shoeprints.fill", target: target, current: maxSteps, unlockedAt: stepDays.first { ($0.steps ?? 0) >= target }?.date)
        }
    }

    /// Every `step` from `first` through `last`.
    private static func dates(from first: Date, through last: Date, step: Calendar.Component, calendar: Calendar) -> [Date] {
        var dates: [Date] = []
        var cursor = first
        while cursor <= last {
            dates.append(cursor)
            // A calendar that can't add a step would loop forever, so end the list instead.
            guard let next = calendar.date(byAdding: step, value: 1, to: cursor) else { break }
            cursor = next
        }
        return dates
    }
}
