import Foundation

/// Where the athlete is in a training block toward their goal: base → build → peak → taper → race week, with an
/// easier recovery week every fourth week. Computed in code from the goal date (counted back from the goal, so the
/// phase of a week doesn't depend on the day the analysis runs) and, without a goal, from recent weeks.
nonisolated enum TrainingPhase: String, Codable, CaseIterable, Sendable {
    case base, build, peak, taper, race, general

    var title: String {
        switch self {
        case .base: "Base"
        case .build: "Build"
        case .peak: "Peak"
        case .taper: "Taper"
        case .race: "Race week"
        case .general: "General fitness"
        }
    }

    /// What the week's training is for, for the prompt and the Plan tab.
    var focus: String {
        switch self {
        case .base: "aerobic base: mostly easy zone 2, a long session that grows slowly, strides or one short quality session"
        case .build: "build: two quality sessions (tempo or intervals) with easy days between, the long session keeps growing"
        case .peak: "peak: goal-specific sessions at goal intensity and the longest long sessions; volume holds"
        case .taper: "taper: less volume, one short sharp session to stay sharp, extra sleep"
        case .race: "race week: short easy sessions with a few strides, rest or very easy the day before the goal"
        case .general: "general fitness: mostly easy aerobic sessions, one or two quality sessions and strength"
        }
    }

    /// Hard sessions a week, not counting the goal day.
    var maxHardSessions: Int {
        switch self {
        case .base, .taper, .race: 1
        case .build, .peak, .general: 2
        }
    }
}

nonisolated struct BlockWeek: Hashable, Sendable {
    /// The week's first day (the plan's first day for the current week).
    var start: Date
    var phase: TrainingPhase
    var isRecovery: Bool
    /// Whole weeks between this week and the goal's week (0 = the goal is in it), nil without a goal.
    var weeksToGoal: Int?
    /// 1-based position within its phase and the phase's length, e.g. week 2 of 6 of build; nil without a goal.
    var phaseWeek: (index: Int, count: Int)?

    var maxHardSessions: Int { isRecovery ? 1 : phase.maxHardSessions }

    /// "Build, week 2 of 6 (recovery week)".
    var title: String {
        var text = phase.title
        if let phaseWeek, phase != .race { text += ", week \(phaseWeek.index) of \(phaseWeek.count)" }
        if isRecovery { text += " (recovery week)" }
        return text
    }

    static func == (lhs: BlockWeek, rhs: BlockWeek) -> Bool {
        lhs.start == rhs.start && lhs.phase == rhs.phase && lhs.isRecovery == rhs.isRecovery && lhs.weeksToGoal == rhs.weeksToGoal
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(start)
        hasher.combine(phase)
        hasher.combine(isRecovery)
    }
}

nonisolated enum TrainingBlock {
    /// Weeks before the goal week where each phase starts (counting back): taper 1, peak 2–4, build 5–10, base 11+.
    static let taperWeeks = 1...1
    static let peakWeeks = 2...4
    static let buildWeeks = 5...10
    /// With a goal, every fourth week of base and build is a recovery week, counted back from the peak, so the
    /// athlete starts the peak after three loading weeks.
    static let recoveryCycle = 4
    /// A recovery week trains about this share of the usual week.
    static let recoveryShare = 0.7
    /// Without a goal, a week below this share of the usual counts as easier, and after this many loading weeks
    /// in a row the next one is a recovery week.
    static let easyWeekShare = 0.85
    static let loadingWeeksBeforeRecovery = 3
    /// The Plan tab's outline shows at most this many weeks.
    static let outlineWeeks = 26

    static func phase(weeksToGoal weeks: Int) -> TrainingPhase {
        switch weeks {
        case 0: .race
        case taperWeeks: .taper
        case peakWeeks: .peak
        case buildWeeks: .build
        default: .base
        }
    }

    static func isRecovery(weeksToGoal weeks: Int) -> Bool {
        weeks > buildWeeks.lowerBound && (weeks - peakWeeks.upperBound) % recoveryCycle == 0
    }

    /// Days from `start` to the goal, nil without an upcoming goal.
    static func daysToGoal(from start: Date, profile: UserProfile, calendar: Calendar) -> Int? {
        guard profile.hasGoal,
              let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: profile.goalDate)).day,
              days >= 0 else { return nil }
        return days
    }

    /// The week starting at `start` (the plan's first day). `weeks` are the metrics' weekly rollups, used without a
    /// goal to tell when a recovery week is due.
    static func week(start: Date, profile: UserProfile, weeks: [WeeklySummary], calendar: Calendar = .current) -> BlockWeek {
        let start = calendar.startOfDay(for: start)
        if let days = daysToGoal(from: start, profile: profile, calendar: calendar) {
            return goalWeek(start: start, weeksToGoal: days / 7, totalWeeks: days / 7)
        }
        return BlockWeek(start: start, phase: .general, isRecovery: recoveryDue(before: start, weeks: weeks, calendar: calendar))
    }

    /// Every week from `start` to the goal week, for the Plan tab. Empty without a goal.
    static func outline(start: Date, profile: UserProfile, calendar: Calendar = .current) -> [BlockWeek] {
        let start = calendar.startOfDay(for: start)
        guard let days = daysToGoal(from: start, profile: profile, calendar: calendar) else { return [] }
        let first = days / 7
        return (0...first).reversed().prefix(outlineWeeks).map { weeks in
            let weekStart = calendar.date(byAdding: .day, value: (first - weeks) * 7, to: start) ?? start
            return goalWeek(start: weekStart, weeksToGoal: weeks, totalWeeks: first)
        }
    }

    private static func goalWeek(start: Date, weeksToGoal weeks: Int, totalWeeks: Int) -> BlockWeek {
        let phase = phase(weeksToGoal: weeks)
        // The phase's weeks that are still ahead or current: its range clipped to the weeks left.
        let range: ClosedRange<Int> = switch phase {
        case .race: 0...0
        case .taper: taperWeeks
        case .peak: peakWeeks
        case .build: buildWeeks
        default: (buildWeeks.upperBound + 1)...max(buildWeeks.upperBound + 1, totalWeeks)
        }
        let count = min(range.upperBound, max(totalWeeks, range.lowerBound)) - range.lowerBound + 1
        let index = min(range.upperBound, totalWeeks) - weeks + 1
        return BlockWeek(
            start: start, phase: phase, isRecovery: isRecovery(weeksToGoal: weeks), weeksToGoal: weeks,
            phaseWeek: (max(1, index), max(1, count))
        )
    }

    /// Without a goal: a recovery week after `loadingWeeksBeforeRecovery` complete weeks in a row at or above
    /// `easyWeekShare` of the usual week (the average of the last four complete weeks).
    static func recoveryDue(before start: Date, weeks: [WeeklySummary], calendar: Calendar) -> Bool {
        let complete = weeks.filter { (calendar.date(byAdding: .day, value: 7, to: $0.weekStart) ?? $0.weekStart) <= start }.suffix(4)
        guard complete.count >= loadingWeeksBeforeRecovery else { return false }
        let usual = complete.map(\.trainingMinutes).reduce(0, +) / Double(complete.count)
        guard usual >= PlanContext.minRecentMinutes else { return false }
        let loading = complete.reversed().prefix { $0.trainingMinutes >= usual * easyWeekShare }.count
        return loading >= loadingWeeksBeforeRecovery
    }

    /// The TRAINING BLOCK prompt line.
    static func promptLine(_ week: BlockWeek, profile: UserProfile) -> String {
        var line = "TRAINING BLOCK: \(week.title)"
        if let weeks = week.weeksToGoal {
            line += weeks == 0 ? ", the \(PromptBuilder.goalTitle(profile)) is this week" : ", \(weeks) week\(weeks == 1 ? "" : "s") before the \(PromptBuilder.goalTitle(profile)) week"
        }
        line += ". Focus: \(week.phase.focus)."
        if week.isRecovery { line += " Recovery week: about \(Int(recoveryShare * 100))% of the usual volume." }
        line += " At most \(week.maxHardSessions) hard session\(week.maxHardSessions == 1 ? "" : "s")\(week.weeksToGoal == 0 ? " besides the goal" : "")."
        return line
    }
}
