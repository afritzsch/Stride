import SwiftUI

extension Color {
    /// Heart-rate zone colors, Z1 (index 0) to Z5; the accent color for nil (no reading).
    static func heartRateZone(_ index: Int?) -> Color {
        guard let index else { return .accentColor }
        return [.gray, .blue, .green, .orange, .red][min(max(index, 0), 4)]
    }
}

extension EffortLevel {
    var color: Color {
        switch self {
        case .recovery: .gray
        case .easy: .green
        case .moderate: .blue
        case .hard: .orange
        case .maximal: .red
        }
    }
}

extension TrainingStatus {
    var color: Color {
        switch self {
        case .productive: .green
        case .maintaining: .blue
        case .overreaching: .red
        case .recovering: .teal
        case .detraining: .orange
        case .insufficientData: .gray
        }
    }
}

extension InsightTone {
    var color: Color {
        switch self {
        case .positive: .green
        case .neutral: .blue
        case .warning: .orange
        }
    }

    var systemImage: String {
        switch self {
        case .positive: "checkmark.circle.fill"
        case .neutral: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }
}

extension Priority {
    var color: Color {
        switch self {
        case .high: .red
        case .medium: .orange
        case .low: .secondary
        }
    }
}

extension SessionIntensity {
    var color: Color {
        switch self {
        case .rest: .gray
        case .easy: .green
        case .moderate: .orange
        case .hard: .red
        }
    }
}

extension Skill {
    var color: Color {
        switch self {
        case .endurance: .blue
        case .power: .red
        case .strength: .purple
        case .explorer: .green
        case .vitality: .mint
        case .rest: .indigo
        case .discipline: .orange
        }
    }
}

extension ProgressMetric {
    var color: Color {
        switch self {
        case .xp: .orange
        case .distance, .runDistance: .green
        case .trainingTime, .sessions: .blue
        case .load: .orange
        case .steps: .mint
        case .activeEnergy: .yellow
        case .sleep: .indigo
        case .restingHR: .red
        case .hrv: .pink
        case .weight: .teal
        }
    }

    func format(_ value: Double?) -> String {
        guard let value else { return "–" }
        switch self {
        case .trainingTime, .sleep: return Format.hours(value)
        case .sessions: return Format.number(value)
        default: return "\(Format.number(value, digits: digits)) \(unit)"
        }
    }
}

extension ProgressGranularity {
    var axisFormat: Date.FormatStyle {
        switch self {
        case .week: .dateTime.day().month(.abbreviated)
        case .month: .dateTime.month(.abbreviated).year(.twoDigits)
        case .year: .dateTime.year()
        }
    }
}

extension Readiness.Level {
    var color: Color {
        switch self {
        case .unknown: .gray
        case .good: .green
        case .caution: .yellow
        case .low: .orange
        }
    }
}

extension PlanAdherence.Status {
    var color: Color {
        switch self {
        case .done, .rested: .green
        case .modified: .orange
        case .missed: .red
        case .extra: .purple
        case .pending: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .rested: "moon.zzz.fill"
        case .modified: "arrow.triangle.swap"
        case .missed: "xmark.circle.fill"
        case .extra: "plus.circle.fill"
        case .pending: "clock"
        }
    }
}
