import Foundation

/// A race-time estimate computed in code, so the chat model only has to explain it (it can't do the arithmetic).
/// Current fitness comes from the best recent run via Riegel's formula; the projection adds a typical monthly
/// improvement for the athlete's experience, capped.
nonisolated struct RaceForecast: Sendable {
    static let distances: [(name: String, km: Double)] = [("5K", 5), ("10K", 10), ("Half marathon", 21.0975), ("Marathon", 42.195)]

    /// Riegel's fatigue exponent.
    static let riegelExponent = 1.06
    /// A run counts as "the race distance" within this share of it.
    static let sameDistanceTolerance = 0.05
    /// Only runs from this many days back, and at least this long, say anything about current fitness.
    static let lookbackDays = 56
    static let minRunKm = 3.0
    /// The projected improvement is capped at this share of the current time.
    static let maxGain = 0.08
    static let daysPerMonth = 30.4
    /// Below this many seconds between the fast and slow estimate, a single time is quoted.
    static let minRangeSeconds = 30.0

    var distanceName: String
    var distanceKm: Double
    var raceDate: Date
    var weeksAway: Int
    /// The run the estimate is based on, and its time converted to the race distance.
    var basis: WorkoutSummary
    var currentSeconds: Double
    /// A recent run of about the race distance, if there is one.
    var sameDistance: WorkoutSummary?
    var monthlyGain: Double
    var fastSeconds: Double
    var slowSeconds: Double

    /// Riegel: T2 = T1 · (D2 / D1)^1.06.
    static func equivalent(seconds: Double, km: Double, toKm target: Double) -> Double {
        seconds * pow(target / km, riegelExponent)
    }

    /// Within 5%, so a watch's 21.3 km counts as a half marathon.
    static func isSameDistance(_ km: Double?, _ target: Double) -> Bool {
        guard let km else { return false }
        return abs(km - target) / target <= sameDistanceTolerance
    }

    static func make(
        distanceKm: Double, raceDate: Date, workouts: [WorkoutSummary], experience: ExperienceLevel,
        now: Date = .now, calendar: Calendar = .current
    ) -> RaceForecast? {
        let since = calendar.date(byAdding: .day, value: -lookbackDays, to: now) ?? now
        let runs = workouts.filter { workout in
            let km: Double = workout.distanceKm ?? 0
            return workout.sport == Sport.running && workout.start >= since && km >= minRunKm && workout.durationMinutes > 0
        }
        // Extrapolating a short run to a much longer race is too optimistic, so prefer runs of at least half the distance.
        let long = runs.filter { ($0.distanceKm ?? 0) >= distanceKm / 2 }
        func equivalent(_ run: WorkoutSummary) -> Double {
            Self.equivalent(seconds: run.durationMinutes * 60, km: run.distanceKm ?? 1, toKm: distanceKm)
        }
        guard let basis = (long.isEmpty ? runs : long).min(by: { equivalent($0) < equivalent($1) }) else { return nil }
        let current = equivalent(basis)

        let days = max(0, calendar.dateComponents([.day], from: now, to: raceDate).day ?? 0)
        let monthlyGain = switch experience {
        case .beginner: 0.015
        case .intermediate: 0.01
        case .advanced: 0.005
        }
        let gain = min(monthlyGain * Double(days) / daysPerMonth, maxGain)
        let sameDistance = runs.filter { isSameDistance($0.distanceKm, distanceKm) }.max(by: { $0.start < $1.start })
        guard let name = distances.min(by: { abs($0.km - distanceKm) < abs($1.km - distanceKm) })?.name else { return nil }
        return RaceForecast(
            distanceName: name, distanceKm: distanceKm, raceDate: raceDate, weeksAway: days / 7,
            basis: basis, currentSeconds: current, sameDistance: sameDistance, monthlyGain: monthlyGain,
            fastSeconds: current * (1 - gain), slowSeconds: current
        )
    }

    var brief: String {
        let calendar = Calendar.current
        func run(_ workout: WorkoutSummary) -> String {
            "\(PromptBuilder.dayLabel(workout.start, calendar: calendar)), \(PromptBuilder.num(workout.distanceKm, 1)) km in \(WorkoutFormat.duration(workout.durationMinutes * 60)) (\(WorkoutFormat.pace(workout.paceSecondsPerKm)) /km)"
        }
        // "2:07 h" for long races; minutes and seconds for short ones.
        func time(_ seconds: Double) -> String {
            seconds >= 3600 ? "\(WorkoutFormat.duration((seconds / 60).rounded() * 60).dropLast(3)) h" : WorkoutFormat.duration(seconds)
        }
        let when = weeksAway == 0 ? "now" : "in \(raceDate.formatted(.dateTime.month(.wide).year())) (about \(weeksAway) weeks away)"
        var lines = ["RACE FORECAST, computed by the app: \(distanceName) \(when)"]
        if let sameDistance, sameDistance.id != basis.id { lines.append("- Recent run at this distance: \(run(sameDistance))") }
        let converted = Self.isSameDistance(basis.distanceKm, distanceKm) ? "" : ", converted with Riegel's formula"
        lines.append("- Current fitness: \(time(currentSeconds)), from \(run(basis))\(converted)")
        lines.append(fastSeconds < slowSeconds - Self.minRangeSeconds
            ? "- Projected race time: \(time(fastSeconds))–\(time(slowSeconds)). Fast end: consistent training (about \(PromptBuilder.num(monthlyGain * 100, 1))% faster a month, typical at this level); slow end: no gain."
            : "- Projected race time: about \(time(slowSeconds)).")
        lines.append("Training runs are rarely all-out, so a real race may be a little faster. Quote these times exactly; don't calculate other times.")
        return lines.joined(separator: "\n")
    }
}
