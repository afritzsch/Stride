import Foundation

/// A day the athlete planned (or changed) themselves. It wins over the coach's plans for that date, and the weekly
/// analysis is told to keep it and plan the other days around it.
nonisolated struct AthletePlanDay: Codable, Hashable, Sendable {
    /// Start of the local day.
    var date: Date
    var day: PlannedDay
    var savedAt: Date
}

/// Everything planned: the coach's weekly plans and the athlete's own days on top of them.
nonisolated struct TrainingPlan: Sendable {
    /// Newest first.
    var analyses: [SavedAnalysis]
    var athleteDays: [AthletePlanDay] = []

    func athleteDay(on date: Date, calendar: Calendar = .current) -> AthletePlanDay? {
        athleteDays.first { calendar.isDate($0.date, inSameDayAs: date) }
    }

    /// The coach's session for a date, ignoring the athlete's changes.
    func coachDay(on date: Date, calendar: Calendar = .current) -> PlannedDay? {
        analyses.plannedDay(on: date, calendar: calendar)
    }

    func plannedDay(on date: Date, calendar: Calendar = .current) -> PlannedDay? {
        athleteDay(on: date, calendar: calendar)?.day ?? coachDay(on: date, calendar: calendar)
    }

    /// Plan positions (0 = `start`) of the days in a 7-day plan the athlete already fixed.
    func pinnedDays(start: Date, count: Int = 7, calendar: Calendar = .current) -> [Int: PlannedDay] {
        var pinned: [Int: PlannedDay] = [:]
        for offset in 0..<count {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start),
                  let day = athleteDay(on: date, calendar: calendar)?.day else { continue }
            pinned[offset] = day
        }
        return pinned
    }
}

nonisolated extension PlannedDay {
    /// "Easy run", "Hard ride", "Strength": a title for a day the athlete planned without naming it.
    var defaultTitle: String {
        guard !isRest else { return Self.rest }
        let nouns = ["Running": "run", "Cycling": "ride", "Swimming": "swim", "Walking": "walk", "Hiking": "hike", "Rowing": "row"]
        if let noun = nouns[sport] { return "\(intensity.rawValue.capitalized) \(noun)" }
        return sport.isEmpty || sport == "Other" ? "\(intensity.rawValue.capitalized) session" : sport
    }
}
