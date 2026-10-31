import Foundation
import FoundationModels

/// What the athlete's recent training, recovery, goal and calendar allow next week, so a plan can be checked
/// against the rules the weekly instructions state. Without it, only the athlete's settings are checked.
nonisolated struct PlanContext: Sendable {
    /// Training minutes in a usual recent week: the larger of the last complete week and the average of the last
    /// four complete weeks (so a recovery week doesn't set the bar). Nil without two complete weeks of history.
    var recentWeeklyMinutes: Double?
    /// The fatigue signals the weekly instructions name (load ratio, resting HR, HRV, sleep), empty when recovered.
    var fatigue: [String] = []
    /// Days from the first plan day to the goal (0 = the first plan day), nil without an upcoming goal.
    var daysToGoal: Int?
    var goalTitle = ""
    /// The longest free stretch in the calendar per plan day, in minutes; nil when time suggestions are off.
    var freeMinutes: [Int]?

    /// Below this, a usual week is too small to measure growth against (new athletes, a comeback).
    static let minRecentMinutes = 60.0
    /// Volume may grow about 10% a week, and at least this many minutes (10% of a short week is nothing).
    static let growthShare = 1.1
    static let minGrowthMinutes = 30
    /// The taper: the week before the goal and the week before that, as a share of the usual week.
    static let finalWeekShare = 0.6
    static let taperWeekShare = 0.8

    init(recentWeeklyMinutes: Double? = nil, fatigue: [String] = [], daysToGoal: Int? = nil, goalTitle: String = "", freeMinutes: [Int]? = nil) {
        self.recentWeeklyMinutes = recentWeeklyMinutes
        self.fatigue = fatigue
        self.daysToGoal = daysToGoal
        self.goalTitle = goalTitle
        self.freeMinutes = freeMinutes
    }

    init(metrics: MetricsReport, profile: UserProfile, planStart: Date, freeMinutes: [Int]? = nil, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: planStart)
        let complete = metrics.weeks.filter { week in
            (calendar.date(byAdding: .day, value: 7, to: week.weekStart) ?? week.weekStart) <= start
        }.suffix(4)
        if complete.count >= 2, let last = complete.last {
            let average = complete.map(\.trainingMinutes).reduce(0, +) / Double(complete.count)
            let usual = max(last.trainingMinutes, average)
            recentWeeklyMinutes = usual
        }

        fatigue = metrics.indicators.fatigueSignals

        if profile.hasGoal, let days = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: profile.goalDate)).day, days >= 0 {
            daysToGoal = days
            goalTitle = PromptBuilder.goalTitle(profile)
        }
        self.freeMinutes = freeMinutes
    }

    /// The plan position of the goal day, when it falls in the plan.
    func goalIndex(days: Int) -> Int? {
        daysToGoal.flatMap { $0 < days ? $0 : nil }
    }
}

/// Checks a generated 7-day plan against the rules the prompt states, so the app doesn't depend on the model
/// (especially the small on-device one) following them.
nonisolated enum PlanCheck {
    /// Up to 5% over a minutes limit is rounding, not a broken rule.
    static let hoursTolerance = 1.05
    /// Shortening sessions never takes one below this.
    static let shortestSession = 20

    /// A cap on the week's training minutes and the rule behind it.
    struct MinuteLimit: Equatable, Sendable {
        var minutes: Int
        /// Completes "The plan adds up to N min but …", e.g. "the athlete has 300 min a week".
        var reason: String
    }

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
            day.targetZone = min(max(day.targetZone, 0), HeartRateZones.zoneCount)
            return day
        }
    }

    /// The caps on next week's training minutes: the athlete's hours, and with a context the taper before a goal,
    /// no growth while recovery is down, or else about 10% growth. The goal day itself doesn't count.
    static func minuteLimits(profile: UserProfile, context: PlanContext?) -> [MinuteLimit] {
        let available = Int(profile.weeklyHoursAvailable * 60)
        var limits = [MinuteLimit(minutes: available, reason: "the athlete has \(available) min a week")]
        guard let context, let recent = context.recentWeeklyMinutes, recent >= PlanContext.minRecentMinutes else { return limits }
        let usual = Int(recent.rounded())
        if let days = context.daysToGoal, days < 14 {
            let share = days < 7 ? PlanContext.finalWeekShare : PlanContext.taperWeekShare
            limits.append(MinuteLimit(
                minutes: Int(recent * share),
                reason: "the \(context.goalTitle) is \(days + 1) days after the plan starts, so the week should taper to about \(Int(share * 100))% of the usual \(usual) min"
            ))
        } else if !context.fatigue.isEmpty {
            limits.append(MinuteLimit(
                minutes: usual,
                reason: "recovery is down (\(context.fatigue.joined(separator: ", "))), so the week shouldn't grow past the usual \(usual) min"
            ))
        } else {
            limits.append(MinuteLimit(
                minutes: max(Int(recent * PlanContext.growthShare), usual + PlanContext.minGrowthMinutes),
                reason: "the usual week is \(usual) min and volume should grow by about 10% at most"
            ))
        }
        return limits
    }

    /// Broken rules, phrased as instructions for the model. Empty when the plan is fine. `pinned` positions are the
    /// athlete's own days: free time in the calendar is their call there.
    static func problems(_ plan: [PlannedDay], labels: [String], profile: UserProfile, context: PlanContext? = nil, pinned: Set<Int> = []) -> [String] {
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
        let minutes = trainingMinutes(plan, context: context)
        let broken = minuteLimits(profile: profile, context: context)
            .filter { Double(minutes) > Double($0.minutes) * hoursTolerance }
            .min { $0.minutes < $1.minutes }
        if let broken {
            problems.append("The plan adds up to \(minutes) min but \(broken.reason): cut \(minutes - broken.minutes) min, starting with easy sessions.")
        }
        for (today, tomorrow) in zip(plan, plan.dropFirst()) where today.intensity == .hard && tomorrow.intensity == .hard {
            problems.append("\(today.day) and \(tomorrow.day) are both hard: put an easy or rest day between hard sessions.")
        }
        if let goal = context?.goalIndex(days: plan.count), goal > 0, plan[goal - 1].intensity == .hard {
            problems.append("\(plan[goal - 1].day) is hard the day before the \(context?.goalTitle ?? "goal"): make it easy or a rest day.")
        }
        if let free = context?.freeMinutes, free.count == plan.count {
            for (index, day) in plan.enumerated() where !day.isRest && !pinned.contains(index) && day.durationMinutes > free[index] {
                problems.append("\(day.day) has a \(day.durationMinutes)-min session but the athlete has only \(free[index]) min free in a row that day: move it to a day with more free time or shorten it.")
            }
        }
        return problems
    }

    /// Fixes in code the broken rules that need no judgment, never touching `pinned` days (the athlete's own):
    /// sessions without minutes become rest days, extra training days become rest (easiest and shortest first),
    /// too many minutes are cut from easy sessions first, and a hard day after a hard day (or before the goal)
    /// becomes easy. Returns the plan and one line per change. What's left (e.g. free time) needs the model.
    static func autoFix(_ plan: [PlannedDay], profile: UserProfile, context: PlanContext? = nil, pinned: Set<Int> = []) -> (plan: [PlannedDay], changes: [String]) {
        var plan = plan
        var changes: [String] = []
        let free = plan.indices.filter { !pinned.contains($0) }

        func rest(_ index: Int, because reason: String) {
            let label = plan[index].day
            plan[index] = PlannedDay(day: label, sport: PlannedDay.rest, intensity: .rest, session: PlannedDay.rest, durationMinutes: 0, targetZone: 0, details: "")
            changes.append("\(label): rest day (\(reason))")
        }
        func ease(_ index: Int, because reason: String) {
            var day = plan[index]
            day.intensity = .easy
            if day.targetZone > 2 { day.targetZone = 2 }
            day.session = day.defaultTitle
            day.details = "Keep it easy\(day.targetZone > 0 ? ", zone \(day.targetZone) at most" : ""): \(reason)."
            plan[index] = day
            changes.append("\(day.day): easy instead of hard (\(reason))")
        }

        for index in free where !plan[index].isRest && (plan[index].durationMinutes <= 0 || plan[index].sport == PlannedDay.rest) {
            rest(index, because: "no session to do")
        }

        var extra = plan.filter { !$0.isRest }.count - profile.trainingDaysPerWeek
        let byEase = free.filter { !plan[$0].isRest }
            .sorted { (plan[$0].intensity.rank, plan[$0].durationMinutes) < (plan[$1].intensity.rank, plan[$1].durationMinutes) }
        for index in byEase where extra > 0 {
            rest(index, because: "at most \(profile.trainingDaysPerWeek) training days a week")
            extra -= 1
        }

        let total = trainingMinutes(plan, context: context)
        if let limit = minuteLimits(profile: profile, context: context).filter({ Double(total) > Double($0.minutes) * hoursTolerance }).min(by: { $0.minutes < $1.minutes }) {
            var excess = total - limit.minutes
            let goal = context?.goalIndex(days: plan.count)
            for intensity in [SessionIntensity.easy, .moderate, .hard] where excess > 0 {
                let candidates = free.filter { $0 != goal && plan[$0].intensity == intensity && plan[$0].durationMinutes > shortestSession }
                let room = candidates.map { plan[$0].durationMinutes - shortestSession }.reduce(0, +)
                guard room > 0 else { continue }
                let target = min(excess, room)
                // Shared by how much each session can give, in 5-minute steps.
                for index in candidates where excess > 0 {
                    let spare = plan[index].durationMinutes - shortestSession
                    let share = Double(spare) / Double(room) * Double(target)
                    let cut = min(spare, excess, Int((share / 5).rounded(.up)) * 5)
                    guard cut > 0 else { continue }
                    plan[index].durationMinutes -= cut
                    excess -= cut
                    changes.append("\(plan[index].day): \(cut) min shorter (\(limit.reason))")
                }
            }
        }

        // The goal day is the event: ease the day before it instead.
        let goal = context?.goalIndex(days: plan.count)
        let easable = { (index: Int) in free.contains(index) && index != goal }
        for index in plan.indices.dropFirst() where plan[index - 1].intensity == .hard && plan[index].intensity == .hard {
            if easable(index) {
                ease(index, because: "the day before was hard")
            } else if easable(index - 1) {
                ease(index - 1, because: "the next day is hard")
            }
        }
        if let goal, goal > 0, free.contains(goal - 1), plan[goal - 1].intensity == .hard {
            ease(goal - 1, because: "fresh legs for the \(context?.goalTitle ?? "goal")")
        }
        return (plan, changes)
    }

    /// Planned minutes, without the goal day (the event isn't training to cap).
    private static func trainingMinutes(_ plan: [PlannedDay], context: PlanContext?) -> Int {
        let goal = context?.goalIndex(days: plan.count)
        return plan.enumerated().filter { $0.offset != goal }.map(\.element.durationMinutes).reduce(0, +)
    }
}

/// Just the 7-day plan: the second step of a weekly analysis on a small context window, and the fix for a plan
/// that broke the rules.
@Generable
nonisolated struct WeekPlan: Codable, Hashable, Sendable {
    @Guide(description: "The 7-day plan, one entry per day, in order", .count(7))
    var days: [PlannedDay]
}

/// Fixes a generated plan: in code where the rules need no judgment, otherwise with a short follow-up that hands
/// the model its own plan and the broken rules. Small enough for the on-device model.
nonisolated enum PlanRepair {
    static let instructions = """
        You are an endurance coach correcting a 7-day training plan you wrote. Fix every listed problem with the \
        smallest change, keep the rest of the plan as it is, and keep the labels exactly as given. Rest days have \
        sport Rest, intensity rest, 0 minutes and zone 0.
        """

    struct Outcome: Equatable, Sendable {
        /// Broken rules left in the plan, as the model was told them.
        var problems: [String] = []
        /// What code changed in the plan, one line per change.
        var changes: [String] = []
    }

    /// Normalizes the plan and fixes what code can (`PlanCheck.autoFix`), then gives the model one chance to fix the
    /// problems left. Keeps the model's fix (after the same code fixes) only when it has fewer problems. `pinned`
    /// days (by position) are the athlete's own and are put back as they are, whatever the model wrote for them.
    static func run(
        _ report: inout AnalysisReport,
        labels: [String],
        profile: UserProfile,
        context: PlanContext? = nil,
        pinned: [Int: PlannedDay] = [:],
        log: (String) -> Void = { _ in },
        generate: (_ instructions: String, _ prompt: String) async throws -> WeekPlan
    ) async -> Outcome {
        let pinnedIndices = Set(pinned.keys)
        func problems(_ plan: [PlannedDay]) -> [String] {
            PlanCheck.problems(plan, labels: labels, profile: profile, context: context, pinned: pinnedIndices)
        }
        func fixed(_ plan: [PlannedDay]) -> (plan: [PlannedDay], changes: [String]) {
            var plan = plan
            if plan.count == labels.count {
                for (index, day) in pinned where plan.indices.contains(index) { plan[index] = day }
            }
            plan = PlanCheck.normalized(plan, labels: labels)
            guard plan.count == labels.count, !problems(plan).isEmpty else { return (plan, []) }
            return PlanCheck.autoFix(plan, profile: profile, context: context, pinned: pinnedIndices)
        }

        let first = fixed(report.weekPlan)
        report.weekPlan = first.plan
        if !first.changes.isEmpty { log("Plan fixed in code: \(first.changes.joined(separator: "; "))") }
        let left = problems(report.weekPlan)
        guard !left.isEmpty else { return Outcome(changes: first.changes) }
        log("Plan check: \(left.joined(separator: " "))")
        let prompt = prompt(
            plan: report.weekPlan, problems: left, profile: profile, reasoning: "\(report.headline) \(report.assessment)",
            pinnedLabels: pinned.keys.sorted().compactMap { labels.indices.contains($0) ? labels[$0] : nil },
            freeMinutes: context?.freeMinutes
        )
        do {
            let repaired = fixed(try await generate(instructions, prompt).days)
            let remaining = problems(repaired.plan)
            log("Plan repair: \(left.count) → \(remaining.count) problems")
            // A plan with the wrong number of days reports just that one problem, so it never counts as better.
            if repaired.plan.count == labels.count, remaining.count < left.count {
                report.weekPlan = repaired.plan
                return Outcome(problems: remaining, changes: repaired.changes)
            }
        } catch {
            log("Plan repair failed: \(error)")
        }
        return Outcome(problems: left, changes: first.changes)
    }

    static func prompt(plan: [PlannedDay], problems: [String], profile: UserProfile, reasoning: String, pinnedLabels: [String] = [], freeMinutes: [Int]? = nil) -> String {
        var lines = [
            "ATHLETE: \(profile.trainingDaysPerWeek) training days and \(PromptBuilder.num(profile.weeklyHoursAvailable, 1)) h a week at most.",
            "WHY THE PLAN LOOKS LIKE THIS: \(reasoning)",
            "",
            "PLAN (day | sport | intensity | session | min | zone | details)",
        ]
        lines += plan.map { "\($0.day) | \($0.sport) | \($0.intensity.rawValue) | \($0.session) | \($0.durationMinutes) | \($0.targetZone) | \($0.details)" }
        if let freeMinutes, freeMinutes.count == plan.count {
            lines.append("")
            lines.append("LONGEST FREE TIME IN THE CALENDAR: " + zip(plan, freeMinutes).map { "\($0.day) \($1) min" }.joined(separator: ", "))
        }
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
