import Foundation
import FoundationModels

@Generable
nonisolated enum EffortLevel: String, Codable, CaseIterable, Sendable {
    case recovery, easy, moderate, hard, maximal
}

extension EffortLevel {
    /// Effort judged from time in the athlete's own heart-rate zones (Z1…Z5), so the label doesn't depend on
    /// the model reading the numbers right. Nil when heart rate covers too little of the session to tell.
    nonisolated static func measured(zoneSeconds: [Double], durationMinutes: Double) -> EffortLevel? {
        let total = zoneSeconds.reduce(0, +)
        guard zoneSeconds.count == 5, total >= max(600, durationMinutes * 60 * 0.5) else { return nil }
        let share = zoneSeconds.map { $0 / total }
        let z5 = share[4], z45 = share[3] + share[4], z345 = share[2] + z45
        if z5 >= 0.3 || z45 >= 0.8 { return .maximal }
        if z5 >= 0.1 || z45 >= 0.25 || (z345 >= 0.6 && durationMinutes >= 120) { return .hard }
        if z345 >= 0.4 { return .moderate }
        if share[0] >= 0.6 && z345 < 0.1 && durationMinutes <= 60 { return .recovery }
        return .easy
    }
}

/// Coach feedback on a single workout.
@Generable
nonisolated struct RunAnalysis: Codable, Hashable, Sendable {
    // Generated first so the headline follows from it; overwritten by `EffortLevel.measured` when HR allows.
    @Guide(description: "How hard the session actually was; use the measured effort from the brief when given")
    var effort: EffortLevel
    @Guide(description: "One-sentence verdict on the session")
    var headline: String
    @Guide(description: "2-4 sentences on how the session went, citing splits, pace and heart rate")
    var summary: String
    @Guide(description: "How the session compared to what was planned for that day, or an empty string if nothing was planned")
    var planComparison: String
    @Guide(description: "What went well, each citing data", .count(1...4))
    var highlights: [String]
    @Guide(description: "Concrete things to do differently next time", .count(1...4))
    var improvements: [String]
    @Guide(description: "Recovery advice for the next 24-48 hours: sleep, fueling, easy movement")
    var recovery: String
    @Guide(description: "What the next session should be and why")
    var nextSession: String
}

extension RunAnalysis: StructuredOutput {
    nonisolated static var jsonSchema: [String: Any] {
        typealias S = JSONSchema
        return S.object([
            "headline": S.string,
            "effort": S.enumeration(EffortLevel.self),
            "summary": S.string,
            "planComparison": S.string,
            "highlights": S.array(S.string),
            "improvements": S.array(S.string),
            "recovery": S.string,
            "nextSession": S.string,
        ])
    }
}

nonisolated struct SavedRunAnalysis: Codable, Hashable, Sendable {
    var workoutID: UUID
    var createdAt: Date
    var modelName: String
    var note: String
    var analysis: RunAnalysis
}
