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
        model.refreshModelAvailability()
        if let blocker = model.onDeviceBlocker {
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
        guard let model, model.onDeviceBlocker == nil, session == nil else { return }
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
                TrendsTool(toolbox: toolbox),
                RaceForecastTool(toolbox: toolbox),
                PlanTool(toolbox: toolbox),
                ChangePlanDayTool(toolbox: toolbox),
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
            plan, and cite the numbers you find. Never invent data; if a tool has nothing, say so. When asked for a \
            prognosis, prediction or what to expect (fitness, race time, reaching the goal), always give your best \
            estimate: call trends first, then answer with a concrete range, the numbers it rests on and how sure you \
            are. For race times, call raceForecast and quote its times exactly; never calculate a time yourself. \
            Projecting from their data is coaching, not inventing data, and a training prognosis is not medical \
            advice. Change the plan only when the athlete asks for it, keep changes consistent with their \
            availability, and tell them what you changed. Only for pain, injury or illness, recommend seeing a \
            professional. Answer in a few short sentences, addressing the athlete as "you".
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

    /// Weekly and monthly rollups, run pace and heart rate per week, records and the goal: what a forecast needs.
    func trends() -> String {
        chat?.setActivity("Looking at your trends…")
        guard let model, let snapshot = model.snapshot, let metrics = model.metrics else { return "No health data is loaded." }
        let calendar = Calendar.current
        let num = PromptBuilder.num
        var lines = ["WEEKLY (week starting | sessions | minutes | km | load | run km | run pace /km | run avg HR | RHR | HRV)"]
        for week in metrics.weeks.suffix(8) {
            let end = calendar.date(byAdding: .day, value: 7, to: week.weekStart) ?? week.weekStart
            let runs = snapshot.workouts.filter { $0.sport == "Running" && $0.start >= week.weekStart && $0.start < end }
            let measured = runs.filter { ($0.distanceKm ?? 0) > 0 }
            let runKm = measured.compactMap(\.distanceKm).reduce(0, +)
            let pace = runKm > 0 ? measured.map(\.durationMinutes).reduce(0, +) * 60 / runKm : nil
            let withHR = runs.compactMap { run in run.averageHeartRate.map { (hr: $0, minutes: run.durationMinutes) } }
            let hrMinutes = withHR.map(\.minutes).reduce(0, +)
            let runHR = hrMinutes > 0 ? withHR.map { $0.hr * $0.minutes }.reduce(0, +) / hrMinutes : nil
            lines.append([
                PromptBuilder.dayLabel(week.weekStart, calendar: calendar) + (end > snapshot.fetchedAt ? " (in progress)" : ""),
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
        let ind = metrics.indicators
        lines.append("Fitness (28-day load per week) \(num(ind.chronicLoad, 0)), last 7 days \(num(ind.acuteLoad, 0)), ACWR \(num(ind.acwr, 2)).")

        if let progress = model.progress {
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
                lines.append("RECORDS: " + progress.records.map { "\($0.title) \($0.value) (\(PromptBuilder.dayLabel($0.date, calendar: calendar)))" }.joined(separator: "; "))
            }
        }

        let profile = model.profile
        if profile.hasGoal {
            let weeks = max(0, calendar.dateComponents([.day], from: .now, to: profile.goalDate).day ?? 0) / 7
            lines.append("GOAL: \(profile.goalName.isEmpty ? "event" : profile.goalName), \(weeks) weeks away\(profile.goalTarget.isEmpty ? "" : ", target \(profile.goalTarget)")")
        } else {
            lines.append("GOAL: none set.")
        }
        return lines.joined(separator: "\n")
    }

    /// `month` 1–12 is that month's next occurrence (the goal date if it falls in it); 0 is the goal date, or today.
    func raceForecast(distance: String, month: Int) -> String {
        chat?.setActivity("Estimating your race time…")
        guard let model, let snapshot = model.snapshot else { return "No health data is loaded." }
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
        guard model.updatePlannedDay(on: date, with: day) else {
            return "There's no saved plan for \(day.day). The athlete needs to run a weekly analysis first."
        }
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
nonisolated struct TrendsArguments {}

nonisolated struct TrendsTool: Tool {
    let toolbox: CoachToolbox
    let name = "trends"
    let description = "Long-term trends for forecasts and progress questions: 8 weeks of volume, load, run pace and run heart rate, 6 months of totals, fitness, personal records and the goal."

    @concurrent func call(arguments: TrendsArguments) async throws -> String {
        await toolbox.trends()
    }
}

@Generable
nonisolated struct RaceForecastArguments {
    @Guide(description: "The race distance", .anyOf(RaceForecast.distances.map(\.name)))
    var distance: String
    @Guide(description: "Month of the race, 1 = January … 12 = December; 0 for the athlete's goal date or today", .range(0...12))
    var month: Int
}

nonisolated struct RaceForecastTool: Tool {
    let toolbox: CoachToolbox
    let name = "raceForecast"
    let description = "Estimated finish time for a 5K, 10K, half marathon or marathon now or in a given month, computed from recent runs. Use it for every race-time question."

    @concurrent func call(arguments: RaceForecastArguments) async throws -> String {
        await toolbox.raceForecast(distance: arguments.distance, month: arguments.month)
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
