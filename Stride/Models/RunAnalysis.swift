import Foundation
import FoundationModels

@Generable
nonisolated enum EffortLevel: String, Codable, CaseIterable, Sendable {
    case recovery, easy, moderate, hard, maximal
}

/// Coach feedback on a single workout.
@Generable
nonisolated struct RunAnalysis: Codable, Hashable, Sendable {
    @Guide(description: "One-sentence verdict on the session")
    var headline: String
    @Guide(description: "How hard the session actually was, judged from heart rate and pace")
    var effort: EffortLevel
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
