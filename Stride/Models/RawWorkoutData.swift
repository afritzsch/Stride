import Foundation

nonisolated struct TimedValue: Hashable, Sendable {
    var date: Date
    var value: Double
}

/// A HealthKit quantity sample reduced to plain values, so workout processing can run on HealthKit data,
/// demo data, or an exported fixture alike.
nonisolated struct RawSample: Codable, Hashable, Sendable {
    var start: Date
    var end: Date
    var value: Double
    var source: String
}

/// One GPS fix from a workout route.
nonisolated struct RoutePoint: Codable, Hashable, Sendable {
    var date: Date
    var latitude: Double
    var longitude: Double
    var altitudeM: Double?
    /// Horizontal accuracy radius in meters.
    var accuracyM: Double?

    static let earthRadiusM = 6_371_000.0

    /// Great-circle distance in meters (haversine).
    func distance(to other: RoutePoint) -> Double {
        let radians = Double.pi / 180
        let dLat = (other.latitude - latitude) * radians, dLon = (other.longitude - longitude) * radians
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(latitude * radians) * cos(other.latitude * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * Self.earthRadiusM * asin(min(1, sqrt(a)))
    }
}

/// Everything read from HealthKit for one workout, before any processing.
nonisolated struct RawWorkoutData: Codable, Sendable {
    var workoutID: UUID
    var start: Date
    var end: Date
    var source: String
    /// bpm, every source, overlapping the workout.
    var heartRate: [RawSample]
    /// Meters of walking/running distance, every source, overlapping the workout.
    var distance: [RawSample]
    var steps: [RawSample]
    var elevationGainM: Double?
    var temperatureC: Double?
    var humidityPercent: Double?
    var isIndoor: Bool?
    var powerW: Double?
    var cyclingCadence: Double?
    var strideLengthM: Double?
    var verticalOscillationCm: Double?
    var groundContactMs: Double?
    /// GPS fixes; nil in fixtures exported before routes were read.
    var route: [RoutePoint]?
}

/// A full export of what the app reads, for replaying someone's real data in the Simulator.
nonisolated struct HealthFixture: Codable, Sendable {
    var exportedAt: Date
    var snapshot: HealthSnapshot
    var workouts: [RawWorkoutData]
}
