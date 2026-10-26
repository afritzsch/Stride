import Foundation

/// Plausible synthetic wearable data so the app can be tried in the Simulator or without a watch.
nonisolated enum DemoData {
    static func snapshot(days: Int = HealthKitService.windowWeeks * 7, calendar: Calendar = .current) -> HealthSnapshot {
        var rng = SeededGenerator(seed: 42)
        // Separate stream so adding weight didn't change the rest of the demo data.
        var weightRng = SeededGenerator(seed: 7)
        let now = Date()
        let today = calendar.startOfDay(for: now)

        var dailyMetrics: [DailyMetrics] = []
        var sleep: [SleepNight] = []
        var workouts: [WorkoutSummary] = []

        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            // The last ~10 days ramp up load while sleep slips: something the analysis should catch.
            let ramp = offset < 10
            let weekday = calendar.component(.weekday, from: day) // 1 = Sunday

            dailyMetrics.append(DailyMetrics(
                date: day,
                steps: offset == 0 ? 4200 : Double.random(in: 5500...13500, using: &rng),
                activeEnergyKcal: Double.random(in: 350...900, using: &rng),
                restingHeartRate: (ramp ? 55 : 51) + Double.random(in: -2...2, using: &rng),
                hrvMs: (ramp ? 48 : 62) + Double.random(in: -6...6, using: &rng),
                // Weighs in most mornings, drifting down ~1 kg over the window.
                bodyMassKg: Double.random(in: 0...1, using: &weightRng) < 0.6
                    ? 72.5 - Double(days - 1 - offset) / Double(days) + Double.random(in: -0.4...0.4, using: &weightRng)
                    : nil
            ))

            let bedtimeMinutes = (ramp ? 23 * 60 + 40 : 22 * 60 + 50) + Int.random(in: -40...50, using: &rng)
            let asleep = (ramp ? 6.3 : 7.4) + Double.random(in: -0.6...0.6, using: &rng)
            if let night = sleepNight(on: day, bedtimeMinutes: bedtimeMinutes, asleep: asleep, calendar: calendar) {
                sleep.append(night)
            }

            // (sport, minutes, avg HR, km per minute)
            let plan: (String, Double, Double, Double)? = switch weekday {
            case 3: ("Running", 50, 162, 0.19)        // Tue intervals
            case 5: ("Running", 45, 155, 0.18)        // Thu tempo
            case 7: ("Running", ramp ? 110 : 85, 146, 0.165) // Sat long run
            case 1: ("Cycling", 60, 128, 0.45)        // Sun easy ride
            case 2: ("Strength", 40, 112, 0)          // Mon gym
            case 4 where ramp: ("Running", 40, 150, 0.17)
            default: nil
            }
            if let (sport, minutes, heartRate, kmPerMinute) = plan, offset > 0,
               let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) {
                workouts.append(workout(start: start, sport: sport, minutes: minutes, heartRate: heartRate, kmPerMinute: kmPerMinute, rng: &rng))
            }
        }

        return HealthSnapshot(fetchedAt: now, days: dailyMetrics, sleep: sleep, workouts: workouts, isDemo: true)
    }
}

nonisolated extension DemoData {
    /// Older history before `start` (the demo snapshot's first day) for the progress screen: two years of
    /// training that slowly gets fitter, with a summer break and a half marathon, so levels and records have a story.
    static func archive(before start: Date, years: Int = 2, calendar: Calendar = .current) -> HealthSnapshot {
        var rng = SeededGenerator(seed: 2024)
        let first = calendar.date(byAdding: .year, value: -years, to: start) ?? start
        let totalDays = max(calendar.dateComponents([.day], from: first, to: start).day ?? 0, 1)

        var dailyMetrics: [DailyMetrics] = []
        var sleep: [SleepNight] = []
        var workouts: [WorkoutSummary] = []

        for offset in 0..<totalDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { continue }
            // 0 at the start of the archive, 1 where the regular demo snapshot takes over.
            let fitness = Double(offset) / Double(totalDays)
            let weekday = calendar.component(.weekday, from: day)
            let daysLeft = totalDays - offset
            // Three weeks off in the first summer.
            let isBreak = (200..<221).contains(offset)

            dailyMetrics.append(DailyMetrics(
                date: day,
                steps: Double.random(in: 4500...11500, using: &rng) + fitness * 1500,
                activeEnergyKcal: Double.random(in: 300...800, using: &rng),
                restingHeartRate: 58 - 7 * fitness + Double.random(in: -2...2, using: &rng),
                hrvMs: 50 + 12 * fitness + Double.random(in: -6...6, using: &rng),
                bodyMassKg: Double.random(in: 0...1, using: &rng) < 0.5
                    ? 77 - 4.5 * fitness + Double.random(in: -0.4...0.4, using: &rng)
                    : nil
            ))

            let asleep = 6.9 + 0.5 * fitness + Double.random(in: -0.7...0.7, using: &rng)
            let bedtimeMinutes = 23 * 60 + Int.random(in: -50...50, using: &rng)
            if let night = sleepNight(on: day, bedtimeMinutes: bedtimeMinutes, asleep: asleep, calendar: calendar) {
                sleep.append(night)
            }

            guard !isBreak else { continue }
            let pace = 0.15 + 0.03 * fitness // km per minute
            // (sport, minutes, avg HR, km per minute); more sessions as fitness grows.
            let plan: (String, Double, Double, Double)? = switch weekday {
            case 3: ("Running", 35 + 15 * fitness, 158, pace + 0.01)
            case 5 where fitness > 0.3: ("Running", 40, 152, pace)
            case 7 where (148..<155).contains(daysLeft): ("Running", 21.2 / (pace + 0.005), 165, pace + 0.005) // half marathon race
            case 7: ("Running", 50 + 35 * fitness, 145, pace - 0.01)
            case 1 where fitness > 0.15: ("Cycling", 45 + 15 * fitness, 126, 0.42)
            case 2 where fitness > 0.5: ("Strength", 35, 110, 0)
            default: nil
            }
            // Skip about one session in eight, like real life.
            guard let (sport, minutes, heartRate, kmPerMinute) = plan, Double.random(in: 0...1, using: &rng) > 0.12,
                  let workoutStart = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) else { continue }
            workouts.append(workout(start: workoutStart, sport: sport, minutes: minutes, heartRate: heartRate, kmPerMinute: kmPerMinute, rng: &rng))
        }
        return HealthSnapshot(fetchedAt: start, days: dailyMetrics, sleep: sleep, workouts: workouts, isDemo: true)
    }

    /// The night ending on `day`, going to bed `bedtimeMinutes` after the previous midnight.
    private static func sleepNight(on day: Date, bedtimeMinutes: Int, asleep: Double, calendar: Calendar) -> SleepNight? {
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: day),
              let bedtime = calendar.date(byAdding: .minute, value: bedtimeMinutes, to: previousDay) else { return nil }
        return SleepNight(
            date: day,
            bedtime: bedtime,
            wakeTime: bedtime.addingTimeInterval((asleep + 0.4) * 3600),
            asleepHours: asleep,
            deepHours: asleep * 0.17,
            remHours: asleep * 0.22,
            awakeHours: 0.4
        )
    }

    /// A workout of about `minutes` (randomized like the heart rate) at a steady speed.
    private static func workout(
        start: Date, sport: String, minutes: Double, heartRate: Double, kmPerMinute: Double, rng: inout SeededGenerator
    ) -> WorkoutSummary {
        let duration = minutes + Double.random(in: -5...8, using: &rng)
        return WorkoutSummary(
            // Derived from the start so saved coach reviews still match after a relaunch.
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", UInt64(start.timeIntervalSince1970)))!,
            start: start,
            durationMinutes: duration,
            sport: sport,
            distanceKm: kmPerMinute > 0 ? duration * kmPerMinute : nil,
            activeEnergyKcal: duration * 11,
            averageHeartRate: heartRate + Double.random(in: -4...4, using: &rng),
            maxHeartRate: heartRate + 18,
            sourceName: "Demo"
        )
    }

    static func detail(for workout: WorkoutSummary) -> WorkoutDetail {
        WorkoutDetail.build(summary: workout, raw: rawWorkout(for: workout))
    }

    /// Fine-grained synthetic samples matching a demo workout's summary, like a watch that shares everything.
    static func rawWorkout(for workout: WorkoutSummary) -> RawWorkoutData {
        var rng = SeededGenerator(seed: UInt64(max(0, workout.start.timeIntervalSince1970)))
        let total = workout.durationMinutes * 60
        let end = workout.start.addingTimeInterval(total)
        let source = workout.sourceName
        let averageHR = workout.averageHeartRate ?? 130
        // Interval-style sessions (high average HR, short) get work/recovery blocks.
        let isIntervals = workout.isFootSport && averageHR >= 158 && workout.durationMinutes < 70

        var heartRate: [RawSample] = []
        var elapsed = 0.0
        while elapsed <= total {
            let warmUp = min(elapsed / 420, 1)
            let drift = elapsed / total * 6 - 3
            var value = averageHR - 22 + 22 * warmUp + drift
            if isIntervals, elapsed > 900, elapsed < total - 600 {
                value += Int((elapsed - 900) / 180).isMultiple(of: 2) ? 10 : -12
            }
            let date = workout.start.addingTimeInterval(elapsed)
            heartRate.append(RawSample(start: date, end: date, value: value + Double.random(in: -3...3, using: &rng), source: source))
            elapsed += 15
        }

        var distance: [RawSample] = []
        var steps: [RawSample] = []
        if workout.isFootSport, let km = workout.distanceKm, km > 0 {
            let metersPerMinute = km * 1000 / workout.durationMinutes
            for minute in 0..<Int(workout.durationMinutes) {
                let start = workout.start.addingTimeInterval(Double(minute) * 60)
                let fade = 1 - Double(minute) / workout.durationMinutes * 0.05
                distance.append(RawSample(
                    start: start,
                    end: start.addingTimeInterval(60),
                    value: metersPerMinute * fade * Double.random(in: 0.94...1.06, using: &rng),
                    source: source
                ))
                steps.append(RawSample(start: start, end: start.addingTimeInterval(60), value: Double.random(in: 166...178, using: &rng), source: source))
            }
            // Scale so the samples add up to the summary's distance exactly.
            let scale = km * 1000 / max(distance.map(\.value).reduce(0, +), 1)
            distance = distance.map { RawSample(start: $0.start, end: $0.end, value: $0.value * scale, source: $0.source) }
        }

        let isRun = workout.sport == "Running"
        let hasRoute = workout.isFootSport || workout.sport == "Cycling"
        return RawWorkoutData(
            workoutID: workout.id,
            start: workout.start,
            end: end,
            source: source,
            heartRate: heartRate,
            distance: distance,
            steps: steps,
            elevationGainM: workout.isFootSport ? Double.random(in: 25...140, using: &rng).rounded() : nil,
            temperatureC: 11,
            humidityPercent: 72,
            isIndoor: workout.sport == "Strength",
            powerW: isRun ? Double.random(in: 240...290, using: &rng) : nil,
            cyclingCadence: workout.sport == "Cycling" ? 86 : nil,
            route: hasRoute ? route(for: workout, distance: distance, rng: &rng) : []
        )
    }

    /// GPS fixes every 5 s on a loop in Berlin's Tiergarten, following the distance samples so
    /// splits computed from the route match the ones from distance.
    private static func route(for workout: WorkoutSummary, distance: [RawSample], rng: inout SeededGenerator) -> [RoutePoint] {
        guard let km = workout.distanceKm, km > 0 else { return [] }
        let total = workout.durationMinutes * 60
        func metersCovered(after elapsed: Double) -> Double {
            guard !distance.isEmpty else { return km * 1000 * elapsed / total }
            let date = workout.start.addingTimeInterval(elapsed)
            return distance.map { sample in
                let length = sample.end.timeIntervalSince(sample.start)
                let share = min(max(date.timeIntervalSince(sample.start) / length, 0), 1)
                return sample.value * share
            }.reduce(0, +)
        }
        // Whole laps of at most 5 km, so the run ends where it started.
        let lap = km * 1000 / (km / 5).rounded(.up)
        let radius = lap / (2 * .pi)
        let center = (latitude: 52.5145, longitude: 13.3501)
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(center.latitude * .pi / 180)
        return stride(from: 0.0, through: total, by: 5).map { elapsed in
            let angle = metersCovered(after: elapsed) / radius
            let north = radius * sin(angle) + Double.random(in: -1...1, using: &rng)
            let east = radius * (1 - cos(angle)) + Double.random(in: -1...1, using: &rng)
            return RoutePoint(
                date: workout.start.addingTimeInterval(elapsed),
                latitude: center.latitude + north / metersPerDegreeLatitude,
                longitude: center.longitude + east / metersPerDegreeLongitude,
                altitudeM: 35 + 4 * sin(angle * 2),
                accuracyM: 4
            )
        }
    }
}

/// SplitMix64, so demo data is stable between launches.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
