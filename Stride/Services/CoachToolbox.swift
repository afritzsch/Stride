import Foundation

/// What the coach's tools can read and change, on the main actor where the app's state lives. Each method answers
/// with plain text for the model; without a chat, tools run silently (the debug state dump uses this).
@MainActor
final class CoachToolbox: CoachToolAnswering {
    private weak var model: AppModel?
    private weak var chat: CoachChat?

    init(model: AppModel, chat: CoachChat?) {
        self.model = model
        self.chat = chat
    }

    private static let noData = "No health data is loaded."
    private static let scheduleOff = "Time suggestions are off. The athlete can turn them on in Settings under Calendar & weather."

    private func label(_ date: Date) -> String { PromptBuilder.dayLabel(date, calendar: .current) }

    // MARK: - Health data

    func recentDays(_ count: Int) -> String {
        chat?.setActivity("Looking at your recovery…")
        guard let snapshot = model?.snapshot, let metrics = model?.metrics else { return Self.noData }
        let sleep = Dictionary(snapshot.sleep.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let num = PromptBuilder.num
        let rows = snapshot.days.suffix(min(max(count, 1), 28)).map { day in
            [
                label(day.date),
                num(day.restingHeartRate, 0),
                num(day.hrvMs, 0),
                num(sleep[day.date]?.asleepHours, 1),
                num(day.steps, 0),
                num(metrics.dailyLoad[day.date] ?? 0, 0),
            ].joined(separator: " | ")
        }
        let ind = metrics.indicators
        return (["day | resting HR | HRV ms | sleep h | steps | load"] + rows + [
            "4-week averages: resting HR \(num(ind.restingHR28, 0)), HRV \(num(ind.hrv28, 0)) ms, sleep \(num(ind.sleep28, 1)) h. Load 7 d \(num(ind.acuteLoad, 0)), ACWR \(num(ind.acwr, 2)).",
        ]).joined(separator: "\n")
    }

    func workouts(days: Int, sport: String?) -> String {
        chat?.setActivity("Looking at your workouts…")
        guard let model, let metrics = model.metrics else { return Self.noData }
        let since = Calendar.current.date(byAdding: .day, value: -min(max(days, 1), 56), to: .now) ?? .now
        let sport = sport?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        func matches(_ workout: WorkoutSummary) -> Bool {
            guard let sport else { return true }
            return workout.sport.localizedCaseInsensitiveCompare(sport) == .orderedSame
        }
        let rows = model.workoutsNewestFirst.enumerated()
            .filter { $0.element.start >= since && matches($0.element) }
            .prefix(15)
            .map { number, workout in
                var parts = [
                    "#\(number + 1)",
                    label(workout.start),
                    workout.sport,
                    "\(PromptBuilder.num(workout.durationMinutes, 0)) min",
                ]
                if let km = workout.distanceKm { parts.append("\(PromptBuilder.num(km, 1)) km") }
                if let heartRate = workout.averageHeartRate { parts.append("avg HR \(PromptBuilder.num(heartRate, 0))") }
                parts.append("load \(PromptBuilder.num(metrics.workoutLoad[workout.id], 0))")
                if let review = model.runAnalyses[workout.id] { parts.append("reviewed: \(review.analysis.headline)") }
                return parts.joined(separator: " | ")
            }
        return rows.isEmpty ? "No matching workouts." : rows.joined(separator: "\n")
    }

    func workoutDetail(number: Int) async -> String {
        chat?.setActivity("Opening that workout…")
        guard let model, let snapshot = model.snapshot, let metrics = model.metrics,
              case let workouts = model.workoutsNewestFirst, workouts.indices.contains(number - 1)
        else { return "There's no workout #\(number). List workouts first." }
        let workout = workouts[number - 1]
        do {
            let detail = try await model.workoutDetail(for: workout)
            var brief = RunPromptBuilder(
                detail: detail, snapshot: snapshot, metrics: metrics, profile: model.profile,
                plannedSession: model.plannedSession(on: workout.start),
                note: model.runAnalyses[workout.id]?.note ?? "", compact: true,
                strengthSession: model.strength.session(for: workout), strengthHistory: model.strength.sessions ?? []
            ).prompt
            if let review = model.runAnalyses[workout.id] {
                brief += "\n\nYOUR EARLIER REVIEW: \(review.analysis.headline) " + review.analysis.summary.joined(separator: " ")
            }
            return brief
        } catch {
            return "Couldn't load that workout: \(error.localizedDescription)"
        }
    }

    /// Weekly and monthly rollups, run pace and heart rate per week, records and the goal: what a forecast needs.
    func trends() -> String {
        chat?.setActivity("Looking at your trends…")
        guard let model, let snapshot = model.snapshot, let metrics = model.metrics else { return Self.noData }
        let num = PromptBuilder.num
        var lines = weeklyTrendLines(snapshot: snapshot, metrics: metrics)
        let ind = metrics.indicators
        lines.append("Fitness (28-day load per week) \(num(ind.chronicLoad, 0)), last 7 days \(num(ind.acuteLoad, 0)), ACWR \(num(ind.acwr, 2)).")
        if let progress = model.progress { lines += longTermLines(progress) }

        let profile = model.profile
        if profile.hasGoal {
            let weeks = max(0, Calendar.current.dateComponents([.day], from: .now, to: profile.goalDate).day ?? 0) / 7
            lines.append("GOAL: \(PromptBuilder.goalTitle(profile)), \(weeks) weeks away\(profile.goalTarget.isEmpty ? "" : ", target \(profile.goalTarget)")")
        } else {
            lines.append("GOAL: none set.")
        }
        return lines.joined(separator: "\n")
    }

    private func weeklyTrendLines(snapshot: HealthSnapshot, metrics: MetricsReport) -> [String] {
        let calendar = Calendar.current
        let num = PromptBuilder.num
        var lines = ["WEEKLY (week starting | sessions | minutes | km | load | run km | run pace /km | run avg HR | RHR | HRV)"]
        for week in metrics.weeks.suffix(8) {
            let end = calendar.date(byAdding: .day, value: 7, to: week.weekStart) ?? week.weekStart
            let runs = snapshot.workouts.filter { $0.sport == Sport.running && $0.start >= week.weekStart && $0.start < end }
            let measured = runs.filter { ($0.distanceKm ?? 0) > 0 }
            let runKm = measured.compactMap(\.distanceKm).reduce(0, +)
            let pace = runKm > 0 ? measured.map(\.durationMinutes).reduce(0, +) * 60 / runKm : nil
            let withHR = runs.compactMap { run in run.averageHeartRate.map { (hr: $0, minutes: run.durationMinutes) } }
            let hrMinutes = withHR.map(\.minutes).reduce(0, +)
            let runHR = hrMinutes > 0 ? withHR.map { $0.hr * $0.minutes }.reduce(0, +) / hrMinutes : nil
            lines.append([
                label(week.weekStart) + (end > snapshot.fetchedAt ? " (in progress)" : ""),
                "\(week.sessions)",
                num(week.trainingMinutes, 0),
                num(week.distanceKm, 1),
                num(week.load, 0),
                num(runKm, 1),
                pace.map { WorkoutFormat.pace($0) } ?? "–",
                num(runHR, 0),
                num(week.avgRestingHR, 0),
                num(week.avgHRV, 0),
            ].joined(separator: " | "))
        }
        return lines
    }

    /// Six months of totals and the records, from the long history.
    private func longTermLines(_ progress: ProgressReport) -> [String] {
        let calendar = Calendar.current
        let num = PromptBuilder.num
        var lines: [String] = []
        let months = progress.buckets(.trainingTime, granularity: .month, count: 6)
        if months.count > 1 {
            lines.append("MONTHLY (month | hours | km | run km | load | RHR | HRV)")
            for month in months {
                let end = calendar.date(byAdding: .month, value: 1, to: month.start) ?? month.start
                func value(_ metric: ProgressMetric) -> String {
                    num(progress.value(metric, from: month.start, to: end), metric.digits)
                }
                lines.append([
                    month.start.formatted(.dateTime.month(.abbreviated).year()),
                    num(month.value, 1), value(.distance), value(.runDistance), value(.load), value(.restingHR), value(.hrv),
                ].joined(separator: " | "))
            }
        }
        if !progress.records.isEmpty {
            lines.append("RECORDS: " + progress.records.map { "\($0.title) \($0.value) (\(label($0.date)))" }.joined(separator: "; "))
        }
        return lines
    }

    /// `month` 1–12 is that month's next occurrence (the goal date if it falls in it); 0 is the goal date, or today.
    func raceForecast(distance: String, month: Int) -> String {
        chat?.setActivity("Estimating your race time…")
        guard let model, let snapshot = model.snapshot else { return Self.noData }
        guard let km = RaceForecast.distances.first(where: { $0.name.localizedCaseInsensitiveCompare(distance) == .orderedSame })?.km else {
            return "Unknown distance \(distance). Use one of: \(RaceForecast.distances.map(\.name).joined(separator: ", "))."
        }
        let calendar = Calendar.current
        let profile = model.profile
        let goal = profile.hasGoal && profile.goalDate > .now ? profile.goalDate : nil
        var date = goal ?? .now
        if (1...12).contains(month) {
            if let goal, calendar.component(.month, from: goal) == month {
                date = goal
            } else {
                date = calendar.nextDate(after: .now, matching: DateComponents(month: month, day: 15), matchingPolicy: .nextTime) ?? .now
            }
        }
        guard let forecast = RaceForecast.make(distanceKm: km, raceDate: date, workouts: snapshot.workouts, experience: profile.experience) else {
            return "No runs of 3 km or more with distance in the last 8 weeks, so there's nothing to base a race time on. Tell the athlete that."
        }
        return forecast.brief
    }

    // MARK: - Plan

    func plan() -> String {
        chat?.setActivity("Checking your plan…")
        guard let model else { return "No plan." }
        let rows = Self.days(7).enumerated().map { offset, date -> String in
            let marker = [0: " (today)", 1: " (tomorrow)"][offset] ?? ""
            guard let day = model.plannedSession(on: date) else { return "\(label(date))\(marker) | no plan" }
            return "\(label(date))\(marker) | \(day.briefDescription) | \(day.details)"
        }
        var lines = ["COMING DAYS (day | session | details)"] + rows
        if let adherence = model.planAdherence?.completed, !adherence.isEmpty {
            lines.append("LAST 7 DAYS: \(PlanAdherence.summary(of: adherence))")
            lines += adherence.filter { $0.status != .done && $0.status != .rested }.map { day in
                "\(label(day.date)): planned \(day.planned.isRest ? "rest" : day.planned.session), \(([day.status.title.lowercased()] + day.notes).joined(separator: "; "))"
            }
        }
        return lines.joined(separator: "\n")
    }

    func changePlanDay(_ day: PlannedDay) -> String {
        chat?.setActivity("Updating your plan…")
        guard let model else { return "No plan." }
        let week = Self.days(7)
        guard let date = week.first(where: { label($0) == day.day }) else {
            return "\(day.day) isn't one of the next 7 days. Use a label from the plan tool, e.g. \(label(.now))."
        }
        var day = PlanCheck.normalized([day], labels: [day.day])[0]
        day.day = label(date)
        // Saved as the athlete's own day: they asked for it, so the next weekly plan keeps it.
        let previous = model.trainingPlan.athleteDay(on: date)?.day
        model.setAthleteDay(day, on: date)
        chat?.change("Plan changed: \(day.day) is now \(day.isRest ? "a rest day" : "\(day.session), \(day.durationMinutes) min").") { [weak model] in
            if let previous { model?.setAthleteDay(previous, on: date) } else { model?.removeAthleteDay(on: date) }
        }

        // Check the week around the change against the athlete's limits and recent training.
        let plan = week.compactMap { model.plannedSession(on: $0) }
        let labels = week.map(label)
        let context = model.metrics.map { PlanContext(metrics: $0, profile: model.profile, planStart: week[0]) }
        let problems = plan.count == 7 ? PlanCheck.problems(plan, labels: labels, profile: model.profile, context: context) : []
        return problems.isEmpty
            ? "Saved \(day.day): \(day.briefDescription)."
            : "Saved \(day.day): \(day.briefDescription). The next 7 days now break these rules: \(problems.joined(separator: " ")) Tell the athlete, and fix it if they agree."
    }

    // MARK: - Calendar and weather

    func freeTimes(day label: String) -> String {
        chat?.setActivity("Checking your calendar…")
        guard let schedule = model?.schedule else { return "No calendar." }
        guard schedule.isActive else { return Self.scheduleOff }
        guard let dates = comingDates(matching: label) else { return "\(label) isn't today or one of the next 7 days. Use a label from getPlan." }
        let time = { (date: Date) in SessionScheduler.time(date, calendar: .current) }
        let rows = dates.compactMap { date -> String? in
            let dayLabel = self.label(date)
            guard let day = schedule.schedule(on: date) else { return dates.count == 1 ? "\(dayLabel) | no session planned" : nil }
            var parts = [dayLabel, day.session.briefDescription]
            if let scheduled = day.scheduled { parts.append("in the calendar \(time(scheduled.start))–\(time(scheduled.end))") }
            if day.slots.isEmpty {
                parts.append(day.note ?? "no free time")
            } else {
                parts.append("best times: " + day.slots.map { slot in
                    let notes = [slot.weather?.summary].compactMap(\.self) + slot.reasons + slot.warnings
                    return "\(time(slot.start))–\(time(slot.end)) (\(notes.joined(separator: ", ")))"
                }.joined(separator: "; "))
            }
            return parts.joined(separator: " | ")
        }
        return rows.isEmpty ? "No sessions planned in the coming days." : (["day | session | calendar and times, best first"] + rows).joined(separator: "\n")
    }

    func weather(day label: String) -> String {
        chat?.setActivity("Checking the weather…")
        guard let forecast = model?.schedule.forecast else { return "No forecast: weather is off or not loaded yet." }
        guard let dates = comingDates(matching: label) else { return "\(label) isn't today or one of the next 7 days." }
        let calendar = Calendar.current
        let num = PromptBuilder.num
        // Three days for all coming days, otherwise the one asked for.
        let shown = dates.prefix(dates.count > 1 ? 3 : 1)
        var lines: [String] = []
        for date in shown {
            var line = self.label(date)
            if let sun = forecast.sun(on: date, calendar: calendar) {
                line += " (sunrise \(SessionScheduler.time(sun.sunrise, calendar: calendar)), sunset \(SessionScheduler.time(sun.sunset, calendar: calendar)))"
            }
            lines.append(line)
            for hour in forecast.hours where calendar.isDate(hour.date, inSameDayAs: date) && calendar.component(.hour, from: hour.date) % 3 == 0 {
                let clock = calendar.component(.hour, from: hour.date)
                guard (6...21).contains(clock) else { continue }
                lines.append("  \(SessionScheduler.clock(clock * 60)) \(num(hour.temperatureC, 0)) °C (feels \(num(hour.apparentTemperatureC, 0))), rain \(num(hour.precipitationChance * 100, 0))%, wind \(num(hour.windKph, 0)) km/h, \(hour.condition.title.lowercased())")
            }
        }
        // Only the day headers: no hours fell on those days.
        return lines.count <= shown.count ? "The forecast doesn't reach that day yet." : lines.joined(separator: "\n")
    }

    func scheduleSession(day label: String, start: String) -> String {
        chat?.setActivity("Adding it to your calendar…")
        guard let model else { return "No calendar." }
        let schedule = model.schedule
        guard schedule.isActive else { return Self.scheduleOff }
        guard let date = comingDates(matching: label)?.first, !label.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "\(label) isn't today or one of the next 7 days. Use a label from getPlan."
        }
        let calendar = Calendar.current
        let parts = start.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]),
              let startDate = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date) else {
            return "Give the start as HH:mm, e.g. 07:30."
        }
        guard let session = model.plannedSession(on: date), !session.isRest else {
            return "Nothing is planned on \(label). Change the plan first."
        }
        guard startDate > .now else { return "\(start) on \(label) has already passed." }
        let end = startDate.addingTimeInterval(TimeInterval(max(session.durationMinutes, 15) * 60))
        if let clash = schedule.busy.first(where: { !$0.isSession && $0.start < end && $0.end > startDate }) {
            return "That overlaps \(clash.title.isEmpty ? "an event" : clash.title) (\(SessionScheduler.time(clash.start, calendar: calendar))–\(SessionScheduler.time(clash.end, calendar: calendar))). Pick a time from freeTimes."
        }
        let day = calendar.startOfDay(for: date)
        let previousStart = schedule.busy.first { $0.sessionDate == day }?.start
        do {
            try schedule.add(session, on: date, at: startDate)
        } catch {
            return "Couldn't add it: \(error.localizedDescription)"
        }
        let range = "\(SessionScheduler.time(startDate, calendar: calendar))–\(SessionScheduler.time(end, calendar: calendar))"
        chat?.change("Added to your calendar: \(session.session), \(label) \(range).") { [weak model] in
            guard let model else { return }
            do {
                if let previousStart { try model.schedule.add(session, on: date, at: previousStart) } else { try model.schedule.removeSession(on: date) }
            } catch {
                model.debugLog("Undoing the calendar change failed: \(error)")
            }
        }
        return "Added \(session.session) on \(label) \(range) to the athlete's calendar."
    }

    // MARK: - Days

    /// Midnight of today and the `count - 1` days after it.
    private static func days(_ count: Int) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    /// Today and the next 7 days whose label matches, or all of them for an empty label.
    private func comingDates(matching label: String) -> [Date]? {
        let dates = Self.days(8)
        let label = label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return dates }
        let matching = dates.filter { self.label($0).caseInsensitiveCompare(label) == .orderedSame }
        return matching.isEmpty ? nil : matching
    }
}
