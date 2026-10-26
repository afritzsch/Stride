import Foundation
import FoundationModels

/// Morning check of today's recovery signals against the athlete's own baselines.
nonisolated struct Readiness: Sendable {
    enum Level: Int, Comparable, Sendable {
        case unknown, good, caution, low

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .unknown: "Not enough data"
            case .good: "Ready to train"
            case .caution: "Train with care"
            case .low: "Take it easy"
            }
        }
    }

    struct Signal: Hashable, Sendable {
        /// Strong signals alone mean "take it easy"; mild ones only together.
        var isStrong: Bool
        var text: String
    }

    var level: Level
    /// Fatigue signals, strongest first. Empty when everything is within range.
    var signals: [Signal]
    /// What was checked and looked fine, for context.
    var fine: [String]

    init(snapshot: HealthSnapshot, metrics: MetricsReport, profile: UserProfile, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: snapshot.fetchedAt)
        let ind = metrics.indicators
        let day = snapshot.days.first { $0.date == today }
        var signals: [Signal] = []
        var fine: [String] = []
        let num = PromptBuilder.num

        if let resting = day?.restingHeartRate, let baseline = ind.restingHR28 {
            // Rounded, so the classification matches the whole number shown.
            let delta = (resting - baseline).rounded()
            if delta >= 5 {
                signals.append(Signal(isStrong: true, text: "Resting HR \(num(resting, 0)) bpm, \(num(delta, 0)) above your 4-week average"))
            } else if delta >= 3 {
                signals.append(Signal(isStrong: false, text: "Resting HR \(num(resting, 0)) bpm, \(num(delta, 0)) above your 4-week average"))
            } else {
                fine.append("resting HR \(num(resting, 0)) bpm")
            }
        }
        if let hrv = day?.hrvMs, let baseline = ind.hrv28, baseline > 0 {
            // Whole percent, so the classification matches the number shown.
            let ratio = 1 - ((1 - hrv / baseline) * 100).rounded() / 100
            if ratio <= 0.8 {
                signals.append(Signal(isStrong: true, text: "HRV \(num(hrv, 0)) ms, \(Int(((1 - ratio) * 100).rounded()))% below your 4-week average"))
            } else if ratio <= 0.9 {
                signals.append(Signal(isStrong: false, text: "HRV \(num(hrv, 0)) ms, \(Int(((1 - ratio) * 100).rounded()))% below your 4-week average"))
            } else {
                fine.append("HRV \(num(hrv, 0)) ms")
            }
        }
        if let night = snapshot.sleep.first(where: { $0.date == today }) {
            let short = profile.sleepTargetHours - night.asleepHours
            if night.asleepHours < 6 || short >= 1.5 {
                signals.append(Signal(isStrong: true, text: "Slept \(num(night.asleepHours, 1)) h last night (target \(num(profile.sleepTargetHours, 1)) h)"))
            } else if short >= 0.75 {
                signals.append(Signal(isStrong: false, text: "Slept \(num(night.asleepHours, 1)) h last night (target \(num(profile.sleepTargetHours, 1)) h)"))
            } else {
                fine.append("\(num(night.asleepHours, 1)) h sleep")
            }
        }
        if let acwr = ind.acwr {
            if acwr > 1.5 {
                signals.append(Signal(isStrong: true, text: "Training load ratio \(num(acwr, 2)): this week is well above your usual"))
            } else if acwr > 1.3 {
                signals.append(Signal(isStrong: false, text: "Training load ratio \(num(acwr, 2)): this week is above your usual"))
            } else {
                fine.append("load ratio \(num(acwr, 2))")
            }
        }
        if ind.consecutiveTrainingDays >= 5 {
            signals.append(Signal(isStrong: false, text: "\(ind.consecutiveTrainingDays) training days in a row"))
        }

        self.signals = signals.sorted { $0.isStrong && !$1.isStrong }
        self.fine = fine
        if signals.isEmpty {
            level = fine.isEmpty ? .unknown : .good
        } else if signals.contains(where: \.isStrong) || signals.count >= 2 {
            level = .low
        } else {
            level = .caution
        }
    }

    /// Worth suggesting a lighter version of a planned session.
    var suggestsAdjusting: Bool { level >= .caution }
}

/// A lighter version of today's planned session, written by the model when readiness is low.
@Generable
nonisolated struct DayAdjustment: Codable, Hashable, Sendable {
    @Guide(description: "One or two sentences to the athlete: which signals matter today and how the session changes")
    var reason: String
    @Guide(description: "Today's adjusted session")
    var session: PlannedDay
}

nonisolated extension DayAdjustment {
    static let instructions = """
        You are an endurance coach adjusting today's planned session to the athlete's recovery this morning.

        Rules:
        - Only make the session easier: lower the intensity, shorten it, or make it a rest day. Never make it \
        harder or longer.
        - With one mild signal, keep the session but cap the intensity at easy (zone 2). With strong or several \
        signals, shorten it a lot or rest.
        - Keep the same sport unless you make it a rest day. Rest days have sport Rest, intensity rest, 0 minutes \
        and zone 0.
        - Use the day label exactly as given. Address the athlete as "you". Be brief and concrete.
        """

    static func prompt(planned: PlannedDay, readiness: Readiness, metrics: MetricsReport, profile: UserProfile) -> String {
        var lines = [
            "ATHLETE: \(profile.primarySport), \(profile.experience.rawValue)",
            "HR ZONES: \(metrics.heartRateZones.summary)",
            "",
            "PLANNED TODAY (\(planned.day)): \(planned.briefDescription). \(planned.details)",
            "",
            "THIS MORNING",
        ]
        lines += readiness.signals.map { "- \($0.isStrong ? "Strong" : "Mild") signal: \($0.text)" }
        if !readiness.fine.isEmpty { lines.append("- Within normal range: \(readiness.fine.joined(separator: ", "))") }
        lines.append("")
        lines.append("Adjust today's session (\(planned.day)).")
        return lines.joined(separator: "\n")
    }

    /// Enforces "never harder or longer" and the rest-day fields, whatever the model wrote.
    func clamped(to planned: PlannedDay) -> DayAdjustment {
        var session = self.session
        session.day = planned.day
        let rank: [SessionIntensity: Int] = [.rest: 0, .easy: 1, .moderate: 2, .hard: 3]
        if (rank[session.intensity] ?? 0) > (rank[planned.intensity] ?? 0) { session.intensity = planned.intensity }
        session.durationMinutes = min(session.durationMinutes, planned.durationMinutes)
        if planned.targetZone > 0, session.targetZone > planned.targetZone { session.targetZone = planned.targetZone }
        if session.intensity == .rest || session.durationMinutes == 0 {
            session.intensity = .rest
            session.sport = PlannedDay.rest
            session.durationMinutes = 0
            session.targetZone = 0
        } else if session.sport == PlannedDay.rest {
            session.sport = planned.sport
        }
        return DayAdjustment(reason: reason, session: session)
    }
}

/// A suggested change to today's session and what the athlete did with it.
nonisolated struct SavedAdjustment: Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable { case suggested, accepted, declined }

    var date: Date
    var original: PlannedDay
    var adjustment: DayAdjustment
    var state = State.suggested
}
