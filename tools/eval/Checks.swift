import Foundation

/// Deterministic checks of the logic around the model: no model, no network.
func runOfflineChecks() async {
    checkPlanAdherence()
    checkWeeklyPrompt()
    checkWorkoutPrompt()
    checkPlanCheck()
    checkReadiness()
    checkRaceForecast()
    await checkPlanRepair()
    checkLegacyHistory()
    checkSessionScheduler()
    checkForecastParsing()
    await checkAthletePlan()
    checkStrength()
    checkProgress()
}

/// Analyses saved by earlier versions (with an `engine`, before `modelName`, `sport` and `targetZone`) still load.
func checkLegacyHistory() {
    section("Saved history")
    let json = """
    [{"id":"6F1C2A7E-0D7B-4C51-9C8E-2B1A9C7D3E10","createdAt":780000000,"engine":"claude","planStartDate":780000000,
      "report":{"headline":"h","trainingStatus":"productive","assessment":"a","insights":[],"recommendations":[],"goalOutlook":"",
        "weekPlan":[{"day":"Mon 27 Oct","intensity":"rest","session":"Rest","durationMinutes":0,"details":""},
                    {"day":"Tue 28 Oct","intensity":"easy","session":"Easy run","durationMinutes":40,"details":""}]}},
     {"id":"0B8E5F2C-1A3D-4E6F-8A9B-C0D1E2F3A4B5","createdAt":780000000,"engine":"onDevice","planStartDate":780000000,
      "report":{"headline":"h","trainingStatus":"maintaining","assessment":"a","insights":[],"recommendations":[],"goalOutlook":"","weekPlan":[]}}]
    """
    do {
        let saved = try JSONDecoder().decode([SavedAnalysis].self, from: Data(json.utf8))
        check(saved.map(\.modelName) == ["Claude", "Apple Intelligence"], "old engine becomes a model name (\(saved.map(\.modelName)))")
        let days = saved[0].report.weekPlan
        check(days[0].sport == PlannedDay.rest && days[1].sport.isEmpty && days[1].targetZone == 0, "old plan days get default sport and zone")
        let again = try JSONDecoder().decode([SavedAnalysis].self, from: JSONEncoder().encode(saved))
        check(again == saved, "re-saved history round-trips")
    } catch {
        check(false, "old history decodes: \(error)")
    }
}

/// Repair with stand-in generators: a fix is kept only when it has fewer problems.
func checkPlanRepair() async {
    section("Plan repair")
    let scenario = Scenario.demoWithHistory()
    let labels = scenario.planLabels
    var profile = UserProfile()
    profile.trainingDaysPerWeek = 3
    profile.weeklyHoursAvailable = 3
    func day(_ index: Int, _ intensity: SessionIntensity, _ minutes: Int) -> PlannedDay {
        PlannedDay(day: labels[index], sport: intensity == .rest ? "Rest" : "Running", intensity: intensity, session: "s", durationMinutes: minutes, targetZone: intensity == .rest ? 0 : 2, details: "")
    }
    let broken = [day(0, .hard, 60), day(1, .hard, 60), day(2, .easy, 40), day(3, .easy, 40), day(4, .rest, 0), day(5, .moderate, 90), day(6, .rest, 0)]
    let fixed = [day(0, .hard, 50), day(1, .rest, 0), day(2, .easy, 40), day(3, .rest, 0), day(4, .rest, 0), day(5, .moderate, 90), day(6, .rest, 0)]
    func report(_ plan: [PlannedDay]) -> AnalysisReport {
        AnalysisReport(headline: "h", trainingStatus: .productive, assessment: "a", insights: [], recommendations: [], goalOutlook: "", weekPlan: plan)
    }

    var good = report(broken)
    let left = await PlanRepair.run(&good, labels: labels, profile: profile) { _, _ in WeekPlan(days: fixed) }
    check(left.isEmpty && good.weekPlan == fixed, "a valid fix is taken: \(left)")

    var worse = report(broken)
    let before = PlanCheck.problems(broken, labels: labels, profile: profile)
    let kept = await PlanRepair.run(&worse, labels: labels, profile: profile) { _, _ in WeekPlan(days: Array(fixed.prefix(5))) }
    check(kept == before && worse.weekPlan == broken, "a worse fix is ignored")

    var failing = report(broken)
    let failed = await PlanRepair.run(&failing, labels: labels, profile: profile) { _, _ in throw CancellationError() }
    check(failed == before, "a failed repair keeps the problems")

    var valid = report(fixed)
    var called = false
    _ = await PlanRepair.run(&valid, labels: labels, profile: profile) { _, _ in called = true; return WeekPlan(days: fixed) }
    check(!called, "no repair call for a valid plan")
}

func checkPlanAdherence() {
    section("Plan adherence")
    let scenario = Scenario.demoWithHistory()
    let adherence = PlanAdherence(
        plan: TrainingPlan(analyses: scenario.history), workouts: scenario.snapshot.workouts, zones: scenario.metrics.heartRateZones,
        now: scenario.snapshot.fetchedAt, calendar: scenario.calendar
    )
    for day in adherence.days {
        let recorded = day.workouts.map { "\($0.sport) \(Int($0.durationMinutes))′ \(Int($0.averageHeartRate ?? 0))bpm" }
        print("  \(PromptBuilder.dayLabel(day.date, calendar: scenario.calendar)) \(day.planned.session): \(day.status.rawValue) \(day.notes) \(recorded)")
    }
    let byOffset = Dictionary(uniqueKeysWithValues: adherence.days.map {
        (scenario.calendar.dateComponents([.day], from: scenario.today, to: $0.date).day!, $0)
    })
    check(adherence.days.count == 7, "7 planned days covered, got \(adherence.days.count)")
    // Demo weekdays: Tue intervals, Wed (ramp) run, Thu tempo, Sat long run, Sun ride, Mon gym; nothing today.
    let weekday = { (offset: Int) in scenario.calendar.component(.weekday, from: scenario.day(offset)) }
    for (offset, day) in byOffset {
        switch (weekday(offset), day.planned.sport) {
        case (_, _) where offset == 0:
            check(day.status == .pending, "today is pending")
        case (6, _) where !day.planned.isRest: // Friday: no demo workout
            check(day.status == .missed, "Friday's run missed, got \(day.status)")
        case (_, PlannedDay.rest) where !day.workouts.isEmpty:
            check(day.status == .extra, "workout on a rest day is extra")
        case (5, _): // Thursday tempo (~155 bpm) planned as easy Z2
            check(day.notes.contains { $0.hasPrefix("harder") }, "tempo on an easy day flagged harder: \(day.notes)")
        default:
            break
        }
    }
    check(PlanAdherence.summary(of: adherence.completed).contains("planned sessions done"), "summary line")

    // Unknown sport (plans saved before `sport` existed) doesn't produce a sport mismatch.
    let legacy = PlannedDay(day: "x", sport: "", intensity: .easy, session: "Easy run", durationMinutes: 45, targetZone: 0, details: "")
    let ride = WorkoutSummary(id: UUID(), start: .now, durationMinutes: 50, sport: "Cycling", averageHeartRate: 120, sourceName: "t")
    let (status, notes) = PlanAdherence.compare(planned: legacy, done: [ride], zones: scenario.metrics.heartRateZones)
    check(status == .done && notes.isEmpty, "legacy plan day without sport: \(status) \(notes)")

    // Old saved plans decode without the new fields.
    let json = #"{"day":"Mon 1 Jan","intensity":"easy","session":"Easy run","durationMinutes":40,"details":"d"}"#
    let decoded = try? JSONDecoder().decode(PlannedDay.self, from: Data(json.utf8))
    check(decoded?.sport == "" && decoded?.targetZone == 0, "legacy PlannedDay decodes")
}

func checkWeeklyPrompt() {
    section("Weekly prompt")
    let scenario = Scenario.demoWithHistory()
    for compact in [false, true] {
        let prompt = scenario.weeklyPrompt(compact: compact)
        let name = compact ? "compact" : "full"
        print("  \(name): \(prompt.count) characters")
        check(prompt.contains("LAST PLAN VS ACTUAL"), "\(name): plan vs actual section")
        check(prompt.contains("SESSION FEEDBACK"), "\(name): session feedback section")
        check(prompt.contains("Left calf felt tight after 14 km"), "\(name): note is quoted on one line")
        check(prompt.contains("COACH LOG"), "\(name): coach log section")
        check(!prompt.contains("| pending"), "\(name): today's pending day is left out")
        check(prompt.hasSuffix(scenario.planLabels.joined(separator: ", ") + "."), "\(name): ends with the plan labels")
    }
}

/// A gym session gets the strength coach, no heart-rate effort, and is told apart from the run it replaced.
func checkWorkoutPrompt() {
    section("Workout prompt")
    let scenario = Scenario.demoWithHistory()
    guard let gym = scenario.snapshot.workouts.last(where: { $0.sport == "Strength" }),
          let run = scenario.snapshot.workouts.last(where: { $0.sport == "Running" }) else {
        check(false, "demo data has a strength session and a run")
        return
    }
    check(gym.kind == .strength && run.kind == .endurance, "sports map to their coach")
    let easyRun = PlannedDay(
        day: scenario.label(0), sport: "Running", intensity: .easy, session: "Easy run",
        durationMinutes: 30, targetZone: 1, details: ""
    )
    func prompt(_ workout: WorkoutSummary) -> String {
        RunPromptBuilder(
            detail: DemoData.detail(for: workout), snapshot: scenario.snapshot, metrics: scenario.metrics,
            profile: scenario.profile, plannedSession: easyRun, note: "", compact: false
        ).prompt
    }
    let gymPrompt = prompt(gym), runPrompt = prompt(run)
    check(!gymPrompt.contains("Measured effort") && !gymPrompt.contains("Time in HR zones"), "strength: no heart-rate effort or zones")
    check(gymPrompt.contains("did Strength instead of the planned Running"), "strength: says it replaced the planned run")
    check(!gymPrompt.contains("| km |"), "strength: previous sessions without distance and pace")
    check(runPrompt.contains("Time in HR zones") && !runPrompt.contains("instead of the planned"), "run: zones, no sport swap")
    check(RunPromptBuilder.instructions(for: .strength).contains("strength and conditioning coach"), "strength: own instructions")

    let legacy = #"{"effort":"recovery","headline":"h","summary":"s","planComparison":"","highlights":[],"improvements":[],"recovery":"","nextSession":""}"#
    let decoded = try? JSONDecoder().decode(RunAnalysis.self, from: Data(legacy.utf8))
    check(decoded?.effort == .recovery && decoded?.summary == ["s"], "old reviews still decode")
    var strengthReview = decoded
    strengthReview?.effort = nil
    let again = strengthReview.flatMap { try? JSONDecoder().decode(RunAnalysis.self, from: JSONEncoder().encode($0)) }
    check(again != nil && again?.effort == nil, "reviews without an effort round-trip")
}

func checkPlanCheck() {
    section("Plan check")
    let scenario = Scenario.demoWithHistory()
    let labels = scenario.planLabels
    var profile = UserProfile()
    profile.trainingDaysPerWeek = 4
    profile.weeklyHoursAvailable = 5
    func day(_ index: Int, _ intensity: SessionIntensity, _ minutes: Int, sport: String = "Running", label: String? = nil) -> PlannedDay {
        PlannedDay(day: label ?? labels[index], sport: sport, intensity: intensity, session: "s", durationMinutes: minutes, targetZone: 2, details: "")
    }
    let good = [
        day(0, .hard, 50), day(1, .rest, 0, sport: "Rest"), day(2, .easy, 45), day(3, .rest, 0, sport: "Rest"),
        day(4, .moderate, 90), day(5, .easy, 60, sport: "Cycling"), day(6, .rest, 0, sport: "Rest"),
    ]
    check(PlanCheck.problems(good, labels: labels, profile: profile).isEmpty, "a valid plan has no problems: \(PlanCheck.problems(good, labels: labels, profile: profile))")

    // Wrong labels and sloppy rest days are fixed in code.
    var sloppy = good
    sloppy[0].day = "Monday"
    sloppy[1] = PlannedDay(day: labels[1], sport: "Running", intensity: .rest, session: "Rest", durationMinutes: 20, targetZone: 2, details: "")
    let normalized = PlanCheck.normalized(sloppy, labels: labels)
    check(normalized.map(\.day) == labels, "labels fixed by position")
    check(normalized[1].durationMinutes == 0 && normalized[1].sport == PlannedDay.rest && normalized[1].targetZone == 0, "rest day fields fixed")

    // Rules that need the model.
    var broken = good
    broken[1] = day(1, .hard, 60)           // back-to-back hard, 5th training day
    broken[4].durationMinutes = 150         // over the weekly hours
    broken[6] = day(6, .easy, 0)            // session without minutes, 6th training day
    let problems = PlanCheck.problems(broken, labels: labels, profile: profile)
    problems.forEach { print("  · \($0)") }
    check(problems.contains { $0.contains("both hard") }, "back-to-back hard days")
    check(problems.contains { $0.contains("training days") }, "too many training days")
    check(problems.contains { $0.contains("min a week") }, "over the weekly hours")
    check(problems.contains { $0.contains("0 minutes") }, "session without minutes")
    check(PlanCheck.problems(Array(good.prefix(6)), labels: labels, profile: profile).count == 1, "wrong day count is one problem")

    let repair = PlanRepair.prompt(plan: broken, problems: problems, profile: profile, reasoning: "Load is high.")
    print("  repair prompt: \(repair.count) characters")
    check(repair.contains("PROBLEMS") && repair.contains(labels[0]), "repair prompt lists plan and problems")
}

func checkReadiness() {
    section("Readiness")
    var scenario = Scenario.demoWithHistory()
    let readiness = Readiness(snapshot: scenario.snapshot, metrics: scenario.metrics, profile: scenario.profile, calendar: scenario.calendar)
    print("  demo: \(readiness.level) \(readiness.signals.map(\.text)) fine: \(readiness.fine)")
    check(readiness.level == .low, "demo data (ramp, short sleep) reads as low")

    // Rested: today's numbers at baseline and a full night.
    let today = scenario.today
    if let index = scenario.snapshot.days.firstIndex(where: { $0.date == today }) {
        scenario.snapshot.days[index].restingHeartRate = scenario.metrics.indicators.restingHR28
        scenario.snapshot.days[index].hrvMs = scenario.metrics.indicators.hrv28
    }
    if let index = scenario.snapshot.sleep.firstIndex(where: { $0.date == today }) {
        scenario.snapshot.sleep[index].asleepHours = 8
    }
    let rested = Readiness(snapshot: scenario.snapshot, metrics: scenario.metrics, profile: scenario.profile, calendar: scenario.calendar)
    check(rested.level == .good, "baseline values read as good, got \(rested.level) \(rested.signals.map(\.text))")

    // No data today at all.
    scenario.snapshot.days.removeAll { $0.date == today }
    scenario.snapshot.sleep.removeAll { $0.date == today }
    let empty = Readiness(snapshot: scenario.snapshot, metrics: scenario.metrics, profile: scenario.profile, calendar: scenario.calendar)
    check(empty.signals.allSatisfy { !$0.text.contains("HRV") && !$0.text.contains("Slept") }, "missing data isn't flagged")

    // The model can't make a session harder or longer.
    let planned = PlannedDay(day: "Tue 27 Oct", sport: "Running", intensity: .moderate, session: "Steady run", durationMinutes: 50, targetZone: 3, details: "")
    let greedy = DayAdjustment(reason: "r", session: PlannedDay(day: "Wed", sport: "Running", intensity: .hard, session: "Intervals", durationMinutes: 70, targetZone: 5, details: ""))
        .clamped(to: planned).session
    check(greedy.day == planned.day && greedy.intensity == .moderate && greedy.durationMinutes == 50 && greedy.targetZone == 3, "clamped to the plan: \(greedy)")
    let rest = DayAdjustment(reason: "r", session: PlannedDay(day: "x", sport: "Running", intensity: .easy, session: "Rest", durationMinutes: 0, targetZone: 2, details: ""))
        .clamped(to: planned).session
    check(rest.isRest && rest.sport == PlannedDay.rest && rest.targetZone == 0, "0 minutes becomes a rest day: \(rest)")

    let prompt = DayAdjustment.prompt(planned: planned, readiness: readiness, metrics: scenario.metrics, profile: scenario.profile)
    print("  adjustment prompt: \(prompt.count) characters")
    check(prompt.contains("Strong signal"), "prompt lists the signals")
}

/// A slow recent half marathon with easy runs around it: the forecast stays close to the real result.
func checkRaceForecast() {
    section("Race forecast")
    let calendar = Calendar.current
    let now = Date.now
    func run(_ daysAgo: Int, km: Double, minutes: Double) -> WorkoutSummary {
        WorkoutSummary(id: UUID(), start: calendar.date(byAdding: .day, value: -daysAgo, to: now)!, durationMinutes: minutes, sport: "Running",
                       distanceKm: km, activeEnergyKcal: nil, averageHeartRate: 150, maxHeartRate: nil, sourceName: "Watch")
    }
    let workouts = [run(20, km: 8, minutes: 58), run(10, km: 6, minutes: 42), run(6, km: 10, minutes: 70), run(2, km: 21.2, minutes: 139)]
    let april = calendar.date(byAdding: .day, value: 170, to: now)!
    guard let forecast = RaceForecast.make(distanceKm: 21.0975, raceDate: april, workouts: workouts, experience: .beginner, now: now) else {
        return check(false, "a forecast from recent runs")
    }
    check(forecast.sameDistance?.distanceKm == 21.2, "finds the recent half marathon")
    check((2.1 * 3600...2.35 * 3600).contains(forecast.currentSeconds), "current fitness near 2:19 (\(WorkoutFormat.duration(forecast.currentSeconds)))")
    check(forecast.fastSeconds >= forecast.currentSeconds * 0.92 && forecast.fastSeconds < forecast.slowSeconds, "projection gains at most 8% (\(WorkoutFormat.duration(forecast.fastSeconds)))")
    check(forecast.brief.contains("Half marathon") && forecast.brief.contains("Quote these times"), "brief names the race and tells the model to quote it")
    check(RaceForecast.make(distanceKm: 5, raceDate: now, workouts: [run(80, km: 10, minutes: 60)], experience: .advanced, now: now) == nil, "no forecast from runs older than 8 weeks")
    print(forecast.brief)
}
