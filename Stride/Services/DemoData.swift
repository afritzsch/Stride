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
