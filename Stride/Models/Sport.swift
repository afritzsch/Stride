import Foundation

/// Sport names as `WorkoutSummary.sport` carries them (HealthKit activity names, see `HealthKitService`).
nonisolated enum Sport {
    static let running = "Running"
    static let cycling = "Cycling"
    static let swimming = "Swimming"
    static let walking = "Walking"
    static let hiking = "Hiking"
    static let strength = "Strength"
    static let other = "Other"
}

/// Which coach reviews a workout. Heart-rate zones and pace say how hard endurance work was; they say little
/// about lifting, where heart rate stays low and the watch records no sets, reps or weights.
nonisolated enum WorkoutKind: Sendable {
    case endurance, strength
}

nonisolated extension WorkoutSummary {
    static let footSports: Set<String> = [Sport.running, Sport.walking, Sport.hiking]
    /// Sports reviewed by the strength coach. Not the same set as the Strength skill's XP sports (`ProgressReport.strengthXPSports`).
    static let strengthSports: Set<String> = [Sport.strength, "Core", "Climbing", "Pilates", "Yoga", "Mobility"]

    var isFootSport: Bool { Self.footSports.contains(sport) }
    var kind: WorkoutKind { Self.strengthSports.contains(sport) ? .strength : .endurance }

    /// Average pace over moving time (HealthKit's workout duration excludes pauses).
    var paceSecondsPerKm: Double? {
        guard let km = distanceKm, km > 0 else { return nil }
        return durationMinutes * 60 / km
    }
}

nonisolated enum WorkoutFormat {
    /// "5:12" for seconds per km.
    static func pace(_ secondsPerKm: Double?) -> String {
        guard let secondsPerKm, secondsPerKm.isFinite, secondsPerKm > 0 else { return "–" }
        let total = Int(secondsPerKm.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// "47:12" or "1:47:12".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", secs))"
            : "\(minutes):\(String(format: "%02d", secs))"
    }
}
