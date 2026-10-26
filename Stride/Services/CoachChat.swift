import Foundation
import FoundationModels
import Observation

/// One line of the coach conversation as the app shows it.
struct ChatMessage: Identifiable, Hashable {
    enum Role { case athlete, coach, notice }

    let id = UUID()
    var role: Role
    var text: String
}

/// A conversation with the on-device model, which looks data up through tools instead of getting it all up front,
/// so it fits the small context window.
@Observable
final class CoachChat {
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    /// What the coach is looking up right now, e.g. "Looking at your workouts…".
    private(set) var activity: String?
    var error: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var session: LanguageModelSession?

    init(model: AppModel) {
        self.model = model
    }

    func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding, let model else { return }
        if let blocker = AppleAnalyzer.onDeviceBlocker {
            error = blocker
            return
        }
        error = nil
        messages.append(ChatMessage(role: .athlete, text: text))
        isResponding = true
        defer {
            isResponding = false
            activity = nil
        }

        for attempt in 1...2 {
            let session = self.session ?? makeSession(model: model)
            self.session = session
            messages.append(ChatMessage(role: .coach, text: ""))
            let index = messages.count - 1
            do {
                for try await snapshot in session.streamResponse(to: text) {
                    activity = nil
                    messages[index].text = snapshot.content
                }
                return
            } catch LanguageModelError.contextSizeExceeded where attempt == 1 {
                // The window is small: start over with fresh context and ask again.
                messages.remove(at: index)
                messages.append(ChatMessage(role: .notice, text: "The conversation got long, so the coach started fresh."))
                self.session = nil
            } catch {
                messages.remove(at: index)
                self.error = Self.describe(error)
                model.debugLog("Coach chat failed: \(error)")
                return
            }
        }
    }

    func reset() {
        guard !isResponding else { return }
        messages = []
        session = nil
        error = nil
    }

    /// Loads the model while the athlete is typing.
    func prewarm() {
        guard let model, AppleAnalyzer.onDeviceBlocker == nil, session == nil else { return }
        let session = makeSession(model: model)
        session.prewarm()
        self.session = session
    }

    func setActivity(_ text: String) { activity = text }

    func notice(_ text: String) { messages.append(ChatMessage(role: .notice, text: text)) }

    private func makeSession(model: AppModel) -> LanguageModelSession {
        let toolbox = CoachToolbox(model: model, chat: self)
        return LanguageModelSession(
            tools: [
                RecentDaysTool(toolbox: toolbox),
                WorkoutsTool(toolbox: toolbox),
                WorkoutDetailTool(toolbox: toolbox),
                PlanTool(toolbox: toolbox),
                ChangePlanDayTool(toolbox: toolbox),
                FreeTimesTool(toolbox: toolbox),
                WeatherTool(toolbox: toolbox),
                ScheduleSessionTool(toolbox: toolbox),
            ],
            instructions: Self.instructions(model: model)
        )
    }

    private static func instructions(model: AppModel) -> String {
        let calendar = Calendar.current
        var lines = [
            """
            You are an experienced endurance coach chatting with your athlete in a phone app. Their watch data is \
            available through your tools: use them before answering questions about their training, recovery or \
            plan, and cite the numbers you find. Never invent data; if a tool has nothing, say so. Change the plan \
            only when the athlete asks for it, keep changes consistent with their availability, and tell them what \
            you changed. For when to train, use freeTimes (calendar and weather); add a session to the calendar \
            only when the athlete asks. You are not a doctor: for pain or illness, recommend seeing a professional. Answer in a few \
            short sentences, addressing the athlete as "you".
            """,
            "",
            "TODAY: \(PromptBuilder.dayLabel(.now, calendar: calendar))",
        ]
        let profile = model.profile
        lines.append("ATHLETE: \(profile.primarySport), \(profile.experience.rawValue); \(profile.trainingDaysPerWeek) training days and \(PromptBuilder.num(profile.weeklyHoursAvailable, 1)) h a week")
        lines.append("HR ZONES: \(model.heartRateZones.summary)")
        if profile.hasGoal {
            lines.append("GOAL: \(profile.goalName.isEmpty ? "event" : profile.goalName) on \(PromptBuilder.dayLabel(profile.goalDate, calendar: calendar))\(profile.goalTarget.isEmpty ? "" : ", target \(profile.goalTarget)")")
        }
        if !profile.notes.isEmpty { lines.append("ATHLETE NOTES: \(PromptBuilder.quote(profile.notes))") }
        if let readiness = model.readiness, readiness.level != .unknown {
            let signals = readiness.signals.map(\.text).joined(separator: "; ")
            lines.append("THIS MORNING: \(readiness.level.title.lowercased())\(signals.isEmpty ? "" : " (\(signals))")")
        }
        if let latest = model.latestAnalysis {
            lines.append("YOUR LAST WEEKLY VERDICT (\(PromptBuilder.dayLabel(latest.createdAt, calendar: calendar))): \(latest.report.headline)")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal: return "The coach can't answer that. Try asking differently."
            case .rateLimited: return "Apple Intelligence is busy. Try again in a moment."
            case .unsupportedLanguageOrLocale: return "Apple Intelligence doesn't support your language for this yet."
            default: break
            }
        }
        return "The coach couldn't answer (\(error.localizedDescription))."
    }
}

// MARK: - Tools

/// What the tools can read and change, on the main actor where the app's state lives.
@MainActor
final class CoachToolbox {
    private weak var model: AppModel?
    private weak var chat: CoachChat?

    /// Without a chat, tools run silently (the debug state dump uses this).
    init(model: AppModel, chat: CoachChat?) {
        self.model = model
        self.chat = chat
    }

    /// Newest first, so "1" is the latest workout.
    private var workoutsNewestFirst: [WorkoutSummary] { Array((model?.snapshot?.workouts ?? []).reversed()) }

    func recentDays(_ count: Int) -> String {
        chat?.setActivity("Looking at your recovery…")
        guard let snapshot = model?.snapshot, let metrics = model?.metrics else { return "No health data is loaded." }
        let calendar = Calendar.current
        let sleep = Dictionary(snapshot.sleep.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let num = PromptBuilder.num
        let rows = snapshot.days.suffix(min(max(count, 1), 28)).map { day in
            [
                PromptBuilder.dayLabel(day.date, calendar: calendar),
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
        guard let metrics = model?.metrics else { return "No health data is loaded." }
        let since = Calendar.current.date(byAdding: .day, value: -min(max(days, 1), 56), to: .now) ?? .now
        let sport = sport?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        func matches(_ workout: WorkoutSummary) -> Bool {
            guard let sport else { return true }
            return workout.sport.localizedCaseInsensitiveCompare(sport) == .orderedSame
        }
        let rows = workoutsNewestFirst.enumerated()
            .filter { $0.element.start >= since && matches($0.element) }
            .prefix(15)
            .map { number, workout in
                var parts = [
                    "#\(number + 1)",
                    PromptBuilder.dayLabel(workout.start, calendar: .current),
                    workout.sport,
                    "\(PromptBuilder.num(workout.durationMinutes, 0)) min",
                ]
                if let km = workout.distanceKm { parts.append("\(PromptBuilder.num(km, 1)) km") }
                if let heartRate = workout.averageHeartRate { parts.append("avg HR \(PromptBuilder.num(heartRate, 0))") }
                parts.append("load \(PromptBuilder.num(metrics.workoutLoad[workout.id], 0))")
                if let review = model?.runAnalyses[workout.id] { parts.append("reviewed: \(review.analysis.headline)") }
                return parts.joined(separator: " | ")
            }
        return rows.isEmpty ? "No matching workouts." : rows.joined(separator: "\n")
    }

    func workoutDetail(number: Int) async -> String {
        chat?.setActivity("Opening that workout…")
        let workouts = workoutsNewestFirst
        guard let model, let snapshot = model.snapshot, let metrics = model.metrics,
              workouts.indices.contains(number - 1) else { return "There's no workout #\(number). List workouts first." }
        let workout = workouts[number - 1]
        do {
            let detail = try await model.workoutDetail(for: workout)
            var brief = RunPromptBuilder(
                detail: detail, snapshot: snapshot, metrics: metrics, profile: model.profile,
                plannedSession: model.plannedSession(on: workout.start),
                note: model.runAnalyses[workout.id]?.note ?? "", compact: true
            ).prompt
            if let review = model.runAnalyses[workout.id] {
                brief += "\n\nYOUR EARLIER REVIEW: \(review.analysis.headline) " + review.analysis.summary.joined(separator: " ")
            }
            return brief
        } catch {
            return "Couldn't load that workout: \(error.localizedDescription)"
        }
    }

    func plan() -> String {
        chat?.setActivity("Checking your plan…")
        guard let model else { return "No plan." }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let rows = (0..<7).compactMap { offset -> String? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let label = PromptBuilder.dayLabel(date, calendar: calendar)
            let marker = offset == 0 ? " (today)" : ""
            guard let day = model.plannedSession(on: date) else { return "\(label)\(marker) | no plan" }
            return "\(label)\(marker) | \(day.briefDescription) | \(day.details)"
        }
        var lines = ["COMING DAYS (day | session | details)"] + rows
        if let adherence = model.planAdherence?.completed, !adherence.isEmpty {
            lines.append("LAST 7 DAYS: \(PlanAdherence.summary(of: adherence))")
            lines += adherence.filter { $0.status != .done && $0.status != .rested }.map { day in
                let label = PromptBuilder.dayLabel(day.date, calendar: calendar)
                return "\(label): planned \(day.planned.isRest ? "rest" : day.planned.session), \(([day.status.title.lowercased()] + day.notes).joined(separator: "; "))"
            }
        }
        return lines.joined(separator: "\n")
    }

    func changePlanDay(_ day: PlannedDay) -> String {
        chat?.setActivity("Updating your plan…")
        guard let model else { return "No plan." }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let date = (0..<7).compactMap({ calendar.date(byAdding: .day, value: $0, to: today) })
            .first(where: { PromptBuilder.dayLabel($0, calendar: calendar) == day.day }) else {
            return "\(day.day) isn't one of the next 7 days. Use a label from the plan tool, e.g. \(PromptBuilder.dayLabel(today, calendar: calendar))."
        }
        var day = PlanCheck.normalized([day], labels: [day.day])[0]
        day.day = PromptBuilder.dayLabel(date, calendar: calendar)
        model.updatePlannedDay(on: date, with: day)
        chat?.notice("Plan changed: \(day.day) is now \(day.isRest ? "a rest day" : "\(day.session), \(day.durationMinutes) min").")

        // Check the week around the change against the athlete's limits.
        let week = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let plan = week.compactMap { model.plannedSession(on: $0) }
        let labels = week.map { PromptBuilder.dayLabel($0, calendar: calendar) }
        let problems = plan.count == 7 ? PlanCheck.problems(plan, labels: labels, profile: model.profile) : []
        return problems.isEmpty
            ? "Saved \(day.day): \(day.briefDescription)."
            : "Saved \(day.day): \(day.briefDescription). The next 7 days now break these rules: \(problems.joined(separator: " ")) Tell the athlete, and fix it if they agree."
    }

    /// Today and the next 7 days whose label matches, or all of them for an empty label.
    private func comingDates(matching label: String) -> [Date]? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let dates = (0..<8).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let label = label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return dates }
        let matching = dates.filter { PromptBuilder.dayLabel($0, calendar: calendar).caseInsensitiveCompare(label) == .orderedSame }
        return matching.isEmpty ? nil : matching
    }

    private var scheduleOff: String {
        "Time suggestions are off. The athlete can turn them on in Settings under Calendar & weather."
    }

    func freeTimes(day label: String) -> String {
        chat?.setActivity("Checking your calendar…")
        guard let schedule = model?.schedule else { return "No calendar." }
        guard schedule.isActive else { return scheduleOff }
        guard let dates = comingDates(matching: label) else { return "\(label) isn't today or one of the next 7 days. Use a label from getPlan." }
        let calendar = Calendar.current
        let time = { (date: Date) in SessionScheduler.time(date, calendar: calendar) }
        let rows = dates.compactMap { date -> String? in
            let dayLabel = PromptBuilder.dayLabel(date, calendar: calendar)
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
        var lines: [String] = []
        for date in dates.prefix(label.isEmpty ? 3 : 1) {
            var line = PromptBuilder.dayLabel(date, calendar: calendar)
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
        return lines.count <= dates.prefix(3).count ? "The forecast doesn't reach that day yet." : lines.joined(separator: "\n")
    }

    func scheduleSession(day label: String, start: String) -> String {
        chat?.setActivity("Adding it to your calendar…")
        guard let model else { return "No calendar." }
        let schedule = model.schedule
        guard schedule.isActive else { return scheduleOff }
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
        do {
            try schedule.add(session, on: date, at: startDate)
        } catch {
            return "Couldn't add it: \(error.localizedDescription)"
        }
        let range = "\(SessionScheduler.time(startDate, calendar: calendar))–\(SessionScheduler.time(end, calendar: calendar))"
        chat?.notice("Added to your calendar: \(session.session), \(label) \(range).")
        return "Added \(session.session) on \(label) \(range) to the athlete's calendar."
    }
}

@Generable
nonisolated struct RecentDaysArguments {
    @Guide(description: "How many days to look back, including today", .range(1...28))
    var days: Int
}

nonisolated struct RecentDaysTool: Tool {
    let toolbox: CoachToolbox
    let name = "recentDays"
    let description = "Daily resting heart rate, HRV, sleep, steps and training load for the last days, with 4-week averages."

    @concurrent func call(arguments: RecentDaysArguments) async throws -> String {
        await toolbox.recentDays(arguments.days)
    }
}

@Generable
nonisolated struct WorkoutsArguments {
    @Guide(description: "How many days to look back", .range(1...56))
    var days: Int
    @Guide(description: "Only this sport, e.g. Running, or an empty string for all sports")
    var sport: String
}

nonisolated struct WorkoutsTool: Tool {
    let toolbox: CoachToolbox
    let name = "listWorkouts"
    let description = "Lists recent workouts, newest first, numbered (#1 is the latest), with duration, distance, average heart rate and load."

    @concurrent func call(arguments: WorkoutsArguments) async throws -> String {
        await toolbox.workouts(days: arguments.days, sport: arguments.sport)
    }
}

@Generable
nonisolated struct WorkoutDetailArguments {
    @Guide(description: "The workout's number from listWorkouts; 1 is the latest workout")
    var number: Int
}

nonisolated struct WorkoutDetailTool: Tool {
    let toolbox: CoachToolbox
    let name = "workoutDetail"
    let description = "Details of one workout: splits, heart-rate zones, heart rate over time, context and the athlete's note."

    @concurrent func call(arguments: WorkoutDetailArguments) async throws -> String {
        await toolbox.workoutDetail(number: arguments.number)
    }
}

@Generable
nonisolated struct PlanArguments {}

nonisolated struct PlanTool: Tool {
    let toolbox: CoachToolbox
    let name = "getPlan"
    let description = "The training plan for today and the next 6 days, with exact day labels, and how the last 7 planned days went."

    @concurrent func call(arguments: PlanArguments) async throws -> String {
        await toolbox.plan()
    }
}

nonisolated struct ChangePlanDayTool: Tool {
    let toolbox: CoachToolbox
    let name = "changePlanDay"
    let description = "Replaces one day of the plan (today or the next 6 days) with a new session. Use the day label from getPlan. Only when the athlete asks for a change."

    @concurrent func call(arguments: PlannedDay) async throws -> String {
        await toolbox.changePlanDay(arguments)
    }
}

@Generable
nonisolated struct DayArguments {
    @Guide(description: "Day label from getPlan, e.g. 'Tue 28 Oct', or an empty string for all coming days")
    var day: String
}

nonisolated struct FreeTimesTool: Tool {
    let toolbox: CoachToolbox
    let name = "freeTimes"
    let description = "Best times for the planned sessions from the athlete's calendar and the weather, and sessions already in the calendar."

    @concurrent func call(arguments: DayArguments) async throws -> String {
        await toolbox.freeTimes(day: arguments.day)
    }
}

nonisolated struct WeatherTool: Tool {
    let toolbox: CoachToolbox
    let name = "weather"
    let description = "Forecast every 3 hours from 06:00 to 21:00, with sunrise and sunset."

    @concurrent func call(arguments: DayArguments) async throws -> String {
        await toolbox.weather(day: arguments.day)
    }
}

@Generable
nonisolated struct ScheduleSessionArguments {
    @Guide(description: "Day label from getPlan, e.g. 'Tue 28 Oct'")
    var day: String
    @Guide(description: "Start time, 24-hour HH:mm, e.g. 07:30")
    var start: String
}

nonisolated struct ScheduleSessionTool: Tool {
    let toolbox: CoachToolbox
    let name = "scheduleSession"
    let description = "Adds that day's planned session to the athlete's calendar at a start time (moves it if it's already there). Only when the athlete asks."

    @concurrent func call(arguments: ScheduleSessionArguments) async throws -> String {
        await toolbox.scheduleSession(day: arguments.day, start: arguments.start)
    }
}
