import Foundation

/// Bucket size for progress charts and period comparisons.
nonisolated enum ProgressGranularity: String, CaseIterable, Identifiable, Sendable {
    case week, month, year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "Weeks"
        case .month: "Months"
        case .year: "Years"
        }
    }

    var currentTitle: String {
        switch self {
        case .week: "This week"
        case .month: "This month"
        case .year: "This year"
        }
    }

    var previousTitle: String {
        switch self {
        case .week: "last week"
        case .month: "last month"
        case .year: "last year"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// How many buckets the chart shows.
    var chartCount: Int {
        switch self {
        case .week: 26
        case .month: 24
        case .year: 10
        }
    }
}

/// Every number the progress screen can chart. Sums add up over a period; averages average the days that have a value.
nonisolated enum ProgressMetric: String, CaseIterable, Identifiable, Sendable {
    case xp, distance, trainingTime, sessions, load, runDistance, steps, activeEnergy, sleep, restingHR, hrv, weight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xp: "XP earned"
        case .distance: "Distance"
        case .trainingTime: "Training time"
        case .sessions: "Workouts"
        case .load: "Training load"
        case .runDistance: "Running distance"
        case .steps: "Steps per day"
        case .activeEnergy: "Active energy per day"
        case .sleep: "Sleep per night"
        case .restingHR: "Resting HR"
        case .hrv: "HRV"
        case .weight: "Weight"
        }
    }

    var unit: String {
        switch self {
        case .xp: "XP"
        case .distance, .runDistance: "km"
        case .trainingTime: "h"
        case .sessions: ""
        case .load: "TRIMP"
        case .steps: "steps"
        case .activeEnergy: "kcal"
        case .sleep: "h"
        case .restingHR: "bpm"
        case .hrv: "ms"
        case .weight: "kg"
        }
    }

    var digits: Int {
        switch self {
        case .trainingTime, .sleep, .weight, .distance, .runDistance: 1
        default: 0
        }
    }

    var systemImage: String {
        switch self {
        case .xp: "star.fill"
        case .distance: "map.fill"
        case .trainingTime: "stopwatch.fill"
        case .sessions: "figure.mixed.cardio"
        case .load: "flame.fill"
        case .runDistance: "figure.run"
        case .steps: "shoeprints.fill"
        case .activeEnergy: "bolt.heart.fill"
        case .sleep: "bed.double.fill"
        case .restingHR: "heart.fill"
        case .hrv: "waveform.path.ecg"
        case .weight: "scalemass.fill"
        }
    }

    /// Sums grow with the period's length, so they're compared over the same elapsed time.
    var isSum: Bool {
        switch self {
        case .xp, .distance, .trainingTime, .sessions, .load, .runDistance: true
        case .steps, .activeEnergy, .sleep, .restingHR, .hrv, .weight: false
        }
    }

    /// nil when neither direction is better (weight depends on the goal).
    var higherIsBetter: Bool? {
        switch self {
        case .restingHR: false
        case .weight: nil
        default: true
        }
    }
}
