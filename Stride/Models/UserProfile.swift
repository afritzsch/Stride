import Foundation

nonisolated enum FocusArea: String, Codable, CaseIterable, Identifiable, Sendable {
    case training, sleep, activity, goal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .training: "Training plan"
        case .sleep: "Sleep & recovery"
        case .activity: "Daily activity"
        case .goal: "Race / goal prep"
        }
    }

    var systemImage: String {
        switch self {
        case .training: "figure.run"
        case .sleep: "bed.double.fill"
        case .activity: "shoeprints.fill"
        case .goal: "flag.checkered"
        }
    }
}

nonisolated enum ExperienceLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case beginner, intermediate, advanced

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Context the AI needs that the watch can't know: goals, availability, constraints.
nonisolated struct UserProfile: Codable, Equatable, Sendable {
    var primarySport = "Running"
    var experience = ExperienceLevel.intermediate
    var age: Int?
    /// Leave nil to estimate from age.
    var maxHeartRate: Int?
    var trainingDaysPerWeek = 4
    var weeklyHoursAvailable = 5.0

    var hasGoal = false
    var goalName = ""
    var goalDate = Calendar.current.date(byAdding: .day, value: 84, to: .now) ?? .now
    var goalTarget = ""

    var sleepTargetHours = 8.0
    var dailyStepTarget = 8000
    var notes = ""
    var focusAreas = Set(FocusArea.allCases)

    /// Tanaka formula when age is known, otherwise a conservative default.
    var effectiveMaxHeartRate: Double {
        if let maxHeartRate { return Double(maxHeartRate) }
        if let age { return 208 - 0.7 * Double(age) }
        return 190
    }

    var isMaxHeartRateEstimated: Bool { maxHeartRate == nil }
}
