import Foundation
import FoundationModels

/// A coach tool: the model fills in `Arguments`, and `run` answers from the toolbox on the main actor, where the app's
/// state lives. Each tool differs only in its name, description and what it asks the toolbox.
nonisolated struct CoachTool<Arguments: Generable & Sendable>: Tool {
    let toolbox: CoachToolbox
    let name: String
    let description: String
    let run: @Sendable @MainActor (CoachToolbox, Arguments) async -> String

    @concurrent func call(arguments: Arguments) async throws -> String {
        await run(toolbox, arguments)
    }
}

extension CoachTool {
    init(
        _ toolbox: CoachToolbox, _ name: String, _ description: String,
        run: @escaping @Sendable @MainActor (CoachToolbox, Arguments) async -> String
    ) {
        self.init(toolbox: toolbox, name: name, description: description, run: run)
    }
}

enum CoachTools {
    /// Everything the coach can look up or change. Names and descriptions are what the model sees.
    static func all(_ toolbox: CoachToolbox) -> [any Tool] {
        [
            CoachTool(toolbox, "recentDays", "Daily resting heart rate, HRV, sleep, steps and training load for the last days, with 4-week averages.") {
                (toolbox, arguments: RecentDaysArguments) in toolbox.recentDays(arguments.days)
            },
            CoachTool(toolbox, "listWorkouts", "Lists recent workouts, newest first, numbered (#1 is the latest), with duration, distance, average heart rate and load.") {
                (toolbox, arguments: WorkoutsArguments) in toolbox.workouts(days: arguments.days, sport: arguments.sport)
            },
            CoachTool(toolbox, "workoutDetail", "Details of one workout: splits, heart-rate zones, heart rate over time, context and the athlete's note.") {
                (toolbox, arguments: WorkoutDetailArguments) in await toolbox.workoutDetail(number: arguments.number)
            },
            CoachTool(toolbox, "trends", "Long-term trends for forecasts and progress questions: 8 weeks of volume, load, run pace and run heart rate, 6 months of totals, fitness, personal records and the goal.") {
                (toolbox, _: TrendsArguments) in toolbox.trends()
            },
            CoachTool(toolbox, "raceForecast", "Estimated finish time for a 5K, 10K, half marathon or marathon now or in a given month, computed from recent runs. Use it for every race-time question.") {
                (toolbox, arguments: RaceForecastArguments) in toolbox.raceForecast(distance: arguments.distance, month: arguments.month)
            },
            CoachTool(toolbox, "getPlan", "The training plan for today and the next 6 days, with exact day labels, and how the last 7 planned days went.") {
                (toolbox, _: PlanArguments) in toolbox.plan()
            },
            CoachTool(toolbox, "changePlanDay", "Replaces one day of the plan (today or the next 6 days) with a new session. Use the day label from getPlan. Only when the athlete asks for a change.") {
                (toolbox, day: PlannedDay) in toolbox.changePlanDay(day)
            },
            CoachTool(toolbox, "freeTimes", "Best times for the planned sessions from the athlete's calendar and the weather, and sessions already in the calendar.") {
                (toolbox, arguments: DayArguments) in toolbox.freeTimes(day: arguments.day)
            },
            CoachTool(toolbox, "weather", "Forecast every 3 hours from 06:00 to 21:00, with sunrise and sunset.") {
                (toolbox, arguments: DayArguments) in toolbox.weather(day: arguments.day)
            },
            CoachTool(toolbox, "scheduleSession", "Adds that day's planned session to the athlete's calendar at a start time (moves it if it's already there). Only when the athlete asks.") {
                (toolbox, arguments: ScheduleSessionArguments) in toolbox.scheduleSession(day: arguments.day, start: arguments.start)
            },
        ]
    }
}

// MARK: - Arguments the model fills in

@Generable
nonisolated struct RecentDaysArguments {
    @Guide(description: "How many days to look back, including today", .range(1...28))
    var days: Int
}

@Generable
nonisolated struct WorkoutsArguments {
    @Guide(description: "How many days to look back", .range(1...56))
    var days: Int
    @Guide(description: "Only this sport, e.g. Running, or an empty string for all sports")
    var sport: String
}

@Generable
nonisolated struct WorkoutDetailArguments {
    @Guide(description: "The workout's number from listWorkouts; 1 is the latest workout")
    var number: Int
}

@Generable
nonisolated struct TrendsArguments {}

@Generable
nonisolated struct RaceForecastArguments {
    @Guide(description: "The race distance", .anyOf(RaceForecast.distances.map(\.name)))
    var distance: String
    @Guide(description: "Month of the race, 1 = January … 12 = December; 0 for the athlete's goal date or today", .range(0...12))
    var month: Int
}

@Generable
nonisolated struct PlanArguments {}

@Generable
nonisolated struct DayArguments {
    @Guide(description: "Day label from getPlan, e.g. 'Tue 28 Oct', or an empty string for all coming days")
    var day: String
}

@Generable
nonisolated struct ScheduleSessionArguments {
    @Guide(description: "Day label from getPlan, e.g. 'Tue 28 Oct'")
    var day: String
    @Guide(description: "Start time, 24-hour HH:mm, e.g. 07:30")
    var start: String
}
