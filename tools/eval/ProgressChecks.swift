import Foundation

/// XP rules, period lookups and week streaks of the Progress tab, on demo data with an archive.
func checkProgress() {
    section("Progress")
    let scenario = Scenario.demoWithHistory()
    let snapshot = scenario.snapshot
    guard let firstDay = snapshot.days.first?.date else {
        check(false, "demo data has days")
        return
    }
    let progress = ProgressReport(snapshot: snapshot.prepending(DemoData.archive(before: firstDay)), profile: scenario.profile)

    let skillTotal = progress.skills.values.map(\.xp).reduce(0, +)
    check(abs(progress.athlete.xp - skillTotal) < 0.001, "athlete XP is the sum of the skills (\(progress.athlete.xp) vs \(skillTotal))")
    guard let firstDate = progress.firstDate else {
        check(false, "progress has a first day")
        return
    }
    let end = scenario.calendar.date(byAdding: .day, value: 1, to: progress.lastDate) ?? progress.lastDate
    let allXP = progress.value(.xp, from: firstDate, to: end) ?? -1
    check(abs(allXP - progress.athlete.xp) < 0.001, "XP over all days matches the athlete's (\(allXP))")
    let allSessions = progress.value(.sessions, from: firstDate, to: end) ?? -1
    check(Int(allSessions) == progress.totalWorkouts, "sessions over all days match the total (\(allSessions) vs \(progress.totalWorkouts))")
    check(progress.value(.xp, from: end, to: firstDate) == nil || progress.value(.xp, from: end, to: firstDate) == 0, "an empty range has no XP")

    let thisWeek = progress.skillXP(nil, in: .week)
    let weekStart = progress.interval(.week, containing: progress.lastDate).start
    let weekDirect = progress.value(.xp, from: weekStart, to: end) ?? -1
    check(abs(thisWeek - weekDirect) < 0.001, "this week's XP agrees between lookups (\(thisWeek) vs \(weekDirect))")
    check(scenario.calendar.component(.weekday, from: weekStart) == 2, "weeks start on Monday")

    check(progress.levelHistory(nil).last.map { Int($0.level) == progress.athlete.level } == true, "level history ends at the athlete's level")
    check(!progress.records.isEmpty && !progress.achievements.isEmpty, "records and achievements are found")
    check(progress.achievements.first { $0.id == "workouts1" }?.isUnlocked == true, "first workout is unlocked")

    // XP rules, including the edges the UI text promises.
    let target = 8.0
    check(XPRules.rest(asleepHours: 7.75, targetHours: target) == XPRules.sleepOnTarget, "within 15 min of the target is on target")
    check(XPRules.rest(asleepHours: 7.0, targetHours: target) == XPRules.sleepNearTarget, "within an hour is near target")
    check(XPRules.rest(asleepHours: 6.9, targetHours: target) == 0, "more than an hour short earns nothing")
    check(XPRules.vitality(steps: 5000) == 10 && XPRules.vitality(steps: 80_000) == XPRules.stepsMaxPerDay, "steps earn XP up to the daily cap")
    check(XPRules.explorerPerKm(sport: Sport.swimming) > XPRules.explorerPerKm(sport: Sport.running)
          && XPRules.explorerPerKm(sport: Sport.running) > XPRules.explorerPerKm(sport: Sport.cycling), "a swimmed km counts most, a cycled km least")
    for skill in Skill.allCases where skill != .endurance && skill != .power {
        check(skill.rule.contains(where: \.isNumber), "\(skill.rawValue) rule names its numbers")
    }
}
