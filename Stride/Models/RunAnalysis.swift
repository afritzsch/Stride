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
    @Guide(description: "A short verdict of at most 12 words, e.g. \"Strong half marathon at threshold effort\"")
    var headline: String
    @Guide(description: "Short bullet points interpreting the session, each under 15 words: what kind of run it was, how pacing and heart rate behaved, what it means for training. The athlete already sees the stats, so don't list them", .count(2...4))
    var summary: [String]
    @Guide(description: "One sentence on how the session compared to what was planned for that day, or an empty string if nothing was planned")
    var planComparison: String
    @Guide(description: "What the athlete did well, each a short bullet point about their running", .count(1...3))
    var highlights: [String]
    @Guide(description: "Specific changes to pacing, training, fueling or recovery, each a short bullet point. Never about the watch or how data is recorded", .count(1...3))
    var improvements: [String]
    @Guide(description: "1-2 sentences of recovery advice for the next 24-48 hours")
    var recovery: String
    @Guide(description: "1-2 sentences: what the next session should be and why")
    var nextSession: String
}

extension RunAnalysis: StructuredOutput {
    nonisolated static var jsonSchema: [String: Any] {
        typealias S = JSONSchema
        return S.object([
            "headline": S.string,
            "effort": S.enumeration(EffortLevel.self),
            "summary": S.array(S.string),
            "planComparison": S.string,
            "highlights": S.array(S.string),
            "improvements": S.array(S.string),
            "recovery": S.string,
            "nextSession": S.string,
        ])
    }
}

extension RunAnalysis {
    private enum CodingKeys: String, CodingKey {
        case effort, headline, summary, planComparison, highlights, improvements, recovery, nextSession
    }

    // Reviews saved before the summary became bullet points stored it as one string.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        effort = try container.decode(EffortLevel.self, forKey: .effort)
        headline = try container.decode(String.self, forKey: .headline)
        if let points = try? container.decode([String].self, forKey: .summary) {
            summary = points
        } else {
            summary = [try container.decode(String.self, forKey: .summary)]
        }
        planComparison = try container.decode(String.self, forKey: .planComparison)
        highlights = try container.decode([String].self, forKey: .highlights)
        improvements = try container.decode([String].self, forKey: .improvements)
        recovery = try container.decode(String.self, forKey: .recovery)
        nextSession = try container.decode(String.self, forKey: .nextSession)
    }
}

nonisolated struct SavedRunAnalysis: Codable, Hashable, Sendable {
    var workoutID: UUID
    var createdAt: Date
    var modelName: String
    var note: String
    var analysis: RunAnalysis
}
