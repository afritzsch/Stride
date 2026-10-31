import Foundation

/// Today's readiness-based adjustment, and everything about the plan: the coach's weekly plans, the athlete's own
/// days and the lookups that merge them.
extension AppModel {
    // MARK: - Today

    var readiness: Readiness? {
        guard let snapshot, let metrics else { return nil }
        return Readiness(snapshot: snapshot, metrics: metrics, profile: profile)
    }

    /// Today's session in the plan, including an applied adjustment.
    var todaysPlan: PlannedDay? { plannedSession(on: .now) }

    var todaysWorkouts: [WorkoutSummary] {
        (snapshot?.workouts ?? []).filter { Calendar.current.isDateInToday($0.start) }
    }

    /// Suggests a lighter session when readiness is down and a session is still to do. It runs by itself once a day
    /// (it's free and on-device); the plan only changes when the athlete accepts.
    func adjustTodayIfNeeded(automatically: Bool) async {
        guard currentAIBlocker() == nil, !isAdjustingToday, todayAdjustment == nil || !automatically,
              let snapshot, let metrics, snapshot.isEmpty == false,
              let planned = todaysPlan, !planned.isRest, todaysWorkouts.isEmpty else { return }
        let readiness = Readiness(snapshot: snapshot, metrics: metrics, profile: profile)
        guard readiness.suggestsAdjusting else { return }

        isAdjustingToday = true
        adjustmentError = nil
        defer { isAdjustingToday = false }
        let prompt = DayAdjustment.prompt(planned: planned, readiness: readiness, metrics: metrics, profile: profile)
        do {
            let result = try await generate(DayAdjustment.self, instructions: DayAdjustment.instructions, fullPrompt: prompt, compactPrompt: prompt, options: AppleAnalyzer.precise)
            todayAdjustment = SavedAdjustment(date: .now, original: planned, adjustment: result.output.clamped(to: planned))
        } catch {
            // An automatic attempt fails quietly; the button stays for a manual retry.
            if !automatically { adjustmentError = error.localizedDescription }
            debugLog("Today's adjustment failed: \(error)")
        }
    }

    func resolveTodayAdjustment(accept: Bool) {
        guard var adjustment = todayAdjustment, adjustment.state == .suggested else { return }
        if accept {
            var session = adjustment.adjustment.session
            session.details = [adjustment.adjustment.reason, session.details].filter { !$0.isEmpty }.joined(separator: " ")
            updatePlannedDay(on: adjustment.date, with: session)
        }
        adjustment.state = accept ? .accepted : .declined
        todayAdjustment = adjustment
    }

    // MARK: - Changing the plan

    /// A coach change to one day (the readiness adjustment, the chat): it changes the athlete's own day if there is
    /// one, otherwise the newest plan that covers the date, otherwise it becomes an athlete day.
    func updatePlannedDay(on date: Date, with day: PlannedDay) {
        let calendar = Calendar.current
        var day = day
        day.day = PromptBuilder.dayLabel(date, calendar: calendar)
        if trainingPlan.athleteDay(on: date, calendar: calendar) != nil {
            setAthleteDay(day, on: date)
            return
        }
        for (index, analysis) in history.enumerated() {
            guard analysis.plannedDay(on: date, calendar: calendar) != nil,
                  let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: analysis.planStartDate), to: calendar.startOfDay(for: date)).day
            else { continue }
            history[index].report.weekPlan[offset] = day
            schedule.sessionChanged(on: date)
            return
        }
        setAthleteDay(day, on: date)
    }

    /// Saves a day the athlete planned. Old days are dropped (`Limits.athleteDayRetentionDays`).
    func setAthleteDay(_ day: PlannedDay, on date: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        var day = PlanCheck.normalized([day], labels: [PromptBuilder.dayLabel(start, calendar: calendar)])[0]
        if day.session.trimmingCharacters(in: .whitespaces).isEmpty { day.session = day.defaultTitle }
        let cutoff = calendar.date(byAdding: .day, value: -Limits.athleteDayRetentionDays, to: calendar.startOfDay(for: .now)) ?? start
        var days = athleteDays.filter { !calendar.isDate($0.date, inSameDayAs: start) && $0.date >= cutoff }
        days.append(AthletePlanDay(date: start, day: day, savedAt: .now))
        athleteDays = days.sorted { $0.date < $1.date }
        schedule.sessionChanged(on: start)
        writeDebugState()
    }

    /// Goes back to the coach's plan for a date.
    func removeAthleteDay(on date: Date) {
        athleteDays.removeAll { Calendar.current.isDate($0.date, inSameDayAs: date) }
        schedule.sessionChanged(on: date)
        writeDebugState()
    }

    // MARK: - Looking up the plan

    var trainingPlan: TrainingPlan { TrainingPlan(analyses: history, athleteDays: athleteDays) }

    /// How the planned days of the last week went.
    var planAdherence: PlanAdherence? {
        guard let snapshot, let metrics else { return nil }
        return PlanAdherence(plan: trainingPlan, workouts: snapshot.workouts, zones: metrics.heartRateZones)
    }

    /// The session planned for that day: the athlete's own, else the newest weekly plan that covers it.
    func plannedSession(on date: Date) -> PlannedDay? {
        trainingPlan.plannedDay(on: date)
    }

    func isAthletePlanned(on date: Date) -> Bool {
        trainingPlan.athleteDay(on: date) != nil
    }

    /// What the coach planned for that day, ignoring the athlete's change.
    func coachSession(on date: Date) -> PlannedDay? {
        trainingPlan.coachDay(on: date)
    }
}
