import Foundation
import FoundationModels

/// Checks a generated 7-day plan against the rules the prompt states, so the app doesn't depend on the model
/// (especially the small on-device one) following them.
nonisolated enum PlanCheck {
    /// Up to 5% over the weekly hours is rounding, not a broken rule.
    static let hoursTolerance = 1.05

    /// Fixes what needs no judgment: day labels (by position) and the fields of rest days.
    static func normalized(_ plan: [PlannedDay], labels: [String]) -> [PlannedDay] {
        plan.enumerated().map { index, day in
            var day = day
            if plan.count == labels.count { day.day = labels[index] }
            if day.isRest {
                day.sport = PlannedDay.rest
                day.durationMinutes = 0
                day.targetZone = 0
            }
            day.targetZone = min(max(day.targetZone, 0), 5)
            return day
        }
    }

    /// Broken rules, phrased as instructions for the model. Empty when the plan is fine.
    static func problems(_ plan: [PlannedDay], labels: [String], profile: UserProfile) -> [String] {
        guard plan.count == labels.count else {
            return ["The plan has \(plan.count) days but needs exactly \(labels.count): \(labels.joined(separator: ", "))."]
        }
        var problems: [String] = []
        for day in plan where !day.isRest {
            if day.durationMinutes <= 0 {
                problems.append("\(day.day) is planned as \(day.intensity.rawValue) but has 0 minutes: give it a duration or make it a rest day.")
            }
            if day.sport == PlannedDay.rest {
                problems.append("\(day.day) has sport Rest but intensity \(day.intensity.rawValue): make it a rest day or pick a sport.")
            }
        }
        let trainingDays = plan.filter { !$0.isRest }
        if trainingDays.count > profile.trainingDaysPerWeek {
            problems.append("The plan has \(trainingDays.count) training days but the athlete trains at most \(profile.trainingDaysPerWeek) days a week: turn \(trainingDays.count - profile.trainingDaysPerWeek) of them into rest days.")
        }
        let minutes = plan.map(\.durationMinutes).reduce(0, +)
        let available = Int(profile.weeklyHoursAvailable * 60)
        if Double(minutes) > Double(available) * hoursTolerance {
            problems.append("The plan adds up to \(minutes) min but the athlete has \(available) min a week: cut \(minutes - available) min, starting with easy sessions.")
        }
        for (today, tomorrow) in zip(plan, plan.dropFirst()) where today.intensity == .hard && tomorrow.intensity == .hard {
            problems.append("\(today.day) and \(tomorrow.day) are both hard: put an easy or rest day between hard sessions.")
        }
        return problems
    }
}

/// Just the 7-day plan, for asking the model to fix one that broke the rules.
@Generable
nonisolated struct WeekPlan: Codable, Hashable, Sendable {
    @Guide(description: "The corrected plan, one entry per day, in order", .count(7))
    var days: [PlannedDay]
}

/// A short follow-up that hands the model its own plan and the broken rules. Small enough for the on-device model.
nonisolated enum PlanRepair {
    static let instructions = """
        You are an endurance coach correcting a 7-day training plan you wrote. Fix every listed problem with the \
        smallest change, keep the rest of the plan as it is, and keep the labels exactly as given. Rest days have \
        sport Rest, intensity rest, 0 minutes and zone 0.
        """

    /// Normalizes the plan, then gives the model one chance to fix the problems left. Keeps the fix only when it has
    /// fewer problems. Returns the problems that remain. `pinned` days (by position) are the athlete's own and are
    /// put back as they are, whatever the model wrote for them.
    static func run(
        _ report: inout AnalysisReport,
        labels: [String],
        profile: UserProfile,
        pinned: [Int: PlannedDay] = [:],
        log: (String) -> Void = { _ in },
        generate: (_ instructions: String, _ prompt: String) async throws -> WeekPlan
    ) async -> [String] {
        func normalized(_ plan: [PlannedDay]) -> [PlannedDay] {
            var plan = plan
            if plan.count == labels.count {
                for (index, day) in pinned where plan.indices.contains(index) { plan[index] = day }
            }
            return PlanCheck.normalized(plan, labels: labels)
        }
        report.weekPlan = normalized(report.weekPlan)
        let problems = PlanCheck.problems(report.weekPlan, labels: labels, profile: profile)
        guard !problems.isEmpty else { return [] }
        log("Plan check: \(problems.joined(separator: " "))")
        let prompt = prompt(
            plan: report.weekPlan, problems: problems, profile: profile, reasoning: "\(report.headline) \(report.assessment)",
            pinnedLabels: pinned.keys.sorted().compactMap { labels.indices.contains($0) ? labels[$0] : nil }
        )
        do {
            let plan = normalized(try await generate(instructions, prompt).days)
            let remaining = PlanCheck.problems(plan, labels: labels, profile: profile)
            log("Plan repair: \(problems.count) → \(remaining.count) problems")
            // A plan with the wrong number of days reports just that one problem, so it never counts as better.
            if plan.count == labels.count, remaining.count < problems.count {
                report.weekPlan = plan
                return remaining
            }
        } catch {
            log("Plan repair failed: \(error)")
        }
        return problems
    }

    static func prompt(plan: [PlannedDay], problems: [String], profile: UserProfile, reasoning: String, pinnedLabels: [String] = []) -> String {
        var lines = [
            "ATHLETE: \(profile.trainingDaysPerWeek) training days and \(PromptBuilder.num(profile.weeklyHoursAvailable, 1)) h a week at most.",
            "WHY THE PLAN LOOKS LIKE THIS: \(reasoning)",
            "",
            "PLAN (day | sport | intensity | session | min | zone | details)",
        ]
        lines += plan.map { "\($0.day) | \($0.sport) | \($0.intensity.rawValue) | \($0.session) | \($0.durationMinutes) | \($0.targetZone) | \($0.details)" }
        lines.append("")
        lines.append("PROBLEMS")
        lines += problems.map { "- \($0)" }
        if !pinnedLabels.isEmpty {
            lines.append("")
            lines.append("The athlete planned \(pinnedLabels.joined(separator: ", ")) themselves: keep these days exactly and fix the others.")
        }
        lines.append("")
        lines.append("Return the full corrected 7-day plan.")
        return lines.joined(separator: "\n")
    }
}
