import Foundation

extension SavedAnalysis {
    /// The plan entry for a date, by position from `planStartDate` (labels are checked when the plan is saved).
    nonisolated func plannedDay(on date: Date, calendar: Calendar = .current) -> PlannedDay? {
        let start = calendar.startOfDay(for: planStartDate)
        guard let offset = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day,
              report.weekPlan.indices.contains(offset) else { return nil }
        return report.weekPlan[offset]
    }
}

extension Array where Element == SavedAnalysis {
    /// The session planned for a date by the newest analysis whose plan covers it (history is newest first).
    nonisolated func plannedDay(on date: Date, calendar: Calendar = .current) -> PlannedDay? {
        lazy.compactMap { $0.plannedDay(on: date, calendar: calendar) }.first
    }
}

/// How the planned days went, compared with the workouts that were actually recorded.
nonisolated struct PlanAdherence: Sendable {
    enum Status: String, Sendable {
        case done, modified, missed, extra, rested, pending

        var title: String {
            switch self {
            case .done: "Done"
            case .modified: "Changed"
            case .missed: "Missed"
            case .extra: "Trained on a rest day"
            case .rested: "Rested"
            case .pending: "Today"
            }
        }
    }

    struct Day: Identifiable, Sendable {
        var date: Date
        var planned: PlannedDay
        var workouts: [WorkoutSummary]
        var status: Status
        /// Deviations from the plan, e.g. "shorter: 30 of 50 min".
        var notes: [String]

        var id: Date { date }
    }

    /// Ascending by date; only days a saved plan covered.
    var days: [Day]

    /// Planned days from `days` back up to today. Today counts once something was recorded, otherwise it's pending.
    init(plan: TrainingPlan, workouts: [WorkoutSummary], zones: HeartRateZones, days: Int = 7, now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let workoutsByDay = Dictionary(grouping: workouts) { calendar.startOfDay(for: $0.start) }
        self.days = (0...days).reversed().compactMap { offset -> Day? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today),
                  let planned = plan.plannedDay(on: date, calendar: calendar) else { return nil }
            let done = workoutsByDay[date] ?? []
            if date == today, done.isEmpty {
                return Day(date: date, planned: planned, workouts: [], status: .pending, notes: [])
            }
            let (status, notes) = Self.compare(planned: planned, done: done, zones: zones)
            return Day(date: date, planned: planned, workouts: done, status: status, notes: notes)
        }
    }

    /// Days that are over (or done today).
    var completed: [Day] { days.filter { $0.status != .pending } }

    /// "3 of 4 planned sessions done, 1 changed" for completed days.
    static func summary(of completed: [Day]) -> String {
        let sessions = completed.filter { !$0.planned.isRest }
        let doneStatuses: Set<Status> = [.done, .modified]
        let done = sessions.filter { doneStatuses.contains($0.status) }.count
        var parts = ["\(done) of \(sessions.count) planned sessions done"]
        let changed = completed.filter { $0.status == .modified }.count
        if changed > 0 { parts.append("\(changed) changed") }
        let extra = completed.filter { $0.status == .extra }.count
        if extra > 0 { parts.append("\(extra) extra on rest days") }
        return parts.joined(separator: ", ")
    }

    static func compare(planned: PlannedDay, done: [WorkoutSummary], zones: HeartRateZones) -> (Status, [String]) {
        if planned.isRest {
            return done.isEmpty ? (.rested, []) : (.extra, [])
        }
        guard !done.isEmpty else { return (.missed, []) }

        var notes: [String] = []
        let knownSport = !planned.sport.isEmpty && planned.sport != "Other" && planned.sport != PlannedDay.rest
        let matching = knownSport ? done.filter { $0.sport == planned.sport } : done
        if matching.isEmpty {
            notes.append("\(Self.sports(done)) instead of \(planned.sport)")
        }
        let measured = matching.isEmpty ? done : matching

        let minutes = measured.map(\.durationMinutes).reduce(0, +)
        if planned.durationMinutes > 0 {
            let ratio = minutes / Double(planned.durationMinutes)
            if ratio < 0.7 { notes.append("shorter: \(Int(minutes.rounded())) of \(planned.durationMinutes) min") }
            if ratio > 1.3 { notes.append("longer: \(Int(minutes.rounded())) of \(planned.durationMinutes) min") }
        }

        // Average HR of the longest session, as a zone (1-5). Averages hide intervals, so only clear
        // mismatches count: an easy day run hard, or a hard day run easy.
        if let main = measured.max(by: { $0.durationMinutes < $1.durationMinutes }), let heartRate = main.averageHeartRate {
            let zone = zones.index(for: heartRate) + 1
            let easyTarget = planned.targetZone > 0 ? planned.targetZone <= 2 : planned.intensity == .easy
            if easyTarget, zone >= 4 {
                notes.append("harder: avg HR \(Int(heartRate.rounded())) (Z\(zone))\(planned.targetZone > 0 ? ", planned Z\(planned.targetZone)" : "")")
            } else if planned.intensity == .hard, zone <= 2 {
                notes.append("easier: avg HR \(Int(heartRate.rounded())) (Z\(zone))")
            }
        }
        return (notes.isEmpty ? .done : .modified, notes)
    }

    static func sports(_ workouts: [WorkoutSummary]) -> String {
        var seen: [String] = []
        for workout in workouts where !seen.contains(workout.sport) { seen.append(workout.sport) }
        return seen.joined(separator: " + ")
    }
}

extension PlannedDay {
    /// "Easy run (Running, easy, 45 min, Z2)" for prompts.
    nonisolated var briefDescription: String {
        guard !isRest else { return PlannedDay.rest }
        var parts: [String] = []
        if !sport.isEmpty { parts.append(sport) }
        parts.append(intensity.rawValue)
        parts.append("\(durationMinutes) min")
        if targetZone > 0 { parts.append("Z\(targetZone)") }
        return "\(session) (\(parts.joined(separator: ", ")))"
    }
}
