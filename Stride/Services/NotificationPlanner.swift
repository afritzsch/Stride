import Foundation

/// The kinds of local notification Stride sends, each with its own switch in Settings.
nonisolated enum NotificationKind: String, Codable, CaseIterable, Sendable {
    case readiness, workout, session
}

/// One local notification, decided and worded in code: Foundation Models doesn't run reliably in the background,
/// so no model text ever goes into a notification.
nonisolated struct NotificationMessage: Hashable, Sendable {
    /// Request identifier and dedupe key, e.g. "readiness-2026-10-31" or "workout-<uuid>".
    var id: String
    var kind: NotificationKind
    var title: String
    /// A second bold line under the title (shown even when the body is cut short in a banner), or "".
    var subtitle = ""
    var body: String
    /// Where a tap opens, in the same form as the debug `-route` argument (`AppModel.open(route:)`).
    var route: String
    /// nil delivers right away; otherwise at this time (session reminders).
    var fireDate: Date?
}

/// Which notifications are on, and how early a session reminder comes.
nonisolated struct NotificationSettings: Equatable, Sendable {
    var readiness = false
    var newWorkouts = false
    var sessionReminders = false
    var reminderLeadMinutes = 30

    static let leadChoices = [10, 15, 30, 45, 60, 90]

    var anyOn: Bool { readiness || newWorkouts || sessionReminders }

    func isOn(_ kind: NotificationKind) -> Bool {
        switch kind {
        case .readiness: readiness
        case .workout: newWorkouts
        case .session: sessionReminders
        }
    }
}

/// Keys of notifications already sent (or deliberately skipped because the app was open), so each workout and
/// each morning notifies at most once. Newest last, bounded.
nonisolated struct NotificationLog: Codable, Equatable, Sendable {
    static let capacity = 200
    private(set) var keys: [String] = []

    func contains(_ key: String) -> Bool { keys.contains(key) }

    mutating func insert(_ key: String) {
        guard !contains(key) else { return }
        keys = Array((keys + [key]).suffix(Self.capacity))
    }
}

/// Decides what to notify about and words it. Pure: the app feeds it a snapshot, the plan and the calendar, and
/// posts what comes back (`AppModel+Background`).
nonisolated enum NotificationPlanner {
    /// The morning notification only goes out in this window (local hours), so a 3 a.m. sync with half a night
    /// of sleep doesn't speak for the day.
    static let morningHours = 5..<14
    /// New-workout notifications only for workouts that ended this recently; older ones were missed, not new.
    static let newWorkoutWindow: TimeInterval = 12 * 3600
    /// At most this many new-workout notifications per wake; a backlog after days offline isn't news.
    static let newWorkoutBatch = 2
    /// Session reminders are scheduled for this many days ahead (the calendar is read for 9).
    static let reminderDays = 8

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func readinessKey(_ date: Date, calendar: Calendar) -> String { "readiness-" + dayKey(date, calendar: calendar) }
    static func workoutKey(_ id: UUID) -> String { "workout-" + id.uuidString }
    static func sessionKey(_ day: Date, calendar: Calendar) -> String { "session-" + dayKey(day, calendar: calendar) }

    // MARK: - Morning readiness

    /// This morning's readiness notification: when readiness is down, a session is planned and nothing is recorded
    /// yet today, once per day, in the morning, and only once this morning's own numbers (sleep, resting HR or HRV)
    /// are in, so yesterday's numbers don't speak for today.
    static func readiness(
        _ readiness: Readiness, snapshot: HealthSnapshot, planned: PlannedDay?, log: NotificationLog,
        now: Date, calendar: Calendar = .current
    ) -> NotificationMessage? {
        guard readiness.suggestsAdjusting, let planned, !planned.isRest,
              morningHours.contains(calendar.component(.hour, from: now)),
              !log.contains(readinessKey(now, calendar: calendar)),
              hasMorningData(snapshot, now: now, calendar: calendar),
              !snapshot.workouts.contains(where: { calendar.isDate($0.start, inSameDayAs: now) })
        else { return nil }
        return readinessMessage(readiness, planned: planned, now: now, calendar: calendar)
    }

    static func hasMorningData(_ snapshot: HealthSnapshot, now: Date, calendar: Calendar) -> Bool {
        let today = calendar.startOfDay(for: now)
        let day = snapshot.days.first { $0.date == today }
        return snapshot.sleep.contains { $0.date == today } || day?.restingHeartRate != nil || day?.hrvMs != nil
    }

    /// The words, given readiness and the planned session (also used by the debug hook).
    static func readinessMessage(_ readiness: Readiness, planned: PlannedDay, now: Date, calendar: Calendar = .current) -> NotificationMessage {
        // The signal texts carry the numbers against the baselines, e.g. "Resting HR 58 bpm, 6 above your 4-week average".
        let signals = readiness.signals.prefix(3).map(\.text)
        let numbers = signals.isEmpty ? "Your recovery numbers are off this morning." : signals.joined(separator: ". ") + "."
        let title = readiness.level == .low ? "Take it easy today" : "Train with care today"
        // The plan goes in the subtitle: a banner shows only the start of the body.
        return NotificationMessage(
            id: readinessKey(now, calendar: calendar), kind: .readiness, title: title, subtitle: "Planned: \(sessionLine(planned))",
            body: "\(numbers) Tap to see a lighter option.", route: "dashboard", fireDate: nil
        )
    }

    // MARK: - New workouts

    /// Workouts that ended within `newWorkoutWindow` and haven't been notified (or seen in the app), oldest first.
    static func newWorkouts(_ workouts: [WorkoutSummary], log: NotificationLog, now: Date) -> [NotificationMessage] {
        let fresh = workouts
            .filter { end(of: $0) <= now && now.timeIntervalSince(end(of: $0)) <= newWorkoutWindow && !log.contains(workoutKey($0.id)) }
            .sorted { $0.start < $1.start }
        return fresh.suffix(newWorkoutBatch).map(workoutMessage)
    }

    static func end(of workout: WorkoutSummary) -> Date { workout.start.addingTimeInterval(workout.durationMinutes * 60) }

    static func workoutMessage(_ workout: WorkoutSummary) -> NotificationMessage {
        var facts = ["\(Int(workout.durationMinutes.rounded())) min"]
        if let km = workout.distanceKm, km >= 0.1 { facts.append(String(format: "%.1f km", km)) }
        if workout.kind == .endurance, let pace = workout.paceSecondsPerKm, workout.isFootSport, workout.distanceKm ?? 0 >= 1 {
            facts.append("\(WorkoutFormat.pace(pace)) /km")
        }
        if let hr = workout.averageHeartRate { facts.append("avg HR \(Int(hr.rounded()))") }
        return NotificationMessage(
            id: workoutKey(workout.id), kind: .workout,
            title: "Your \(noun(for: workout.sport)) is in",
            body: facts.joined(separator: " · ") + ". Tap for the coach review.",
            route: "review:\(workout.id.uuidString)", fireDate: nil
        )
    }

    /// "run" for Running: how an athlete would name the session.
    static func noun(for sport: String) -> String {
        let nouns = [
            Sport.running: "run", Sport.cycling: "ride", Sport.swimming: "swim", Sport.walking: "walk", Sport.hiking: "hike",
            "Rowing": "row", Sport.strength: "strength session",
        ]
        if let noun = nouns[sport] { return noun }
        return sport.isEmpty || sport == Sport.other ? "workout" : "\(sport.lowercased()) session"
    }

    // MARK: - Session reminders

    /// Reminders `leadMinutes` before each session Stride put in the calendar, for the next `reminderDays` days.
    /// A day that's now a rest day, or that already has a recorded workout, gets none; neither does a reminder
    /// whose time has passed. Outdoor sessions mention the forecast when there is one.
    static func sessionReminders(
        sessions: [BusyInterval], plannedOn: (Date) -> PlannedDay?, workouts: [WorkoutSummary],
        forecast: WeatherForecast?, leadMinutes: Int, now: Date, calendar: Calendar = .current
    ) -> [NotificationMessage] {
        let horizon = calendar.date(byAdding: .day, value: reminderDays, to: calendar.startOfDay(for: now)) ?? now
        return sessions.compactMap { event -> NotificationMessage? in
            guard let day = event.sessionDate, event.start < horizon else { return nil }
            let fire = event.start.addingTimeInterval(-TimeInterval(leadMinutes * 60))
            guard fire > now, let planned = plannedOn(day), !planned.isRest,
                  !workouts.contains(where: { calendar.isDate($0.start, inSameDayAs: day) })
            else { return nil }
            return sessionMessage(
                event, planned: planned, weather: weather(for: event, sport: planned.sport, forecast: forecast),
                leadMinutes: leadMinutes, fireDate: fire, calendar: calendar
            )
        }
        .sorted { ($0.fireDate ?? now) < ($1.fireDate ?? now) }
    }

    /// The forecast over an outdoor session, nil indoors or without forecast hours for that time.
    static func weather(for event: BusyInterval, sport: String, forecast: WeatherForecast?) -> SlotWeather? {
        guard SessionScheduler.isOutdoor(sport), let forecast else { return nil }
        let hours = forecast.hours(overlapping: DateInterval(start: event.start, end: max(event.end, event.start)))
        return hours.isEmpty ? nil : SessionScheduler.weather(over: hours)
    }

    static func sessionMessage(
        _ event: BusyInterval, planned: PlannedDay, weather: SlotWeather?, leadMinutes: Int, fireDate: Date?, calendar: Calendar = .current
    ) -> NotificationMessage {
        let day = event.sessionDate ?? calendar.startOfDay(for: event.start)
        var body = "In \(leadMinutes) min: \(sessionLine(planned))."
        if let weather { body += " Forecast \(weather.summary)" + (weather.windKph >= 30 ? ", wind \(Int(weather.windKph.rounded())) km/h" : "") + "." }
        return NotificationMessage(
            id: sessionKey(day, calendar: calendar), kind: .session,
            title: "\(planned.session) at \(SessionScheduler.time(event.start, calendar: calendar))",
            body: body, route: "plan", fireDate: fireDate
        )
    }

    /// "Tempo run, 50 min, zone 4".
    static func sessionLine(_ planned: PlannedDay) -> String {
        var parts = [planned.session.isEmpty ? planned.defaultTitle : planned.session]
        if planned.durationMinutes > 0 { parts.append("\(planned.durationMinutes) min") }
        if planned.targetZone > 0 { parts.append("zone \(planned.targetZone)") }
        return parts.joined(separator: ", ")
    }
}
