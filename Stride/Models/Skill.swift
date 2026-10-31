import Foundation

/// The numbers behind each skill's XP, in one place. `Skill.rule` (shown in the UI) is built from them, so the text
/// can't drift from the code. Endurance (1 XP per minute) and power (1 XP per TRIMP point) have no factor to name.
nonisolated enum XPRules {
    static let strengthPerMinute = 3.0
    /// Sports whose minutes earn Strength XP. Not the same set as the strength coach's (`WorkoutSummary.strengthSports`).
    static let strengthSports: Set<String> = [Sport.strength, "HIIT", "Core", "Climbing", "Cross training"]

    static let stepsPerThousand = 2.0
    static let stepsMaxPerDay = 60.0
    /// Steps above this earn nothing more.
    static var stepsCap: Double { stepsMaxPerDay / stepsPerThousand * 1000 }

    /// A night counts as "on target" within this many hours of the sleep target, "near" within an hour.
    static let sleepOnTargetToleranceHours = 0.25
    static let sleepNearTargetToleranceHours = 1.0
    static let sleepOnTarget = 20.0
    static let sleepNearTarget = 10.0

    static let disciplineDay = 25.0
    static let disciplineWeekBonus = 50.0

    /// Explorer XP per km: foot sports count most, cycling less (it's faster), swimming more (it's slower).
    static func explorerPerKm(sport: String) -> Double {
        switch sport {
        case Sport.running, Sport.walking, Sport.hiking: 10
        case Sport.swimming: 40
        case Sport.cycling: 3
        default: 5
        }
    }

    /// Steps earn `stepsPerThousand` per 1,000, up to `stepsMaxPerDay`.
    static func vitality(steps: Double) -> Double {
        min(steps / 1000 * stepsPerThousand, stepsMaxPerDay)
    }

    /// Rest XP for a night of `asleepHours` against the target.
    static func rest(asleepHours: Double, targetHours: Double) -> Double {
        let short = targetHours - asleepHours
        return short <= sleepOnTargetToleranceHours ? sleepOnTarget : short <= sleepNearTargetToleranceHours ? sleepNearTarget : 0
    }
}

/// A trainable attribute, RPG style. Each earns XP from one kind of effort; the athlete level adds them all up.
nonisolated enum Skill: String, CaseIterable, Identifiable, Sendable {
    case endurance, power, strength, explorer, vitality, rest, discipline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .endurance: "Endurance"
        case .power: "Power"
        case .strength: "Strength"
        case .explorer: "Explorer"
        case .vitality: "Vitality"
        case .rest: "Rest"
        case .discipline: "Discipline"
        }
    }

    var systemImage: String {
        switch self {
        case .endurance: "lungs.fill"
        case .power: "bolt.fill"
        case .strength: "dumbbell.fill"
        case .explorer: "map.fill"
        case .vitality: "shoeprints.fill"
        case .rest: "moon.zzz.fill"
        case .discipline: "calendar.badge.checkmark"
        }
    }

    var meaning: String {
        switch self {
        case .endurance: "Your aerobic base: how much time you spend training. Volume is the foundation every other kind of fitness is built on."
        case .power: "How hard you train. Training load weights every minute by heart rate, so a minute in Z4–5 counts several times more than an easy one."
        case .strength: "Resistance and functional work that keeps muscles, tendons and bones resilient, which makes you faster and less injury-prone."
        case .explorer: "Ground covered. A km on foot counts most; cycling counts less per km because it's faster, swimming more because it's slower."
        case .vitality: "Everyday movement outside training. Lots of light activity helps recovery and long-term health, and it adds up."
        case .rest: "Sleep, where training turns into fitness. Without enough of it, hard sessions mostly just make you tired."
        case .discipline: "Consistency. Showing up most days, week after week, beats occasional big efforts."
        }
    }

    /// Where the numbers come from, with the user's own settings filled in.
    func tracking(profile: UserProfile) -> String {
        switch self {
        case .endurance:
            "Duration of every workout in Apple Health, any sport and any intensity."
        case .power:
            "Banister TRIMP from each workout's average heart rate, your max HR (\(Int(profile.effectiveMaxHeartRate)) bpm) and your resting HR in that month. Workouts without heart rate count as moderate effort."
        case .strength:
            "Minutes of workouts recorded as Strength, HIIT, Core, Climbing or Cross training. A gym session saved as \"Other\" or \"Cardio\" doesn't count."
        case .explorer:
            "The distance your watch saved with each workout. Workouts without a distance, like strength or yoga, earn nothing here."
        case .vitality:
            "Daily step count from Apple Health (watch and phone combined, without double counting). Steps above \(Int(XPRules.stepsCap).formatted()) a day don't add XP."
        case .rest:
            "Time asleep per night from Apple Health, against your sleep target in Settings (\(ProgressReport.hours(profile.sleepTargetHours))). Naps don't count."
        case .discipline:
            "Any day with at least one workout is a training day. The weekly bonus comes once a week reaches your training days per week in Settings (\(profile.trainingDaysPerWeek))."
        }
    }

    var tips: [String] {
        switch self {
        case .endurance: [
            "Add time before intensity: make one session a week, often the long run, 10 minutes longer.",
            "Keep most sessions easy (Z1–2). Easy volume is what you can sustain and recover from.",
            "Grow weekly time by about 10% at most, with a lighter week every 3–4 weeks.",
        ]
        case .power: [
            "One or two quality sessions a week (intervals, tempo, hills) earn the most load per minute.",
            "Keep the acute:chronic ratio on the Dashboard within 0.8–1.3. Sudden spikes raise the injury risk.",
            "Keep the easy days truly easy, so the hard days can be hard.",
        ]
        case .strength: [
            "Two 30–45 minute sessions a week are enough to see results.",
            "Record them on your watch as a strength workout so they count here.",
            "For runners, focus on legs, hips and core: squats, lunges, deadlifts, calf raises, planks.",
        ]
        case .explorer: [
            "Make one long run or ride a week your anchor session.",
            "Walks and hikes count too, if you record them as workouts.",
            "Check that Garmin Connect shares workout distance with Apple Health.",
        ]
        case .vitality: [
            "Walk for short trips, take calls on foot, add a 10-minute walk after meals.",
            "Set a realistic step target in Settings and aim to hit it on most days.",
            "Rest days are a good time for an easy walk: movement without training stress.",
        ]
        case .rest: [
            "Keep your bedtime within about 30 minutes, also on weekends.",
            "Count back from your wake-up time and start winding down 30 minutes before.",
            "Avoid caffeine after early afternoon, alcohol, and hard sessions late in the evening.",
        ]
        case .discipline: [
            "Spread training over more days. Even a 20-minute session counts as a training day.",
            "Set training days per week in Settings to what you can really do, then hit it.",
            "Plan the week ahead (the Plan tab helps) so sessions don't depend on motivation.",
        ]
        }
    }

    /// How the skill earns XP, shown in the UI so the numbers aren't a black box.
    var rule: String {
        typealias XP = XPRules
        switch self {
        case .endurance: return "1 XP per minute of any workout"
        case .power: return "1 XP per point of training load (TRIMP), so hard sessions count more"
        case .strength: return "\(Int(XP.strengthPerMinute)) XP per minute of strength, HIIT, core, climbing or cross training"
        case .explorer:
            return "\(Int(XP.explorerPerKm(sport: Sport.running))) XP per km on foot, \(Int(XP.explorerPerKm(sport: Sport.cycling))) per km cycling, "
                + "\(Int(XP.explorerPerKm(sport: Sport.swimming))) per km swimming, \(Int(XP.explorerPerKm(sport: Sport.other))) for other sports"
        case .vitality: return "\(Int(XP.stepsPerThousand)) XP per 1,000 daily steps, up to \(Int(XP.stepsMaxPerDay)) a day"
        case .rest: return "\(Int(XP.sleepOnTarget)) XP per night at your sleep target, \(Int(XP.sleepNearTarget)) within an hour of it"
        case .discipline: return "\(Int(XP.disciplineDay)) XP per training day, +\(Int(XP.disciplineWeekBonus)) for each week you hit your training days"
        }
    }
}
