import Foundation

/// Turns health data into a compact text brief. `compact` keeps the on-device model inside its small context window.
nonisolated struct PromptBuilder {
    var snapshot: HealthSnapshot
    var metrics: MetricsReport
    var profile: UserProfile
    var planStart: Date
    var compact: Bool
    var calendar = Calendar.current

    static let instructions = """
        You are an experienced endurance coach and sleep and recovery specialist. You are reviewing an athlete's \
        wearable data from Apple Health and helping them plan better.

        Rules:
        - Base every insight on the numbers provided and cite them (e.g. "resting HR 55 vs 51 bpm 4-week average").
        - If a metric is missing ("–"), say the data is unavailable. Don't invent values.
        - Recommendations must be concrete: what, when, how much.
        - The 7-day plan must fit the athlete's available training days and weekly hours, keep at least one easy day \
        between hard sessions, and include rest days.
        - Adjust load to fatigue signals: ACWR above 1.3, resting HR more than 3 bpm above baseline, HRV well below \
        baseline, or under 7 h of sleep mean reduce intensity or volume. ACWR below 0.8 with good recovery means \
        there is room to build gradually (about 10% per week at most).
        - If there is a goal event, periodize toward it using the weeks remaining (base, build, peak, then a taper \
        in the final 1–2 weeks).
        - Cover only the athlete's selected focus areas, but always produce the full 7-day plan.
        - You are not a doctor. If the data suggests a medical concern, recommend seeing a professional.
        - Address the athlete as "you". Be direct and concise.
        """

    var prompt: String {
        var lines: [String] = []
        let ind = metrics.indicators

        lines.append("TODAY: \(Self.dayLabel(snapshot.fetchedAt, calendar: calendar))")
        lines.append("")
        lines.append("ATHLETE")
        lines.append("- Primary sport: \(profile.primarySport), experience: \(profile.experience.rawValue)")
        if let age = profile.age { lines.append("- Age: \(age)") }
        lines.append("- Max HR: \(Int(profile.effectiveMaxHeartRate)) bpm\(profile.isMaxHeartRateEstimated ? " (estimated)" : "")")
        lines.append("- HR zones (as set on the athlete's watch; use these, don't derive your own): \(metrics.heartRateZones.summary)")
        lines.append("- Available: \(profile.trainingDaysPerWeek) training days/week, \(Self.num(profile.weeklyHoursAvailable, 1)) h/week")
        lines.append("- Targets: \(Self.num(profile.sleepTargetHours, 1)) h sleep, \(profile.dailyStepTarget) steps/day")
        let focus = FocusArea.allCases.filter { profile.focusAreas.contains($0) }.map(\.title)
        lines.append("- Focus areas: \(focus.isEmpty ? "all" : focus.joined(separator: ", "))")
        if profile.hasGoal {
            let weeks = max(0, calendar.dateComponents([.day], from: snapshot.fetchedAt, to: profile.goalDate).day ?? 0) / 7
            let target = profile.goalTarget.isEmpty ? "" : ", target: \(profile.goalTarget)"
            lines.append("- Goal: \(profile.goalName.isEmpty ? "event" : profile.goalName) on \(Self.dayLabel(profile.goalDate, calendar: calendar)) (\(weeks) weeks away\(target))")
        } else {
            lines.append("- Goal: none set (general fitness)")
        }
        if !profile.notes.isEmpty { lines.append("- Notes: \(profile.notes)") }

        lines.append("")
        lines.append("KEY INDICATORS (load = Banister TRIMP from avg HR)")
        lines.append("- Load last 7 d: \(Self.num(ind.acuteLoad, 0)); avg weekly last 28 d: \(Self.num(ind.chronicLoad, 0)); ACWR: \(Self.num(ind.acwr, 2))")
        lines.append("- Monotony (7 d): \(Self.num(ind.monotony, 1)); consecutive training days: \(ind.consecutiveTrainingDays)")
        lines.append("- Resting HR 7 d / 28 d: \(Self.num(ind.restingHR7, 0)) / \(Self.num(ind.restingHR28, 0)) bpm")
        lines.append("- HRV (SDNN) 7 d / 28 d: \(Self.num(ind.hrv7, 0)) / \(Self.num(ind.hrv28, 0)) ms")
        lines.append("- Sleep 7 d / 28 d: \(Self.num(ind.sleep7, 1)) / \(Self.num(ind.sleep28, 1)) h; bedtime variability (SD, 14 nights): \(Self.num(ind.bedtimeSDMinutes, 0)) min")
        lines.append("- Steps 7 d / 28 d: \(Self.num(ind.steps7, 0)) / \(Self.num(ind.steps28, 0))")
        let zoneTotal = ind.zoneMinutes28.values.reduce(0, +)
        if zoneTotal > 0 {
            let share = { (zone: IntensityZone) in "\(Int((ind.zoneMinutes28[zone] ?? 0) / zoneTotal * 100))%" }
            lines.append("- Intensity mix 28 d by avg HR (easy Z1–2 / moderate Z3 / hard Z4–5 / no HR): \(share(.easy)) / \(share(.moderate)) / \(share(.hard)) / \(share(.unknown))")
        }

        lines.append("")
        lines.append("WEEKLY (week starting | sessions | minutes | km | load | hard | sleep h | steps | RHR | HRV)")
        for week in metrics.weeks.suffix(compact ? 4 : 8) {
            let inProgress = (calendar.date(byAdding: .day, value: 7, to: week.weekStart) ?? week.weekStart) > snapshot.fetchedAt
            lines.append([
                Self.dayLabel(week.weekStart, calendar: calendar) + (inProgress ? " (in progress)" : ""),
                "\(week.sessions)",
                Self.num(week.trainingMinutes, 0),
                Self.num(week.distanceKm, 1),
                Self.num(week.load, 0),
                "\(week.hardSessions)",
                Self.num(week.avgSleepHours, 1),
                Self.num(week.avgSteps, 0),
                Self.num(week.avgRestingHR, 0),
                Self.num(week.avgHRV, 0),
            ].joined(separator: " | "))
        }

        if !compact {
            let sleepByDay = Dictionary(snapshot.sleep.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
            lines.append("")
            lines.append("DAILY, LAST 14 DAYS (date | steps | RHR | HRV | sleep h | bedtime | deep h | REM h | load)")
            for day in snapshot.days.suffix(14) {
                let night = sleepByDay[day.date]
                lines.append([
                    Self.dayLabel(day.date, calendar: calendar),
                    Self.num(day.steps, 0),
                    Self.num(day.restingHeartRate, 0),
                    Self.num(day.hrvMs, 0),
                    Self.num(night?.asleepHours, 1),
                    night.map { $0.bedtime.formatted(date: .omitted, time: .shortened) } ?? "–",
                    Self.num(night?.deepHours, 1),
                    Self.num(night?.remHours, 1),
                    Self.num(metrics.dailyLoad[day.date], 0),
                ].joined(separator: " | "))
            }
        } else {
            lines.append("")
            lines.append("LAST 7 NIGHTS (date | sleep h | bedtime)")
            for night in snapshot.sleep.suffix(7) {
                lines.append("\(Self.dayLabel(night.date, calendar: calendar)) | \(Self.num(night.asleepHours, 1)) | \(night.bedtime.formatted(date: .omitted, time: .shortened))")
            }
        }

        lines.append("")
        lines.append("RECENT WORKOUTS (date | sport | min | km | avg HR | load)")
        for workout in snapshot.workouts.suffix(compact ? 8 : 25) {
            lines.append([
                Self.dayLabel(workout.start, calendar: calendar),
                workout.sport,
                Self.num(workout.durationMinutes, 0),
                Self.num(workout.distanceKm, 1),
                Self.num(workout.averageHeartRate, 0),
                Self.num(metrics.workoutLoad[workout.id], 0),
            ].joined(separator: " | "))
        }

        lines.append("")
        let planDays = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: planStart) }
        lines.append("Write the 7-day plan for these days, in this order, using these exact labels: \(planDays.map { Self.dayLabel($0, calendar: calendar) }.joined(separator: ", ")).")
        return lines.joined(separator: "\n")
    }

    /// "Mon 27 Oct": no commas, so labels can be listed unambiguously.
    static func dayLabel(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }

    static func num(_ value: Double?, _ digits: Int) -> String {
        guard let value, value.isFinite else { return "–" }
        return value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}
