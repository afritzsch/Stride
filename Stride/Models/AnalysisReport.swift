import Foundation
import FoundationModels

// The report is @Generable (guided generation with Apple's on-device model) and Codable (saved history).

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

    /// Ascending effort, for comparing two sessions.
    var rank: Int {
        switch self {
        case .rest: 0
        case .easy: 1
        case .moderate: 2
        case .hard: 3
        }
    }
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
    @Guide(description: "The sport, or Rest on a rest day", .anyOf(PlannedDay.sports))
    var sport: String
    var intensity: SessionIntensity
    @Guide(description: "Session title, e.g. 'Easy run' or 'Rest'")
    var session: String
    @Guide(description: "Planned duration in minutes, 0 for rest days")
    var durationMinutes: Int
    @Guide(description: "Heart-rate zone (1-5) for the main part of the session, 0 for rest or sessions without a heart-rate target", .range(0...5))
    var targetZone: Int
    @Guide(description: "Specific details: structure, target heart rate or pace, sleep or recovery cue")
    var details: String

    /// Names match `WorkoutSummary.sport` (HealthKit activity names), so plan and workouts can be compared.
    static let rest = "Rest"
    static let sports = [
        Sport.running, Sport.cycling, Sport.swimming, Sport.walking, Sport.hiking, Sport.strength, "Mobility", "Yoga", "Rowing", "HIIT",
        "Cross training", Sport.other, rest,
    ]

    var isRest: Bool { intensity == .rest }

    /// A real sport, as opposed to a rest day, "Other", or the empty sport of plans saved before `sport` existed.
    var hasKnownSport: Bool { !sport.isEmpty && sport != Sport.other && sport != Self.rest }
}

nonisolated extension PlannedDay {
    private enum CodingKeys: String, CodingKey {
        case day, sport, intensity, session, durationMinutes, targetZone, details
    }

    /// Plans saved before `sport` and `targetZone` existed decode with an unknown sport ("") and no zone.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(String.self, forKey: .day)
        intensity = try container.decode(SessionIntensity.self, forKey: .intensity)
        sport = try container.decode(.sport, default: intensity == .rest ? Self.rest : "")
        session = try container.decode(String.self, forKey: .session)
        durationMinutes = try container.decode(Int.self, forKey: .durationMinutes)
        targetZone = try container.decode(.targetZone, default: 0)
        details = try container.decode(String.self, forKey: .details)
    }
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

nonisolated struct SavedAnalysis: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var createdAt: Date
    /// The model that ran, e.g. "Apple on-device model".
    var modelName: String
    var planStartDate: Date
    var report: AnalysisReport
}

nonisolated extension SavedAnalysis {
    private enum LegacyKeys: String, CodingKey { case engine }

    /// Analyses saved before `modelName` existed only stored the engine ("claude" or "onDevice").
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        planStartDate = try container.decode(Date.self, forKey: .planStartDate)
        report = try container.decode(AnalysisReport.self, forKey: .report)
        if let name = try container.decodeIfPresent(String.self, forKey: .modelName) {
            modelName = name
        } else {
            let engine = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .engine)
            modelName = engine == "claude" ? "Claude" : "Apple Intelligence"
        }
    }
}
