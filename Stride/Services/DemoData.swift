import Foundation

/// Plausible synthetic wearable data so the app can be tried in the Simulator or without a watch.
nonisolated enum DemoData {
    static func snapshot(days: Int = 56, calendar: Calendar = .current) -> HealthSnapshot {
        var rng = SeededGenerator(seed: 42)
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
                hrvMs: (ramp ? 48 : 62) + Double.random(in: -6...6, using: &rng)
            ))

            let bedtimeMinutes = (ramp ? 23 * 60 + 40 : 22 * 60 + 50) + Int.random(in: -40...50, using: &rng)
            let asleep = (ramp ? 6.3 : 7.4) + Double.random(in: -0.6...0.6, using: &rng)
            if let previousDay = calendar.date(byAdding: .day, value: -1, to: day),
               let bedtime = calendar.date(byAdding: .minute, value: bedtimeMinutes, to: previousDay) {
                sleep.append(SleepNight(
                    date: day,
                    bedtime: bedtime,
                    wakeTime: bedtime.addingTimeInterval((asleep + 0.4) * 3600),
                    asleepHours: asleep,
                    deepHours: asleep * 0.17,
                    remHours: asleep * 0.22,
                    awakeHours: 0.4
                ))
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
               let start = calendar.date(byAdding: .hour, value: 18, to: day) {
                let duration = minutes + Double.random(in: -5...8, using: &rng)
                workouts.append(WorkoutSummary(
                    id: UUID(),
                    start: start,
                    durationMinutes: duration,
                    sport: sport,
                    distanceKm: kmPerMinute > 0 ? duration * kmPerMinute : nil,
                    activeEnergyKcal: duration * 11,
                    averageHeartRate: heartRate + Double.random(in: -4...4, using: &rng),
                    maxHeartRate: heartRate + 18,
                    sourceName: "Demo"
                ))
            }
        }

        return HealthSnapshot(fetchedAt: now, days: dailyMetrics, sleep: sleep, workouts: workouts, isDemo: true)
    }
}

nonisolated extension DemoData {
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
