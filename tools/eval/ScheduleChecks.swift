import Foundation

// Time suggestions, forecast parsing and the athlete's own plan days: no calendar, no network.

/// The next Tuesday after today at midnight, so weekday habits apply.
private func nextTuesday(_ calendar: Calendar) -> Date {
    let today = calendar.startOfDay(for: .now)
    var date = calendar.date(byAdding: .day, value: 1, to: today)!
    while calendar.component(.weekday, from: date) != 3 { date = calendar.date(byAdding: .day, value: 1, to: date)! }
    return date
}

private func at(_ day: Date, _ hour: Int, _ minute: Int = 0) -> Date {
    day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
}

private func forecast(day: Date, rainHours: ClosedRange<Int>? = nil, temperature: Double = 10, sun: (Int, Int)? = nil) -> WeatherForecast {
    let hours = (0..<24).map { hour in
        let wet = rainHours?.contains(hour) ?? false
        return HourlyWeather(
            date: at(day, hour), temperatureC: temperature, apparentTemperatureC: temperature,
            precipitationChance: wet ? 0.8 : 0.05, precipitationMm: wet ? 2 : 0, windKph: 10, uvIndex: 0,
            condition: wet ? .rain : .partlyCloudy
        )
    }
    let sunTimes = sun.map { [SunTimes(date: day, sunrise: at(day, $0.0, 30), sunset: at(day, $0.1, 30))] } ?? []
    return WeatherForecast(fetchedAt: .now, source: .openMeteo, placeName: nil, hours: hours, sun: sunTimes)
}

func checkSessionScheduler() {
    section("Session scheduler")
    let calendar = Calendar.current
    let day = nextTuesday(calendar)
    let now = calendar.date(byAdding: .day, value: -1, to: day)!
    let settings = ScheduleSettings()
    let run = PlannedDay(day: "", sport: "Running", intensity: .easy, session: "Easy run", durationMinutes: 45, targetZone: 2, details: "")
    let gym = PlannedDay(day: "", sport: "Strength", intensity: .moderate, session: "Gym", durationMinutes: 45, targetZone: 0, details: "")
    let work = [BusyInterval(start: at(day, 9), end: at(day, 17), title: "Work")]
    func schedule(_ session: PlannedDay, busy: [BusyInterval] = work, forecast: WeatherForecast? = nil, habits: StartHabits = .none, now: Date = now, settings: ScheduleSettings = settings) -> DaySchedule {
        SessionScheduler.schedule(date: day, session: session, busy: busy, forecast: forecast, settings: settings, habits: habits, now: now, calendar: calendar)
    }
    let time = { (date: Date) in SessionScheduler.time(date, calendar: calendar) }

    let plain = schedule(run)
    check(!plain.slots.isEmpty, "slots around work")
    check(plain.slots.allSatisfy { $0.end <= at(day, 8, 45) || $0.start >= at(day, 17, 15) }, "slots keep 15 min clear of work: \(plain.slots.map { time($0.start) })")
    check(plain.slots.first?.start == at(day, 6), "without weather or habits the earliest time wins: \(plain.slots.first.map { time($0.start) } ?? "-")")
    let starts = plain.slots.map(\.start)
    check(zip(starts, starts.dropFirst()).allSatisfy { abs($0.timeIntervalSince($1)) >= 3600 }, "suggestions at least an hour apart")

    let wetMorning = schedule(run, forecast: forecast(day: day, rainHours: 5...9))
    check((wetMorning.best?.start ?? .distantPast) >= at(day, 17, 15), "rainy morning moves the run to the evening: \(wetMorning.best.map { time($0.start) } ?? "-")")
    check(wetMorning.slots.contains { $0.warnings.contains { $0.hasPrefix("Rain likely") } } || wetMorning.slots.allSatisfy { $0.start >= at(day, 17) }, "rain is named when a wet slot is offered")
    let indoor = schedule(gym, forecast: forecast(day: day, rainHours: 5...9))
    check(indoor.best?.start == at(day, 6), "weather doesn't matter for strength")

    let dark = schedule(run, forecast: forecast(day: day, sun: (7, 16)))
    check((dark.best?.start ?? .distantPast) >= at(day, 7, 30) && (dark.best?.end ?? .distantFuture) <= at(day, 8, 45), "daylight before work beats the dark: \(dark.best.map { time($0.start) } ?? "-")")
    check(dark.slots.contains { $0.warnings.contains { $0.hasPrefix("After sunset") || $0.hasPrefix("Before sunrise") } }, "dark slots say so")

    let pastWeekdays = (1...6).compactMap { calendar.date(byAdding: .day, value: -7 * $0, to: at(day, 18)) }
    let habits = StartHabits(
        workouts: pastWeekdays.map { WorkoutSummary(id: UUID(), start: $0, durationMinutes: 45, sport: "Running", sourceName: "t") },
        calendar: calendar
    )
    let usual = schedule(run, habits: habits)
    check(usual.best.map { calendar.component(.hour, from: $0.start) } == 18, "usual 18:00 start wins without weather: \(usual.best.map { time($0.start) } ?? "-")")
    check(usual.best?.reasons.contains("Your usual time") == true, "usual time is a reason")

    let full = schedule(run, busy: [BusyInterval(start: at(day, 5), end: at(day, 22), title: "Trip")])
    check(full.slots.isEmpty && full.note != nil, "a full day has no slots but a note")

    let added = BusyInterval(start: at(day, 18), end: at(day, 18, 45), title: "Easy run", sessionDate: day, eventID: "x")
    let scheduled = schedule(run, busy: work + [added], habits: habits)
    check(scheduled.scheduled == added, "Stride's own event counts as scheduled")
    check(scheduled.best?.start == at(day, 18), "the session's own event doesn't block its time")

    let late = schedule(run, busy: [], now: at(day, 20, 30))
    check(late.slots.isEmpty && late.note?.hasPrefix("Too late today") == true, "too late today: \(late.note ?? "-")")

    var hard = run
    hard.intensity = .hard
    var lateWindow = settings
    lateWindow.earliestMinute = 19 * 60
    lateWindow.latestMinute = 22 * 60
    let lateHard = schedule(hard, busy: [], settings: lateWindow)
    check(lateHard.best?.start == at(day, 19), "hard sessions prefer finishing early in the evening")

    let line = SessionScheduler.availabilityLine(
        date: day, label: "Tue", busy: work, forecast: forecast(day: day, rainHours: 15...18), settings: settings, compact: false, now: now, calendar: calendar
    )
    check(line.contains("h free: 06:00–08:45, 17:15–21:00") && line.contains("rain likely 15–19"), "availability line: \(line)")

    let demoBusy = DemoSchedule.busy(), demoForecast = DemoSchedule.forecast()
    let today = calendar.startOfDay(for: .now)
    let demoDays = (1...7).map { offset in
        SessionScheduler.schedule(
            date: calendar.date(byAdding: .day, value: offset, to: today)!, session: run, busy: demoBusy, forecast: demoForecast,
            settings: settings, habits: .none, calendar: calendar
        )
    }
    check(demoDays.filter { !$0.slots.isEmpty }.count >= 6, "demo calendar leaves time on most days")
    for day in demoDays.prefix(3) {
        let best = day.best.map { "\(time($0.start)) score \(Int($0.score)) \(($0.weather.map { [$0.summary] } ?? []) + $0.reasons + $0.warnings)" } ?? day.note ?? "-"
        print("  \(PromptBuilder.dayLabel(day.date, calendar: calendar)): \(best)")
    }

    let decoded = try? JSONDecoder().decode(ScheduleSettings.self, from: Data("{\"suggestTimes\":true}".utf8))
    check(decoded?.suggestTimes == true && decoded?.latestMinute == 21 * 60, "old schedule settings decode with defaults")
}

func checkForecastParsing() {
    section("Open-Meteo")
    let json = """
    {"hourly":{"time":[1761548400,1761552000],"temperature_2m":[8.4,null],"apparent_temperature":[6.1,null],
      "precipitation_probability":[40,90],"precipitation":[0.2,3],"weather_code":[61,95],"wind_speed_10m":[14,30],"uv_index":[0.5,0]},
     "daily":{"time":[1761516000],"sunrise":[1761545400],"sunset":[1761582000]}}
    """
    do {
        let forecast = try OpenMeteo.parse(Data(json.utf8), placeName: "Berlin")
        check(forecast.hours.count == 1, "hours without a temperature are dropped")
        let hour = forecast.hours.first
        check(hour?.precipitationChance == 0.4 && hour?.condition == .rain && hour?.apparentTemperatureC == 6.1, "hour fields: \(String(describing: hour))")
        check(forecast.sun.first?.sunrise == Date(timeIntervalSince1970: 1761545400), "sunrise parsed")
    } catch {
        check(false, "forecast parses: \(error)")
    }
    let url = OpenMeteo.url(latitude: 52.520008, longitude: 13.404954, days: 8).absoluteString
    check(url.contains("latitude=52.52&") && url.contains("longitude=13.40&"), "location is rounded: \(url)")
    check(SkyCondition.wmo(95) == .thunderstorm && SkyCondition.wmo(2) == .partlyCloudy, "WMO codes")
}

func checkAthletePlan() async {
    section("Athlete's own plan")
    let scenario = Scenario.demoWithHistory()
    let calendar = scenario.calendar
    let coach = scenario.history.plannedDay(on: scenario.day(0), calendar: calendar)
    let own = PlannedDay(day: scenario.label(0), sport: "Cycling", intensity: .easy, session: "Spin", durationMinutes: 30, targetZone: 1, details: "")
    let plan = TrainingPlan(analyses: scenario.history, athleteDays: [AthletePlanDay(date: scenario.day(0), day: own, savedAt: .now)])
    check(plan.plannedDay(on: scenario.day(0), calendar: calendar) == own, "the athlete's day wins")
    check(plan.coachDay(on: scenario.day(0), calendar: calendar) == coach, "the coach's day is still there")
    check(plan.plannedDay(on: scenario.day(-1), calendar: calendar) == scenario.history.plannedDay(on: scenario.day(-1), calendar: calendar), "other days come from the coach")

    // A pinned day in the next plan: in the prompt, and kept through a repair that changes it.
    let tomorrow = PlannedDay(day: scenario.label(1), sport: "Running", intensity: .hard, session: "Hill repeats", durationMinutes: 50, targetZone: 4, details: "With the club")
    let athleteDays = [AthletePlanDay(date: scenario.day(1), day: tomorrow, savedAt: .now)]
    let prompt = PromptBuilder(
        snapshot: scenario.snapshot, metrics: scenario.metrics, profile: scenario.profile, planStart: scenario.planStart, compact: true,
        history: scenario.history, athleteDays: athleteDays, availability: ["\(scenario.label(1)) | 2.0 h free"], calendar: calendar
    ).prompt
    check(prompt.contains("THE ATHLETE'S OWN PLAN") && prompt.contains("\(scenario.label(1)) | Hill repeats"), "pinned day in the prompt")
    check(prompt.contains("FREE TIME") && prompt.contains("2.0 h free"), "free time in the prompt")

    let pinned = TrainingPlan(analyses: [], athleteDays: athleteDays).pinnedDays(start: scenario.planStart, calendar: calendar)
    check(pinned.keys.sorted() == [0], "pinned by position: \(pinned.keys.sorted())")
    let labels = scenario.planLabels
    func day(_ index: Int, _ intensity: SessionIntensity, _ minutes: Int) -> PlannedDay {
        PlannedDay(day: labels[index], sport: intensity == .rest ? PlannedDay.rest : "Running", intensity: intensity, session: "x", durationMinutes: minutes, targetZone: 0, details: "")
    }
    // The model plans an easy day over the athlete's hard one, and a hard day right after it.
    let generated = [day(0, .easy, 40), day(1, .hard, 50), day(2, .rest, 0), day(3, .easy, 40), day(4, .rest, 0), day(5, .moderate, 60), day(6, .rest, 0)]
    var report = AnalysisReport(headline: "", trainingStatus: .productive, assessment: "", insights: [], recommendations: [], goalOutlook: "", weekPlan: generated)
    var called = false
    let left = await PlanRepair.run(&report, labels: labels, profile: scenario.profile, pinned: pinned) { _, _ in
        called = true
        return WeekPlan(days: generated)
    }
    check(report.weekPlan[0].session == "Hill repeats" && report.weekPlan[0].day == labels[0], "the athlete's day survives the fixes")
    check(left.problems.isEmpty && report.weekPlan[1].intensity == .easy && !called, "code eases the day after it, without the model: \(left)")
    let repairPrompt = PlanRepair.prompt(plan: report.weekPlan, problems: ["x"], profile: scenario.profile, reasoning: "", pinnedLabels: [labels[0]])
    check(repairPrompt.contains("planned \(labels[0]) themselves"), "the repair prompt names the athlete's days")
}
