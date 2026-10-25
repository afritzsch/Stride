import Foundation

/// One calendar day of aggregated metrics read from Apple Health.
nonisolated struct DailyMetrics: Codable, Hashable, Identifiable, Sendable {
    /// Start of the local calendar day.
    var date: Date
    var steps: Double?
    var activeEnergyKcal: Double?
    var restingHeartRate: Double?
    var hrvMs: Double?

    var id: Date { date }
}

/// One night of sleep, keyed by the day the athlete woke up.
nonisolated struct SleepNight: Codable, Hashable, Identifiable, Sendable {
    var date: Date
    var bedtime: Date
    var wakeTime: Date
    var asleepHours: Double
    var deepHours: Double?
    var remHours: Double?
    var awakeHours: Double?

    var id: Date { date }
}

nonisolated struct WorkoutSummary: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var start: Date
    var durationMinutes: Double
    var sport: String
    var distanceKm: Double?
    var activeEnergyKcal: Double?
    var averageHeartRate: Double?
    var maxHeartRate: Double?
    var sourceName: String
}

nonisolated struct HealthSnapshot: Codable, Sendable {
    var fetchedAt: Date
    /// Ascending by date, one entry per day in the window (values may be nil).
    var days: [DailyMetrics]
    /// Ascending by date.
    var sleep: [SleepNight]
    /// Ascending by start.
    var workouts: [WorkoutSummary]
    var isDemo: Bool

    var isEmpty: Bool {
        workouts.isEmpty && sleep.isEmpty && days.allSatisfy { $0.steps == nil && $0.restingHeartRate == nil }
    }
}
