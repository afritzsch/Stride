import Foundation

/// Demo data plus the app state that shapes a prompt (profile, earlier analyses, coach reviews).
struct Scenario {
    var name: String
    var snapshot: HealthSnapshot
    var profile = UserProfile()
    var history: [SavedAnalysis] = []
    var reviews: [UUID: SavedRunAnalysis] = [:]
    var calendar = Calendar.current

    var metrics: MetricsReport { MetricsReport(snapshot: snapshot, profile: profile, calendar: calendar) }
    var today: Date { calendar.startOfDay(for: snapshot.fetchedAt) }
    var planStart: Date { day(1) }

    func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today)!
    }

    func label(_ offset: Int) -> String {
        PromptBuilder.dayLabel(day(offset), calendar: calendar)
    }

    func weeklyPrompt(compact: Bool) -> String {
        PromptBuilder(
            snapshot: snapshot, metrics: metrics, profile: profile, planStart: planStart, compact: compact,
            history: history, reviews: reviews, calendar: calendar
        ).prompt
    }

    /// The labels the weekly prompt asks for.
    var planLabels: [String] { (1...7).map(label) }

    /// Saves `history` (plus a current plan from tomorrow) and `reviews` as the app's JSON stores.
    func seed(into directory: URL) throws {
        let labels = planLabels
        let upcoming = AnalysisReport(
            headline: "Ease off this week: sleep is down and resting HR is up",
            trainingStatus: .overreaching,
            assessment: "Load rose 20% while sleep fell to 6.3 h and HRV dropped 10 ms.",
            insights: [], recommendations: [], goalOutlook: "",
            weekPlan: [
                PlannedDay(day: labels[0], sport: "Running", intensity: .easy, session: "Easy run", durationMinutes: 40, targetZone: 2, details: "Conversational pace."),
                PlannedDay(day: labels[1], sport: PlannedDay.rest, intensity: .rest, session: "Rest", durationMinutes: 0, targetZone: 0, details: "Bed by 22:45."),
                PlannedDay(day: labels[2], sport: "Running", intensity: .hard, session: "Tempo 3×8 min", durationMinutes: 50, targetZone: 4, details: "2 min jog between."),
                PlannedDay(day: labels[3], sport: PlannedDay.rest, intensity: .rest, session: "Rest", durationMinutes: 0, targetZone: 0, details: ""),
                PlannedDay(day: labels[4], sport: "Running", intensity: .moderate, session: "Long run", durationMinutes: 85, targetZone: 2, details: "Keep it easy."),
                PlannedDay(day: labels[5], sport: "Cycling", intensity: .easy, session: "Easy ride", durationMinutes: 60, targetZone: 2, details: ""),
                PlannedDay(day: labels[6], sport: PlannedDay.rest, intensity: .rest, session: "Rest", durationMinutes: 0, targetZone: 0, details: ""),
            ]
        )
        let current = SavedAnalysis(createdAt: snapshot.fetchedAt, modelName: "Seeded", planStartDate: planStart, report: upcoming)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([current] + history).write(to: directory.appending(path: "analyses.json"))
        try JSONEncoder().encode(Array(reviews.values)).write(to: directory.appending(path: "run-analyses.json"))
        if let planned = history.plannedDay(on: today, calendar: calendar) {
            let adjustment = DayAdjustment(
                reason: "Your HRV is down 21% and you slept 6.4 h, so keep today light.",
                session: PlannedDay(day: planned.day, sport: planned.sport, intensity: .easy, session: "Light mobility", durationMinutes: 25, targetZone: 1, details: "")
            )
            let saved = SavedAdjustment(date: snapshot.fetchedAt, original: planned, adjustment: adjustment.clamped(to: planned))
            try JSONEncoder().encode(saved).write(to: directory.appending(path: "today-adjustment.json"))
        }
        print("Seeded \(history.count + 1) analyses and \(reviews.count) reviews into \(directory.path())")
    }

    /// Situations that stress different rules: tight availability, a race soon, data a Garmin often lacks.
    static func all() -> [Scenario] {
        let demo = demoWithHistory()

        var tight = demo
        tight.name = "beginner, 3 days / 2.5 h"
        tight.profile.experience = .beginner
        tight.profile.trainingDaysPerWeek = 3
        tight.profile.weeklyHoursAvailable = 2.5

        var race = demo
        race.name = "half marathon in 2 weeks"
        race.profile.hasGoal = true
        race.profile.goalName = "Berlin Half Marathon"
        race.profile.goalTarget = "sub 1:45"
        race.profile.goalDate = race.day(14)

        var sparse = demo
        sparse.name = "no HRV, resting HR or sleep"
        sparse.snapshot.days = sparse.snapshot.days.map {
            var day = $0
            day.hrvMs = nil
            day.restingHeartRate = nil
            return day
        }
        sparse.snapshot.sleep = []
        return [demo, tight, race, sparse]
    }

    /// Demo data with a plan that started six days ago and a review of the last long run.
    static func demoWithHistory() -> Scenario {
        var scenario = Scenario(name: "demo with history", snapshot: DemoData.snapshot())
        let start = scenario.day(-6)
        func planned(_ offset: Int, _ sport: String, _ intensity: SessionIntensity, _ session: String, _ minutes: Int, _ zone: Int) -> PlannedDay {
            PlannedDay(
                day: scenario.label(offset - 6), sport: sport, intensity: intensity, session: session,
                durationMinutes: minutes, targetZone: zone, details: ""
            )
        }
        let plan = [
            planned(0, "Running", .hard, "Intervals 6×3 min", 50, 4),
            planned(1, PlannedDay.rest, .rest, "Rest", 0, 0),
            planned(2, "Running", .easy, "Easy run", 45, 2),
            planned(3, "Running", .easy, "Easy run", 40, 2),
            planned(4, "Running", .moderate, "Long run", 90, 2),
            planned(5, PlannedDay.rest, .rest, "Rest", 0, 0),
            planned(6, "Strength", .easy, "Gym", 40, 0),
        ]
        let report = AnalysisReport(
            headline: "Load is building well, keep sleep in check",
            trainingStatus: .productive,
            assessment: "",
            insights: [],
            recommendations: [],
            goalOutlook: "",
            weekPlan: plan
        )
        scenario.history = [SavedAnalysis(createdAt: scenario.day(-7), modelName: "test", planStartDate: start, report: report)]
        if let longRun = scenario.snapshot.workouts.last(where: { $0.sport == "Running" && $0.durationMinutes > 90 }) {
            let review = RunAnalysis(
                effort: .moderate, headline: "Solid long run, faded late",
                summary: [], planComparison: "", highlights: [], improvements: [], recovery: "", nextSession: ""
            )
            scenario.reviews[longRun.id] = SavedRunAnalysis(
                workoutID: longRun.id, createdAt: longRun.start, modelName: "test",
                note: "Left calf felt tight\nafter 14 km", analysis: review
            )
        }
        return scenario
    }
}
