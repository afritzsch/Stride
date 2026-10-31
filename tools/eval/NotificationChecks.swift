import Foundation

// What Stride notifies about while the app is closed, and the words: no UserNotifications, no HealthKit.

func checkNotifications() {
    section("Notifications")
    checkReadinessNotification()
    checkWorkoutNotifications()
    checkSessionReminders()

    var log = NotificationLog()
    for index in 0..<(NotificationLog.capacity + 50) { log.insert("key-\(index)") }
    log.insert("key-\(NotificationLog.capacity + 49)")
    check(log.keys.count == NotificationLog.capacity, "log is bounded: \(log.keys.count)")
    check(log.contains("key-\(NotificationLog.capacity + 49)") && !log.contains("key-0"), "log keeps the newest keys")
}

private let tempo = PlannedDay(day: "", sport: Sport.running, intensity: .hard, session: "Tempo run", durationMinutes: 50, targetZone: 4, details: "")
private let easyRun = PlannedDay(day: "", sport: Sport.running, intensity: .easy, session: "Easy run", durationMinutes: 45, targetZone: 2, details: "")
private let gym = PlannedDay(day: "", sport: Sport.strength, intensity: .moderate, session: "Gym", durationMinutes: 45, targetZone: 0, details: "")
private let rest = PlannedDay(day: "", sport: PlannedDay.rest, intensity: .rest, session: "Rest", durationMinutes: 0, targetZone: 0, details: "")

private func checkReadinessNotification() {
    var scenario = Scenario.demoWithHistory()
    let calendar = scenario.calendar
    let today = scenario.today
    scenario.snapshot.workouts.removeAll { calendar.isDate($0.start, inSameDayAs: today) }
    let metrics = scenario.metrics
    let morning = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: today)!
    func readiness(_ snapshot: HealthSnapshot) -> Readiness {
        Readiness(snapshot: snapshot, metrics: metrics, profile: scenario.profile, calendar: calendar)
    }
    func message(
        _ snapshot: HealthSnapshot? = nil, planned: PlannedDay? = tempo, log: NotificationLog = NotificationLog(), at now: Date? = nil
    ) -> NotificationMessage? {
        let snapshot = snapshot ?? scenario.snapshot
        return NotificationPlanner.readiness(readiness(snapshot), snapshot: snapshot, planned: planned, log: log, now: now ?? morning, calendar: calendar)
    }

    let low = readiness(scenario.snapshot)
    guard let sent = message() else {
        check(false, "low readiness with a planned session notifies (readiness \(low.level), \(low.signals.map(\.text)))")
        return
    }
    print("  readiness: \(sent.title) | \(sent.subtitle) | \(sent.body)")
    check(sent.kind == .readiness && sent.route == "dashboard" && sent.fireDate == nil, "readiness opens the dashboard right away")
    check(sent.id == NotificationPlanner.readinessKey(morning, calendar: calendar), "keyed by day: \(sent.id)")
    check(sent.title == (low.level == .low ? "Take it easy today" : "Train with care today"), "title follows the level: \(sent.title)")
    check(low.signals.prefix(3).allSatisfy { sent.body.contains($0.text) }, "body carries the measured signals")
    check(sent.subtitle == "Planned: Tempo run, 50 min, zone 4", "subtitle names the planned session: \(sent.subtitle)")
    check(!sent.body.contains("{") && !sent.body.contains("nil"), "no placeholders in the body")

    var log = NotificationLog()
    log.insert(sent.id)
    check(message(log: log) == nil, "readiness notifies once a day")
    let tomorrowMorning = calendar.date(byAdding: .day, value: 1, to: morning)!
    check(NotificationPlanner.readinessKey(tomorrowMorning, calendar: calendar) != sent.id, "a new day has a new key")
    check(message(at: calendar.date(bySettingHour: 3, minute: 0, second: 0, of: today)!) == nil, "not at 3 a.m.")
    check(message(at: calendar.date(bySettingHour: 15, minute: 0, second: 0, of: today)!) == nil, "not in the afternoon")
    check(message(planned: rest) == nil, "not on a rest day")
    check(message(planned: nil) == nil, "not without a plan")

    var trained = scenario.snapshot
    trained.workouts.append(WorkoutSummary(id: UUID(), start: calendar.date(bySettingHour: 6, minute: 0, second: 0, of: today)!, durationMinutes: 40, sport: Sport.running, sourceName: "Garmin"))
    check(message(trained) == nil, "not once today's session is recorded")

    var rested = scenario.snapshot
    if let index = rested.days.firstIndex(where: { $0.date == today }) {
        rested.days[index].restingHeartRate = metrics.indicators.restingHR28
        rested.days[index].hrvMs = metrics.indicators.hrv28
    }
    if let index = rested.sleep.firstIndex(where: { $0.date == today }) { rested.sleep[index].asleepHours = 8.5 }
    let restedReadiness = readiness(rested)
    check(!restedReadiness.suggestsAdjusting || message(rested) != nil, "notifies exactly when readiness suggests adjusting")
    if !restedReadiness.suggestsAdjusting { check(message(rested) == nil, "rested: no notification") }

    var notSynced = scenario.snapshot
    if let index = notSynced.days.firstIndex(where: { $0.date == today }) {
        notSynced.days[index].restingHeartRate = nil
        notSynced.days[index].hrvMs = nil
    }
    notSynced.sleep.removeAll { $0.date == today }
    check(message(notSynced) == nil, "not before this morning's numbers are in (load alone doesn't speak for today)")
}

private func checkWorkoutNotifications() {
    let now = Date(timeIntervalSince1970: 1_793_000_000)
    func workout(endingAgo hours: Double, sport: String = Sport.running, minutes: Double = 45, km: Double? = 8.2) -> WorkoutSummary {
        WorkoutSummary(
            id: UUID(), start: now.addingTimeInterval(-hours * 3600 - minutes * 60), durationMinutes: minutes, sport: sport,
            distanceKm: km, averageHeartRate: 148, sourceName: "Garmin"
        )
    }
    let run = workout(endingAgo: 1)
    let messages = NotificationPlanner.newWorkouts([run], log: NotificationLog(), now: now)
    check(messages.count == 1, "a workout that just synced notifies")
    if let message = messages.first {
        print("  workout: \(message.title) | \(message.body)")
        check(message.title == "Your run is in", "title names the sport: \(message.title)")
        check(message.body.contains("45 min") && message.body.contains("8.2 km") && message.body.contains("5:29 /km"), "body has duration, distance and pace: \(message.body)")
        check(message.body.hasSuffix("Tap for the coach review."), "body asks for the tap")
        check(message.route == "review:\(run.id.uuidString)" && message.id == NotificationPlanner.workoutKey(run.id), "opens that workout's review")
    }
    var log = NotificationLog()
    log.insert(NotificationPlanner.workoutKey(run.id))
    check(NotificationPlanner.newWorkouts([run], log: log, now: now).isEmpty, "each workout notifies once")
    check(NotificationPlanner.newWorkouts([workout(endingAgo: 30)], log: NotificationLog(), now: now).isEmpty, "old workouts aren't news")
    check(NotificationPlanner.newWorkouts([workout(endingAgo: -0.2)], log: NotificationLog(), now: now).isEmpty, "not before the workout ends")
    let backlog = (1...4).map { workout(endingAgo: Double($0)) }
    let batch = NotificationPlanner.newWorkouts(backlog, log: NotificationLog(), now: now)
    check(batch.count == NotificationPlanner.newWorkoutBatch, "a backlog is capped: \(batch.count)")
    check(batch.map(\.route) == [backlog[1], backlog[0]].map { "review:\($0.id.uuidString)" }, "the newest of a backlog, oldest first")

    let lift = NotificationPlanner.workoutMessage(workout(endingAgo: 1, sport: Sport.strength, km: nil))
    check(lift.title == "Your strength session is in" && !lift.body.contains("km"), "strength: \(lift.title) | \(lift.body)")
    check(NotificationPlanner.noun(for: "Yoga") == "yoga session" && NotificationPlanner.noun(for: Sport.other) == "workout", "other sports read naturally")
    let ride = NotificationPlanner.workoutMessage(workout(endingAgo: 1, sport: Sport.cycling, minutes: 90, km: 40))
    check(ride.title == "Your ride is in" && !ride.body.contains("/km"), "rides show no running pace: \(ride.body)")
}

private func checkSessionReminders() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3))!
    let now = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today)!
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
    func at(_ day: Date, _ hour: Int, _ minute: Int = 0) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)! }
    func session(_ day: Date, _ hour: Int, minutes: Int = 45) -> BusyInterval {
        BusyInterval(start: at(day, hour), end: at(day, hour).addingTimeInterval(TimeInterval(minutes * 60)), title: "Stride", sessionDate: day, eventID: "e")
    }
    let rainy = WeatherForecast(
        fetchedAt: now, source: .openMeteo, placeName: nil,
        hours: (0..<48).map { offset in
            let date = today.addingTimeInterval(TimeInterval(offset * 3600))
            let wet = calendar.component(.hour, from: date) >= 17
            return HourlyWeather(
                date: date, temperatureC: 9, apparentTemperatureC: 7, precipitationChance: wet ? 0.7 : 0.1, precipitationMm: wet ? 1.5 : 0,
                windKph: 12, uvIndex: 0, condition: wet ? .rain : .cloudy
            )
        },
        sun: []
    )
    var plan: [Date: PlannedDay] = [today: easyRun, tomorrow: easyRun]
    func reminders(_ sessions: [BusyInterval], workouts: [WorkoutSummary] = [], lead: Int = 30, at time: Date = now) -> [NotificationMessage] {
        NotificationPlanner.sessionReminders(
            sessions: sessions, plannedOn: { plan[$0] }, workouts: workouts, forecast: rainy, leadMinutes: lead, now: time, calendar: calendar
        )
    }

    let evening = reminders([session(tomorrow, 18)])
    check(evening.count == 1, "a session in the calendar gets a reminder")
    if let reminder = evening.first {
        print("  session: \(reminder.title) | \(reminder.body)")
        check(reminder.fireDate == at(tomorrow, 17, 30), "30 min before the start")
        check(reminder.title == "Easy run at 18:00", "title has session and time: \(reminder.title)")
        check(reminder.body.hasPrefix("In 30 min: Easy run, 45 min, zone 2.") && reminder.body.contains("rain 70%"), "body has the session and the rain: \(reminder.body)")
        check(reminder.id == "session-2026-11-04" && reminder.route == "plan", "keyed by day, opens the plan")
    }
    let moved = reminders([session(tomorrow, 7)])
    check(moved.first?.id == evening.first?.id && moved.first?.fireDate == at(tomorrow, 6, 30), "a moved session keeps its key (the reminder is replaced)")
    check(moved.first.map { $0.body.contains("dry") } ?? false, "the forecast follows the new time: \(moved.first?.body ?? "-")")
    check(reminders([session(tomorrow, 18)], lead: 60).first?.fireDate == at(tomorrow, 17), "lead time from the settings")

    plan[tomorrow] = gym
    check(reminders([session(tomorrow, 18)]).first.map { !$0.body.contains("Forecast") } ?? false, "indoor sessions get no forecast")
    plan[tomorrow] = rest
    check(reminders([session(tomorrow, 18)]).isEmpty, "no reminder once the day became a rest day")
    plan[tomorrow] = nil
    check(reminders([session(tomorrow, 18)]).isEmpty, "no reminder without a planned session")
    plan[tomorrow] = easyRun

    check(reminders([session(today, 9)]).isEmpty, "no reminder whose time has passed")
    check(reminders([session(today, 9, minutes: 45)], at: at(today, 8)).count == 1, "a reminder still ahead is kept")
    let done = WorkoutSummary(id: UUID(), start: at(today, 7), durationMinutes: 40, sport: Sport.running, sourceName: "Garmin")
    check(reminders([session(today, 18)], workouts: [done]).isEmpty, "no reminder on a day already trained")
    check(reminders([BusyInterval(start: at(tomorrow, 9), end: at(tomorrow, 17), title: "Work")]).isEmpty, "other calendar events get none")
    let farDay = calendar.date(byAdding: .day, value: NotificationPlanner.reminderDays + 1, to: today)!
    plan[farDay] = easyRun
    check(reminders([session(farDay, 18)]).isEmpty, "only the next \(NotificationPlanner.reminderDays) days")
    let both = reminders([session(tomorrow, 18), session(today, 17)])
    check(both.map(\.id) == ["session-2026-11-03", "session-2026-11-04"], "sorted by time")
}
