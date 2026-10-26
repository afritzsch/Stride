import Foundation

nonisolated enum IntensityZone: String, Sendable {
    case easy, moderate, hard, unknown
}

nonisolated struct WeeklySummary: Identifiable, Hashable, Sendable {
    var weekStart: Date
    var sessions = 0
    var trainingMinutes = 0.0
    var load = 0.0
    var distanceKm = 0.0
    var hardSessions = 0
    var avgSleepHours: Double?
    var avgSteps: Double?
    var avgRestingHR: Double?
    var avgHRV: Double?
    var avgWeightKg: Double?

    var id: Date { weekStart }
}

/// One value per day, for charts.
nonisolated struct DatedValue: Identifiable, Hashable, Sendable {
    var date: Date
    var value: Double

    var id: Date { date }
}

nonisolated struct TrainingIndicators: Sendable {
    /// Sum of TRIMP over the last 7 days.
    var acuteLoad = 0.0
    /// Average weekly TRIMP over the last 28 days.
    var chronicLoad = 0.0
    /// Acute:chronic workload ratio. ~0.8–1.3 is the usual "sweet spot".
    var acwr: Double?
    /// Foster monotony (mean / SD of daily load, last 7 days). > 2 means little day-to-day variation.
    var monotony: Double?
    var consecutiveTrainingDays = 0
    var restingHRBaseline = 60.0

    var sleep7: Double?
    var sleep28: Double?
    /// Standard deviation of bedtime over the last 14 nights, in minutes.
    var bedtimeSDMinutes: Double?
    var restingHR7: Double?
    var restingHR28: Double?
    var hrv7: Double?
    var hrv28: Double?
    var steps7: Double?
    var steps28: Double?
    /// Most recent weigh-in in the window.
    var latestWeightKg: Double?
    var latestWeightDate: Date?
    var weight7: Double?
    var weight28: Double?

    /// Training minutes per zone over the last 28 days.
    var zoneMinutes28: [IntensityZone: Double] = [:]
}

/// Derived training metrics. Load uses Banister's TRIMP from average workout heart rate.
nonisolated struct MetricsReport: Sendable {
    var weeks: [WeeklySummary]
    var dailyLoad: [Date: Double]
    var workoutLoad: [UUID: Double]
    /// Acute:chronic ratio as of each day that has 28 days of synced history behind it.
    var acwrHistory: [DatedValue]
    var indicators: TrainingIndicators
    var heartRateZones: HeartRateZones

    init(snapshot: HealthSnapshot, profile: UserProfile, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: snapshot.fetchedAt)
        let maxHR = profile.effectiveMaxHeartRate
        func since(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today }
        let start7 = since(7), start14 = since(14), start28 = since(28)

        let days7 = snapshot.days.filter { $0.date >= start7 }
        let days28 = snapshot.days.filter { $0.date >= start28 }
        var ind = TrainingIndicators()
        ind.restingHRBaseline = Self.median(days28.compactMap(\.restingHeartRate)) ?? 60
        let zones = profile.heartRateZones(restingHR: ind.restingHRBaseline)

        var workoutLoad: [UUID: Double] = [:]
        var workoutZone: [UUID: IntensityZone] = [:]
        var dailyLoad: [Date: Double] = [:]
        for workout in snapshot.workouts {
            let load = Self.trimp(workout, restingHR: ind.restingHRBaseline, maxHR: maxHR)
            workoutLoad[workout.id] = load
            workoutZone[workout.id] = Self.zone(workout, zones: zones)
            dailyLoad[calendar.startOfDay(for: workout.start), default: 0] += load
        }

        func loads(endingOn day: Date, days: Int) -> [Double] {
            (0..<days).map { offset in dailyLoad[calendar.date(byAdding: .day, value: -offset, to: day) ?? day] ?? 0 }
        }
        let last7Loads = loads(endingOn: today, days: 7)
        ind.acuteLoad = last7Loads.reduce(0, +)
        ind.chronicLoad = dailyLoad.filter { $0.key >= start28 }.values.reduce(0, +) / 4
        // With less than 28 days of synced data the chronic average is too low and the ratio reads as overload.
        let firstSynced = snapshot.days.first { $0.steps != nil || $0.restingHeartRate != nil }?.date
        let hasChronicHistory = firstSynced.map { $0 <= start28 } ?? false
        ind.acwr = hasChronicHistory && ind.chronicLoad > 0 ? ind.acuteLoad / ind.chronicLoad : nil
        acwrHistory = snapshot.days.compactMap { day in
            guard let firstSynced, let chronicStart = calendar.date(byAdding: .day, value: -27, to: day.date),
                  firstSynced <= chronicStart else { return nil }
            let chronic = loads(endingOn: day.date, days: 28).reduce(0, +) / 4
            guard chronic > 0 else { return nil }
            return DatedValue(date: day.date, value: loads(endingOn: day.date, days: 7).reduce(0, +) / chronic)
        }
        if let sd = Self.standardDeviation(last7Loads), sd > 0 {
            ind.monotony = (ind.acuteLoad / 7) / sd
        }

        // Count back from today; if today has no session yet, start from yesterday.
        var day = (dailyLoad[today] ?? 0) > 0 ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        while (dailyLoad[day] ?? 0) > 0 {
            ind.consecutiveTrainingDays += 1
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }

        ind.restingHR7 = Self.mean(days7.compactMap(\.restingHeartRate))
        ind.restingHR28 = Self.mean(days28.compactMap(\.restingHeartRate))
        ind.hrv7 = Self.mean(days7.compactMap(\.hrvMs))
        ind.hrv28 = Self.mean(days28.compactMap(\.hrvMs))
        ind.steps7 = Self.mean(days7.compactMap(\.steps))
        ind.steps28 = Self.mean(days28.compactMap(\.steps))
        if let latest = snapshot.days.last(where: { $0.bodyMassKg != nil }) {
            ind.latestWeightKg = latest.bodyMassKg
            ind.latestWeightDate = latest.date
        }
        ind.weight7 = Self.mean(days7.compactMap(\.bodyMassKg))
        ind.weight28 = Self.mean(days28.compactMap(\.bodyMassKg))
        ind.sleep7 = Self.mean(snapshot.sleep.filter { $0.date >= start7 }.map(\.asleepHours))
        ind.sleep28 = Self.mean(snapshot.sleep.filter { $0.date >= start28 }.map(\.asleepHours))
        ind.bedtimeSDMinutes = Self.standardDeviation(
            snapshot.sleep.filter { $0.date >= start14 }.map { Self.minutesAfterSixPM($0.bedtime, calendar: calendar) }
        )

        for workout in snapshot.workouts where workout.start >= start28 {
            ind.zoneMinutes28[workoutZone[workout.id] ?? .unknown, default: 0] += workout.durationMinutes
        }

        self.dailyLoad = dailyLoad
        self.workoutLoad = workoutLoad
        self.indicators = ind
        self.heartRateZones = zones
        self.weeks = Self.weeklySummaries(snapshot: snapshot, workoutLoad: workoutLoad, workoutZone: workoutZone, calendar: calendar)
    }

    // MARK: - Formulas

    static func trimp(_ workout: WorkoutSummary, restingHR: Double, maxHR: Double) -> Double {
        guard let avg = workout.averageHeartRate, maxHR > restingHR else {
            // No heart rate (e.g. strength without a strap): assume roughly moderate effort.
            return workout.durationMinutes * 0.7
        }
        let reserve = min(max((avg - restingHR) / (maxHR - restingHR), 0), 1)
        return workout.durationMinutes * reserve * 0.64 * exp(1.92 * reserve)
    }

    /// Easy = average HR in Z1–2, moderate = Z3, hard = Z4–5.
    static func zone(_ workout: WorkoutSummary, zones: HeartRateZones) -> IntensityZone {
        guard let avg = workout.averageHeartRate else { return .unknown }
        switch zones.index(for: avg) {
        case ...1: return .easy
        case 2: return .moderate
        default: return .hard
        }
    }

    private static func weeklySummaries(
        snapshot: HealthSnapshot,
        workoutLoad: [UUID: Double],
        workoutZone: [UUID: IntensityZone],
        calendar: Calendar
    ) -> [WeeklySummary] {
        // ISO weeks (Monday start) in the caller's time zone.
        var iso = calendar
        iso.firstWeekday = 2
        iso.minimumDaysInFirstWeek = 4
        func weekStart(_ date: Date) -> Date { iso.dateInterval(of: .weekOfYear, for: date)?.start ?? date }

        let daysByWeek = Dictionary(grouping: snapshot.days) { weekStart($0.date) }
        var weeks = Dictionary(uniqueKeysWithValues: daysByWeek.keys.map { ($0, WeeklySummary(weekStart: $0)) })
        for workout in snapshot.workouts {
            let key = weekStart(workout.start)
            var week = weeks[key] ?? WeeklySummary(weekStart: key)
            week.sessions += 1
            week.trainingMinutes += workout.durationMinutes
            week.load += workoutLoad[workout.id] ?? 0
            week.distanceKm += workout.distanceKm ?? 0
            if workoutZone[workout.id] == .hard { week.hardSessions += 1 }
            weeks[key] = week
        }
        let sleepByWeek = Dictionary(grouping: snapshot.sleep) { weekStart($0.date) }
        for key in weeks.keys {
            let days = daysByWeek[key] ?? []
            weeks[key]?.avgSteps = mean(days.compactMap(\.steps))
            weeks[key]?.avgRestingHR = mean(days.compactMap(\.restingHeartRate))
            weeks[key]?.avgHRV = mean(days.compactMap(\.hrvMs))
            weeks[key]?.avgWeightKg = mean(days.compactMap(\.bodyMassKg))
            weeks[key]?.avgSleepHours = mean((sleepByWeek[key] ?? []).map(\.asleepHours))
        }
        return weeks.values.sorted { $0.weekStart < $1.weekStart }
    }

    // MARK: - Statistics helpers

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Population SD (divides by n), as in Foster's monotony.
    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count >= 2, let avg = mean(values) else { return nil }
        let variance = values.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(values.count)
        return variance.squareRoot()
    }

    /// Maps clock time onto a scale that doesn't wrap at midnight for typical bedtimes.
    static func minutesAfterSixPM(_ date: Date, calendar: Calendar) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return Double((minutes - 18 * 60 + 24 * 60) % (24 * 60))
    }
}
