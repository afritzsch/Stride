import Foundation
import FoundationModels

// The report is both @Generable (guided generation with the on-device model) and Codable
// (decoded from Claude's structured JSON output), so both engines produce the same type.

@Generable
nonisolated enum TrainingStatus: String, Codable, CaseIterable, Sendable {
    case productive, maintaining, overreaching, recovering, detraining, insufficientData

    var title: String {
        switch self {
        case .productive: "Productive"
        case .maintaining: "Maintaining"
        case .overreaching: "Overreaching"
        case .recovering: "Recovering"
        case .detraining: "Detraining"
        case .insufficientData: "Not enough data"
        }
    }
}

@Generable
nonisolated enum InsightArea: String, Codable, CaseIterable, Sendable {
    case training, sleep, activity, goal

    var focusArea: FocusArea { FocusArea(rawValue: rawValue) ?? .training }
}

@Generable
nonisolated enum InsightTone: String, Codable, CaseIterable, Sendable {
    case positive, neutral, warning
}

@Generable
nonisolated enum Priority: String, Codable, CaseIterable, Sendable {
    case high, medium, low

    var rank: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .low: 2
        }
    }
}

@Generable
nonisolated enum SessionIntensity: String, Codable, CaseIterable, Sendable {
    case rest, easy, moderate, hard
}

@Generable
nonisolated struct Insight: Codable, Hashable, Sendable {
    var area: InsightArea
    var tone: InsightTone
    @Guide(description: "Short title, max 6 words")
    var title: String
    @Guide(description: "One or two sentences that cite the specific numbers behind the insight")
    var detail: String
}

@Generable
nonisolated struct Recommendation: Codable, Hashable, Sendable {
    var area: InsightArea
    var priority: Priority
    @Guide(description: "A concrete action: what to do, when, and how much")
    var action: String
    @Guide(description: "Why, referring to the athlete's data")
    var rationale: String
}

@Generable
nonisolated struct PlannedDay: Codable, Hashable, Sendable {
    @Guide(description: "Day label exactly as given in the prompt, e.g. 'Mon 27 Oct'")
    var day: String
    var intensity: SessionIntensity
    @Guide(description: "Session title, e.g. 'Easy run' or 'Rest'")
    var session: String
    @Guide(description: "Planned duration in minutes, 0 for rest days")
    var durationMinutes: Int
    @Guide(description: "Specific details: structure, target heart rate or pace, sleep or recovery cue")
    var details: String
}

@Generable
nonisolated struct AnalysisReport: Codable, Hashable, Sendable {
    @Guide(description: "One-sentence headline with the single most important finding")
    var headline: String
    var trainingStatus: TrainingStatus
    @Guide(description: "Overall assessment in 2-4 sentences")
    var assessment: String
    @Guide(description: "Key observations across training, sleep and activity", .count(3...6))
    var insights: [Insight]
    @Guide(description: "Prioritized changes the athlete should make", .count(3...5))
    var recommendations: [Recommendation]
    @Guide(description: "Outlook toward the goal event, or an empty string if there is no goal")
    var goalOutlook: String
    @Guide(description: "Plan for the next 7 days, one entry per day, in order", .count(7))
    var weekPlan: [PlannedDay]
}

/// A result type both engines can produce: Claude via `output_config.format`, Apple via guided generation.
nonisolated protocol StructuredOutput: Generable, Decodable, Sendable {
    /// JSON Schema mirroring the Codable shape, for Claude's structured output.
    static var jsonSchema: [String: Any] { get }
}

nonisolated enum JSONSchema {
    static var string: [String: Any] { ["type": "string"] }
    static var integer: [String: Any] { ["type": "integer"] }

    static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object",
         "properties": properties,
         "required": Array(properties.keys).sorted(),
         "additionalProperties": false]
    }

    static func array(_ items: [String: Any]) -> [String: Any] {
        ["type": "array", "items": items]
    }

    static func enumeration<E: RawRepresentable & CaseIterable>(_: E.Type) -> [String: Any] where E.RawValue == String {
        ["type": "string", "enum": E.allCases.map(\.rawValue)]
    }
}

extension AnalysisReport: StructuredOutput {
    nonisolated static var jsonSchema: [String: Any] {
        typealias S = JSONSchema
        return S.object([
            "headline": S.string,
            "trainingStatus": S.enumeration(TrainingStatus.self),
            "assessment": S.string,
            "insights": S.array(S.object([
                "area": S.enumeration(InsightArea.self),
                "tone": S.enumeration(InsightTone.self),
                "title": S.string,
                "detail": S.string,
            ])),
            "recommendations": S.array(S.object([
                "area": S.enumeration(InsightArea.self),
                "priority": S.enumeration(Priority.self),
                "action": S.string,
                "rationale": S.string,
            ])),
            "goalOutlook": S.string,
            "weekPlan": S.array(S.object([
                "day": S.string,
                "intensity": S.enumeration(SessionIntensity.self),
                "session": S.string,
                "durationMinutes": S.integer,
                "details": S.string,
            ])),
        ])
    }
}

nonisolated enum AIEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    // Raw value kept from when this engine was on-device only, so saved settings still decode.
    case apple = "onDevice"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .apple: "Apple Intelligence"
        }
    }
}

nonisolated struct SavedAnalysis: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var createdAt: Date
    var engine: AIEngine
    /// The model that actually ran, e.g. "Apple Private Cloud Compute". nil for analyses saved before this existed.
    var modelName: String?
    var planStartDate: Date
    var report: AnalysisReport

    var sourceTitle: String { modelName ?? engine.title }
}
