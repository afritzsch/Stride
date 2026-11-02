import Foundation

/// The pain and illness log: limits per day, readiness, the plan check and the prompts.
func checkHealthLog() {
    section("Health log")
    let scenario = Scenario.demoWithHistory()
    let calendar = scenario.calendar
    let today = scenario.today
    func day(_ offset: Int) -> Date { scenario.day(offset) }

    let calf = HealthIssue(kind: .pain, bodyPart: .calf, side: .left, severity: .moderate, started: day(-1), calendar: calendar)
    check(calf.title == "Left calf pain", "pain title: \(calf.title)")
    check(HealthIssue(kind: .pain, bodyPart: .lowerBack, severity: .mild, started: today).title == "Lower back pain", "pain without a side")
    let calfToday = calf.limit(on: today, calendar: calendar)
    check(calfToday?.maxIntensity == .easy && calfToday?.avoidSports.contains(Sport.running) == true, "moderate calf pain: easy, no running (\(String(describing: calfToday)))")
    check(calf.limit(on: day(2), calendar: calendar) != nil && calf.limit(on: day(3), calendar: calendar) == nil,
          "limits last \(HealthIssue.horizonDays) days past the last check-in")
    check(calf.limit(on: day(-2), calendar: calendar) == nil, "no limit before it started")

    let mildPain = HealthIssue(kind: .pain, bodyPart: .knee, severity: .mild, started: today, calendar: calendar)
    check(mildPain.limit(on: today, calendar: calendar)?.maxIntensity == .moderate, "mild pain: nothing hard")
    let fever = HealthIssue(kind: .illness, illness: .fever, severity: .mild, started: today, calendar: calendar)
    check(fever.limit(on: today, calendar: calendar)?.maxIntensity == .rest, "fever (below the neck) means rest even when mild")
    let cold = HealthIssue(kind: .illness, illness: .headCold, severity: .moderate, started: today, calendar: calendar)
    check(cold.limit(on: today, calendar: calendar)?.maxIntensity == .easy, "head cold: easy only")

    var gone = HealthIssue(kind: .illness, illness: .chest, severity: .moderate, started: day(-5), calendar: calendar)
    gone.resolvedOn = today
    let back = (0..<3).map { gone.limit(on: day($0), calendar: calendar)?.maxIntensity }
    check(back == [.easy, .easy, nil], "first \(HealthIssue.returnDays) days back after illness are easy: \(back)")

    var checked = calf
    checked.checkIn(.mild, on: today, calendar: calendar)
    checked.checkIn(.mild, on: today.addingTimeInterval(3600), calendar: calendar)
    check(checked.checkIns.count == 2 && checked.severity == .mild && checked.trend == "better", "a second check-in the same day replaces the first")
    check(checked.limit(on: today, calendar: calendar)?.maxIntensity == .moderate, "checking in mild relaxes the limit")

    let log = HealthLog(issues: [calf, cold], calendar: calendar)
    let merged = log.limit(on: today)
    check(merged?.maxIntensity == .easy && merged?.avoidSports.contains(Sport.running) == true && merged?.reasons.count == 2, "limits merge: \(merged?.summary ?? "nil")")

    let hardRun = PlannedDay(day: "x", sport: Sport.running, intensity: .hard, session: "Intervals", durationMinutes: 50, targetZone: 4, details: "")
    let swapped = calfToday?.apply(to: hardRun)
    check(swapped?.sport == "Cross training" && swapped?.intensity == .easy && swapped?.durationMinutes == 50, "a run becomes easy cross training: \(String(describing: swapped))")
    let easyRide = PlannedDay(day: "x", sport: Sport.cycling, intensity: .easy, session: "Easy ride", durationMinutes: 60, targetZone: 2, details: "")
    check(calfToday?.apply(to: easyRide) == nil, "an easy ride already fits calf pain")
    check(fever.limit(on: today, calendar: calendar)?.apply(to: easyRide)?.isRest == true, "fever turns any session into rest")

    // Readiness: a rested morning with a logged issue.
    var rested = scenario
    if let index = rested.snapshot.days.firstIndex(where: { $0.date == today }) {
        rested.snapshot.days[index].restingHeartRate = rested.metrics.indicators.restingHR28
        rested.snapshot.days[index].hrvMs = rested.metrics.indicators.hrv28
    }
    if let index = rested.snapshot.sleep.firstIndex(where: { $0.date == today }) { rested.snapshot.sleep[index].asleepHours = 8 }
    let withCalf = Readiness(snapshot: rested.snapshot, metrics: rested.metrics, profile: rested.profile, healthIssues: [calf], calendar: calendar)
    check(withCalf.level == .low && withCalf.signals.contains { $0.isLogged }, "moderate pain alone reads as low: \(withCalf.level) \(withCalf.signals.map(\.text))")
    let withMild = Readiness(snapshot: rested.snapshot, metrics: rested.metrics, profile: rested.profile, healthIssues: [mildPain], calendar: calendar)
    check(withMild.level == .caution, "mild pain alone reads as caution, got \(withMild.level)")

    // Today's adjustment can't break the limit, whatever the model writes.
    let adjusted = DayAdjustment(reason: "r", session: hardRun).clamped(to: hardRun, limit: calfToday).session
    check(adjusted.sport != Sport.running && adjusted.intensity == .easy, "adjustment respects the log: \(adjusted)")

    // The plan check and its fixes, never on the athlete's own days.
    let labels = scenario.planLabels
    let limits = log.limits(start: scenario.planStart)
    let context = PlanContext(dayLimits: limits)
    var plan = labels.map { PlannedDay(day: $0, sport: PlannedDay.rest, intensity: .rest, session: "Rest", durationMinutes: 0, targetZone: 0, details: "") }
    plan[0] = PlannedDay(day: labels[0], sport: Sport.running, intensity: .hard, session: "Tempo", durationMinutes: 45, targetZone: 4, details: "")
    plan[1] = PlannedDay(day: labels[1], sport: Sport.running, intensity: .easy, session: "Easy run", durationMinutes: 40, targetZone: 2, details: "")
    plan[5] = PlannedDay(day: labels[5], sport: Sport.running, intensity: .hard, session: "Intervals", durationMinutes: 50, targetZone: 4, details: "")
    let problems = PlanCheck.problems(plan, labels: labels, profile: scenario.profile, context: context)
    check(problems.filter { $0.contains("logged") }.count == 2, "days 1–2 break the log, day 6 is past the horizon: \(problems)")
    let fixed = PlanCheck.autoFix(plan, profile: scenario.profile, context: context, pinned: [1])
    check(fixed.plan[0].sport == "Cross training" && fixed.plan[1] == plan[1] && fixed.plan[5].sport == Sport.running,
          "autoFix swaps day 1, keeps the athlete's day 2 and day 6: \(fixed.changes)")

    // Prompts.
    let prompt = PromptBuilder(
        snapshot: scenario.snapshot, metrics: scenario.metrics, profile: scenario.profile, planStart: scenario.planStart,
        compact: true, history: scenario.history, reviews: scenario.reviews, healthIssues: [calf, gone], calendar: calendar
    ).prompt
    let healthLines = prompt.split(separator: "\n").filter { $0.contains("HEALTH LOG") || $0.hasPrefix("- Left calf") || $0.hasPrefix("- Cough") || $0.hasPrefix("- Limit") }
    print(healthLines.map { "  " + $0 }.joined(separator: "\n"))
    check(prompt.contains("HEALTH LOG") && prompt.contains("Left calf pain: moderate") && prompt.contains("gone since"), "weekly prompt lists the issues")
    check(prompt.contains("- Limit \(labels[1]): easy only, no HIIT, Hiking or Running (left calf pain, moderate)"), "weekly prompt lists each day's limit")
    let fresh = HealthIssue(kind: .pain, bodyPart: .calf, side: .left, severity: .moderate, started: today, calendar: calendar)
    let grouped = HealthLog(issues: [fresh], calendar: calendar).promptLines(planStart: scenario.planStart, compact: true)
    check(grouped.last == "- Limit \(labels[0]) to \(labels[2]): easy only, no HIIT, Hiking or Running (left calf pain, moderate)", "equal days are grouped: \(grouped)")
    check(!PromptBuilder(
        snapshot: scenario.snapshot, metrics: scenario.metrics, profile: scenario.profile, planStart: scenario.planStart,
        compact: true, calendar: calendar
    ).prompt.contains("HEALTH LOG"), "no section without issues")

    let old = HealthIssue(kind: .pain, bodyPart: .knee, severity: .mild, started: day(-300), calendar: calendar)
    var oldGone = old
    oldGone.resolvedOn = day(-200)
    check(HealthLog(issues: [oldGone, calf], calendar: calendar).pruned(now: today).count == 1, "old resolved issues are dropped")

    do {
        let data = try JSONEncoder().encode([calf, gone])
        check(try JSONDecoder().decode([HealthIssue].self, from: data) == [calf, gone], "the log round-trips")
    } catch {
        check(false, "the log encodes: \(error)")
    }
}

/// The training block: phases counted back from the goal, recovery weeks, and the limits they put on a plan.
func checkTrainingBlock() {
    section("Training block")
    let scenario = Scenario.demoWithHistory()
    let calendar = scenario.calendar
    let start = scenario.planStart
    var profile = scenario.profile
    profile.hasGoal = true
    profile.goalName = "Berlin Half"
    profile.goalDate = calendar.date(byAdding: .day, value: 14 * 7 + 3, to: start)!

    let outline = TrainingBlock.outline(start: start, profile: profile, calendar: calendar)
    let phases = outline.map(\.phase)
    let counts = TrainingPhase.allCases.map { phase in phases.filter { $0 == phase }.count }
    print("  outline: " + outline.map { $0.phase.rawValue.prefix(2) + ($0.isRecovery ? "*" : "") }.joined(separator: " "))
    check(outline.count == 15 && counts == [4, 6, 3, 1, 1, 0], "15 weeks: 4 base, 6 build, 3 peak, taper, race (\(counts))")
    check(outline.filter(\.isRecovery).compactMap(\.weeksToGoal) == [12, 8], "recovery weeks 12 and 8 weeks out")
    check(outline.first?.phaseWeek?.index == 1 && outline.first?.phaseWeek?.count == 4, "first week is base week 1 of 4")
    check(outline.first?.start == start && outline.last.map { calendar.dateComponents([.day], from: $0.start, to: profile.goalDate).day ?? -1 } == 3,
          "weeks run from the plan start to the goal week")
    let week = TrainingBlock.week(start: start, profile: profile, weeks: scenario.metrics.weeks, calendar: calendar)
    check(week == outline[0], "the plan's week matches the outline")

    var soon = profile
    soon.goalDate = calendar.date(byAdding: .day, value: 4, to: start)!
    check(TrainingBlock.week(start: start, profile: soon, weeks: [], calendar: calendar).phase == .race, "goal within the plan: race week")
    soon.goalDate = calendar.date(byAdding: .day, value: 40, to: start)!
    let late = TrainingBlock.week(start: start, profile: soon, weeks: [], calendar: calendar)
    check(late.phase == .build && late.phaseWeek?.index == 1 && late.phaseWeek?.count == 1, "a goal 5 weeks out starts in build: \(late.title)")

    // Without a goal, a recovery week follows three loading weeks.
    func weeks(_ minutes: [Double]) -> [WeeklySummary] {
        minutes.enumerated().map { index, total in
            var week = WeeklySummary(weekStart: calendar.date(byAdding: .day, value: (index - minutes.count) * 7, to: start)!)
            week.trainingMinutes = total
            return week
        }
    }
    check(TrainingBlock.recoveryDue(before: start, weeks: weeks([300, 310, 320, 330]), calendar: calendar), "four loading weeks: recovery due")
    check(!TrainingBlock.recoveryDue(before: start, weeks: weeks([300, 320, 330, 200]), calendar: calendar), "an easy last week: no recovery due")
    check(!TrainingBlock.recoveryDue(before: start, weeks: weeks([20, 30, 25, 30]), calendar: calendar), "too little training to need recovery")

    // Limits: recovery minutes and hard sessions.
    let recovery = BlockWeek(start: start, phase: .general, isRecovery: true)
    let limits = PlanCheck.minuteLimits(profile: scenario.profile, context: PlanContext(recentWeeklyMinutes: 300, block: recovery))
    check(limits.map(\.minutes).min() == 210, "recovery week caps minutes at 70%: \(limits.map(\.minutes))")

    let labels = scenario.planLabels
    let base = BlockWeek(start: start, phase: .base, isRecovery: false)
    var plan = labels.map { PlannedDay(day: $0, sport: PlannedDay.rest, intensity: .rest, session: "Rest", durationMinutes: 0, targetZone: 0, details: "") }
    plan[1] = PlannedDay(day: labels[1], sport: Sport.running, intensity: .hard, session: "Tempo", durationMinutes: 45, targetZone: 4, details: "")
    plan[4] = PlannedDay(day: labels[4], sport: Sport.running, intensity: .hard, session: "Intervals", durationMinutes: 50, targetZone: 4, details: "")
    let problems = PlanCheck.problems(plan, labels: labels, profile: scenario.profile, context: PlanContext(block: base))
    check(problems.contains { $0.contains("2 hard sessions") && $0.contains("base week") }, "two hard sessions in a base week: \(problems)")
    let fixed = PlanCheck.autoFix(plan, profile: scenario.profile, context: PlanContext(block: base))
    check(fixed.plan[1].intensity == .hard && fixed.plan[4].intensity == .easy, "the later hard session is eased: \(fixed.changes)")
    let pinned = PlanCheck.autoFix(plan, profile: scenario.profile, context: PlanContext(block: base), pinned: [4])
    check(pinned.plan[4].intensity == .hard && pinned.plan[1].intensity == .easy, "the athlete's own hard day stays: \(pinned.changes)")

    var goalScenario = scenario
    goalScenario.profile = profile
    let prompt = goalScenario.weeklyPrompt(compact: true)
    let line = prompt.split(separator: "\n").first { $0.hasPrefix("TRAINING BLOCK") }.map(String.init) ?? ""
    print("  \(line)")
    check(line.contains("Base, week 1 of 4") && line.contains("14 weeks before the Berlin Half week") && line.contains("At most 1 hard session"), "prompt states the block")
    check(scenario.weeklyPrompt(compact: true).contains("TRAINING BLOCK: General fitness"), "without a goal the block is general fitness")
}
