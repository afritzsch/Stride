import Foundation

/// Turns health data into a compact text brief. `compact` keeps the on-device model inside its small context window.
nonisolated struct PromptBuilder {
    var snapshot: HealthSnapshot
    var metrics: MetricsReport
    var profile: UserProfile
    var planStart: Date
    var compact: Bool
    /// Earlier analyses, newest first: their plans (to compare with what happened) and their verdicts.
    var history: [SavedAnalysis] = []
    /// Coach reviews by workout ID, with the athlete's notes.
    var reviews: [UUID: SavedRunAnalysis] = [:]
    /// Days the athlete planned themselves. They count for plan vs actual, and the new plan keeps them.
    var athleteDays: [AthletePlanDay] = []
    /// Free time and rain per plan day (`SessionScheduler.availabilityLine`), empty when the calendar isn't used.
    var availability: [String] = []
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
        - LAST PLAN VS ACTUAL shows how your previous plan went. Build on it: repeat a missed key session only \
        if recovery allows, never cram missed work into the new week, and if sessions keep being missed or changed, \
        make the plan fit the athlete's real routine.
        - SESSION FEEDBACK holds the athlete's own words after sessions. Take pain, illness or unusual fatigue \
        seriously and adjust the plan for it.
        - THE ATHLETE'S OWN PLAN lists days the athlete already planned: copy them exactly into the plan and plan \
        the other days around them, including rest and hard-easy spacing.
        - FREE TIME shows open time in the athlete's calendar and the forecast: put long sessions on days with \
        enough free time, and outdoor sessions away from rain when you can.
        - COACH LOG lists your earlier verdicts. Stay consistent with them unless the data changed, and then say \
        what changed.
        - Body weight is context, not a target: mention it only when it matters for training (e.g. a fast drop \
        alongside rising load can mean under-fueling). Don't give dieting advice.
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
        if let weight = ind.latestWeightKg, let date = ind.latestWeightDate {
            lines.append("- Body weight: \(Self.num(weight, 1)) kg (weighed \(Self.dayLabel(date, calendar: calendar))); avg 7 d / 28 d: \(Self.num(ind.weight7, 1)) / \(Self.num(ind.weight28, 1)) kg")
        }
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
        // Most people don't weigh themselves; leave the column out rather than fill it with "–".
        let hasWeight = ind.latestWeightKg != nil
        lines.append("WEEKLY (week starting | sessions | minutes | km | load | hard | sleep h | steps | RHR | HRV\(hasWeight ? " | weight kg" : ""))")
        for week in metrics.weeks.suffix(compact ? 4 : 8) {
            let inProgress = (calendar.date(byAdding: .day, value: 7, to: week.weekStart) ?? week.weekStart) > snapshot.fetchedAt
            var columns = [
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
            ]
            if hasWeight { columns.append(Self.num(week.avgWeightKg, 1)) }
            lines.append(columns.joined(separator: " | "))
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

        lines.append(contentsOf: memorySections)

        if !availability.isEmpty {
            lines.append("")
            lines.append("FREE TIME (day | free time in the calendar, from the athlete's earliest to latest training time | weather)")
            lines += availability
        }
        let plan = TrainingPlan(analyses: history, athleteDays: athleteDays)
        let labels = Self.planLabels(start: planStart, calendar: calendar)
        let pinned = plan.pinnedDays(start: planStart, calendar: calendar).sorted { $0.key < $1.key }
        if !pinned.isEmpty {
            lines.append("")
            lines.append("THE ATHLETE'S OWN PLAN (day | session | details); keep these days exactly")
            for (index, day) in pinned {
                lines.append("\(labels[index]) | \(day.briefDescription) | \(Self.quote(day.details))")
            }
        }

        lines.append("")
        lines.append("Write the 7-day plan for these days, in this order, using these exact labels: \(labels.joined(separator: ", ")).")
        return lines.joined(separator: "\n")
    }

    /// Plan vs actual, the athlete's session notes and earlier verdicts, so each analysis builds on the last.
    private var memorySections: [String] {
        var lines: [String] = []
        let adherence = PlanAdherence(
            plan: TrainingPlan(analyses: history, athleteDays: athleteDays),
            workouts: snapshot.workouts,
            zones: metrics.heartRateZones,
            now: snapshot.fetchedAt,
            calendar: calendar
        ).completed
        if !adherence.isEmpty {
            // The compact brief (small on-device context) keeps only the days that didn't go to plan.
            let shown = compact ? adherence.filter { $0.status != .done && $0.status != .rested } : adherence
            lines.append("")
            lines.append("LAST PLAN VS ACTUAL (day | planned | recorded | result)\(compact ? ", days that differed" : "")")
            for day in shown {
                let recorded = day.workouts.isEmpty ? "–" : day.workouts.map { workout in
                    "\(workout.sport) \(Self.num(workout.durationMinutes, 0)) min" + (workout.averageHeartRate.map { ", avg HR \(Self.num($0, 0))" } ?? "")
                }.joined(separator: " + ")
                let result = ([day.status.title.lowercased()] + day.notes).joined(separator: "; ")
                lines.append("\(Self.dayLabel(day.date, calendar: calendar)) | \(day.planned.briefDescription) | \(recorded) | \(result)")
            }
            lines.append("Summary: \(PlanAdherence.summary(of: adherence))")
        }

        let since = calendar.date(byAdding: .day, value: compact ? -7 : -14, to: snapshot.fetchedAt) ?? snapshot.fetchedAt
        let feedback = snapshot.workouts.reversed()
            .filter { $0.start >= since }
            .compactMap { workout in reviews[workout.id].map { (workout, $0) } }
            .prefix(compact ? 2 : 6)
        if !feedback.isEmpty {
            lines.append("")
            lines.append("SESSION FEEDBACK, NEWEST FIRST (day | sport | effort | your verdict | athlete's note)")
            for (workout, review) in feedback {
                lines.append([
                    Self.dayLabel(workout.start, calendar: calendar),
                    workout.sport,
                    // Strength reviews saved before they stopped getting an effort carry a meaningless one.
                    (workout.kind == .strength ? nil : review.analysis.effort)?.rawValue ?? "–",
                    review.analysis.headline,
                    Self.quote(review.note),
                ].joined(separator: " | "))
            }
        }

        // One verdict per week (the newest), so re-running an analysis doesn't crowd out older weeks.
        var seenWeeks = Set<Date>()
        let log = history.filter { analysis in
            let week = calendar.dateInterval(of: .weekOfYear, for: analysis.createdAt)?.start ?? analysis.createdAt
            return seenWeeks.insert(week).inserted
        }.prefix(compact ? 2 : 6)
        if !log.isEmpty {
            lines.append("")
            lines.append("COACH LOG, NEWEST FIRST (date | training status | your headline)")
            for analysis in log {
                lines.append("\(Self.dayLabel(analysis.createdAt, calendar: calendar)) | \(analysis.report.trainingStatus.rawValue) | \(analysis.report.headline)")
            }
        }
        return lines
    }

    /// Labels of the seven plan days from `start`.
    static func planLabels(start: Date, calendar: Calendar) -> [String] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }.map { dayLabel($0, calendar: calendar) }
    }

    /// One line, at most 160 characters, or "–" when empty.
    static func quote(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return "–" }
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
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
