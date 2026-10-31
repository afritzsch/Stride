import Foundation
import FoundationModels

/// Answers the coach's tools with canned text and records what the model called, to check tool use without the app.
@MainActor
final class RecordingToolbox: CoachToolAnswering {
    let labels: [String]
    var calls: [String] = []
    var changed: [PlannedDay] = []
    var scheduled: [(day: String, start: String)] = []

    init(labels: [String]) {
        self.labels = labels
    }

    func recentDays(_ count: Int) -> String {
        calls.append("recentDays")
        return """
            day | resting HR | HRV ms | sleep h | steps | load
            \(labels[0]) | 57 | 45 | 6.4 | 3200 | 0
            4-week averages: resting HR 53, HRV 58 ms, sleep 7.3 h. Load 7 d 310, ACWR 0.89.
            """
    }

    func workouts(days: Int, sport: String?) -> String {
        calls.append("listWorkouts")
        return "#1 | Thu 29 Oct | Running | 44 min | 8.1 km | avg HR 156 | load 93\n#2 | Tue 27 Oct | Running | 55 min | 10.2 km | avg HR 163 | load 110"
    }

    func workoutDetail(number: Int) async -> String {
        calls.append("workoutDetail")
        return """
            SESSION: Running on Thu 29 Oct at 18:10
            - duration 44:12, distance 8.10 km, avg moving pace 5:27 /km, avg HR 156, max HR 171, load 93
            - Time in HR zones: Z1 3%, Z2 20%, Z3 45%, Z4 30%, Z5 2%
            PLANNED FOR THIS DAY: Running, moderate, 90 min. Long run
            """
    }

    func trends() -> String {
        calls.append("trends")
        return "WEEKLY (week starting | sessions | minutes | run km | run pace /km)\nMon 12 Oct | 4 | 280 | 32.0 | 5:41\nMon 19 Oct | 5 | 310 | 35.5 | 5:35"
    }

    func raceForecast(distance: String, month: Int) -> String {
        calls.append("raceForecast")
        return """
            RACE FORECAST, computed by the app: \(distance) in April 2027 (about 24 weeks away)
            - Projected race time: 1:52 h–1:58 h. Quote these times exactly; don't calculate other times.
            """
    }

    func plan() -> String {
        calls.append("getPlan")
        return """
            COMING DAYS (day | session | details)
            \(labels[0]) (today) | Strength, easy, 40 min | Gym
            \(labels[1]) (tomorrow) | Running, moderate, 75 min | Long run
            \(labels[2]) | Rest | –
            \(labels[3]) | Running, hard, 50 min | Intervals 6×3 min
            """
    }

    func changePlanDay(_ day: PlannedDay) -> String {
        calls.append("changePlanDay")
        changed.append(day)
        return "Saved \(day.day): \(day.briefDescription)."
    }

    func freeTimes(day: String) -> String {
        calls.append("freeTimes")
        return "day | session | calendar and times, best first\n\(labels[1]) | Running, moderate, 75 min | best times: 07:00–08:15 (8 °C, dry); 17:30–18:45 (11 °C, dry)"
    }

    func weather(day: String) -> String {
        calls.append("weather")
        return "\(labels[1]) (sunrise 07:05, sunset 16:52)\n  09:00 8 °C (feels 6), rain 10%, wind 12 km/h, cloudy"
    }

    func scheduleSession(day: String, start: String) -> String {
        calls.append("scheduleSession")
        scheduled.append((day, start))
        return "Added Long run on \(day) \(start) to the athlete's calendar."
    }

    var changedSomething: Bool { !changed.isEmpty || !scheduled.isEmpty }
}

/// The chat's tool use: the right tool for the question, and no plan or calendar change unless asked. Each case
/// runs a few times because output varies; a case passes when most runs do.
func evalChat(_ scenario: Scenario) async {
    section("Coach chat")
    let labels = (0..<7).map(scenario.label)
    let readiness = Readiness(snapshot: scenario.snapshot, metrics: scenario.metrics, profile: scenario.profile, calendar: scenario.calendar)
    let instructions = CoachTools.instructions(
        profile: scenario.profile, zones: scenario.metrics.heartRateZones, readiness: readiness,
        lastVerdict: scenario.history.first, now: scenario.snapshot.fetchedAt, calendar: scenario.calendar
    )

    // What every chat request spends before the conversation: instructions and the tools' names, descriptions and schemas.
    let model = SystemLanguageModel.default
    let tools = CoachTools.all(RecordingToolbox(labels: labels))
    var toolTokens = 0
    for tool in tools {
        toolTokens += (try? await model.tokenCount(for: tool.parameters)) ?? 0
        toolTokens += (try? await model.tokenCount(for: "\(tool.name): \(tool.description)")) ?? 0
    }
    let instructionTokens = (try? await model.tokenCount(for: instructions)) ?? -1
    print("  fixed cost: instructions \(instructionTokens) + tools about \(toolTokens) tokens (iPhone window 4096)")

    struct Case {
        var question: String
        var passes: (RecordingToolbox, String) -> Bool
    }
    let cases = [
        Case(question: "What time could I run a half marathon in April?") { box, reply in
            box.calls.contains("raceForecast") && (reply.contains("1:52") || reply.contains("1:58")) && !box.changedSomething
        },
        Case(question: "Please make tomorrow a rest day.") { box, _ in
            box.changed.contains { $0.day == labels[1] && $0.isRest } && box.scheduled.isEmpty
        },
        Case(question: "How did my last run go?") { box, _ in
            (box.calls.contains("listWorkouts") || box.calls.contains("workoutDetail")) && !box.changedSomething
        },
        // This morning's readiness is in the instructions, so answering without a tool is fine.
        Case(question: "Should I train hard today?") { box, reply in
            !reply.isEmpty && !box.changedSomething
        },
        Case(question: "Put tomorrow's session in my calendar at 7:30.") { box, _ in
            box.scheduled.contains { $0.day == labels[1] && $0.start == "07:30" } && box.changed.isEmpty
        },
    ]
    let runs = 3
    for item in cases {
        var passed = 0
        var lastCalls: [String] = []
        for _ in 0..<runs {
            let box = RecordingToolbox(labels: labels)
            let session = LanguageModelSession(tools: CoachTools.all(box), instructions: instructions)
            do {
                let reply = try await session.respond(to: item.question).content
                if item.passes(box, reply) {
                    passed += 1
                } else {
                    let changes = box.changed.map { "\($0.day) | \($0.sport) | \($0.intensity.rawValue) | \($0.durationMinutes)" }
                    let times = box.scheduled.map { "\($0.day) \($0.start)" }
                    print("    ✗ changed \(changes), scheduled \(times): \(PromptBuilder.quote(reply, limit: 200))")
                }
                lastCalls = box.calls
            } catch {
                print("  \(item.question): \(error)")
            }
        }
        print("  \(passed)/\(runs) \(item.question) (last calls: \(lastCalls.joined(separator: ", ")))")
        check(passed * 2 > runs, "chat: \(item.question) passes in most runs (\(passed)/\(runs))")
    }
}
