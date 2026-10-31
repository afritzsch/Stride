import Foundation
import FoundationModels

/// The weekly analysis, per-workout coach reviews, and the single place that calls the model.
extension AppModel {
    // MARK: - Weekly analysis

    func runAnalysis() async {
        guard let snapshot, let metrics, !isAnalyzing else { return }
        analysisError = nil
        analysisNotice = nil
        isAnalyzing = true
        defer {
            isAnalyzing = false
            analysisPreview = nil
            analysisStep = nil
            writeDebugState()
        }

        let calendar = Calendar.current
        let planStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        await schedule.refresh()
        let availability = (full: schedule.availability(start: planStart, compact: false), compact: schedule.availability(start: planStart, compact: true))
        func prompt(_ part: PromptBuilder.Part, compact: Bool) -> String {
            PromptBuilder(
                snapshot: snapshot, metrics: metrics, profile: profile, planStart: planStart, compact: compact,
                history: history, reviews: runAnalyses, athleteDays: athleteDays, adjustment: todayAdjustment,
                availability: compact ? availability.compact : availability.full, part: part
            ).prompt
        }

        do {
            let analyzer = AppleAnalyzer(allowPrivateCloud: usesPrivateCloud)
            let compact = prompt(.report, compact: true)
            var result: (output: AnalysisReport, modelName: String, notice: String?)
            if await analyzer.fitsInOneRequest(AnalysisReport.self, instructions: PromptBuilder.instructions, prompt: compact) {
                do {
                    result = try await generate(
                        AnalysisReport.self,
                        instructions: PromptBuilder.instructions,
                        fullPrompt: prompt(.report, compact: false),
                        compactPrompt: compact
                    ) { [weak self] partial in self?.analysisPreview = partial }
                } catch AnalyzerError.contextTooLarge {
                    // The report came out longer than the room kept for it.
                    debugLog("Weekly report overflowed the context window; writing it in two steps")
                    result = try await generateReportInSteps(prompt: prompt)
                }
            } else {
                debugLog("Weekly report doesn't fit one request; writing it in two steps")
                result = try await generateReportInSteps(prompt: prompt)
            }
            var report = result.output
            report.trainingStatus = TrainingStatus.measured(metrics, now: snapshot.fetchedAt, calendar: calendar)
            let labels = PromptBuilder.planLabels(start: planStart, calendar: calendar)
            let pinned = trainingPlan.pinnedDays(start: planStart, calendar: calendar)
            let context = PlanContext(
                metrics: metrics, profile: profile, planStart: planStart,
                freeMinutes: schedule.longestFreeMinutes(start: planStart), calendar: calendar
            )
            let planNotice = await checkPlan(&report, labels: labels, context: context, pinned: pinned)
            analysisNotice = [result.notice, planNotice].compactMap(\.self).joined(separator: " ").nilIfEmpty
            let saved = SavedAnalysis(createdAt: .now, modelName: result.modelName, planStartDate: planStart, report: report)
            history = Array(([saved] + history).prefix(Limits.savedAnalyses))
        } catch {
            analysisError = error.localizedDescription
            debugLog("Weekly analysis failed: \(error)")
        }
    }

    /// The iPhone's on-device window (4096 tokens) can't hold the brief and the whole report, so this writes the
    /// assessment first and then the plan, each in a fresh session with the same brief.
    private func generateReportInSteps(
        prompt: (PromptBuilder.Part, _ compact: Bool) -> String
    ) async throws -> (output: AnalysisReport, modelName: String, notice: String?) {
        analysisPreview = nil
        let assessment = try await generate(
            AnalysisAssessment.self,
            instructions: PromptBuilder.instructions(for: .assessment),
            fullPrompt: prompt(.assessment, false),
            compactPrompt: prompt(.assessment, true)
        ) { [weak self] partial in self?.analysisPreview = AnalysisReport.PartiallyGenerated(partial) }

        analysisStep = "Planning your week…"
        let summary = PromptBuilder.quote("\(assessment.output.headline) \(assessment.output.assessment)", limit: 500)
        let plan = try await generate(
            WeekPlan.self,
            instructions: PromptBuilder.instructions(for: .plan(assessment: summary)),
            fullPrompt: prompt(.plan(assessment: summary), false),
            compactPrompt: prompt(.plan(assessment: summary), true),
            options: AppleAnalyzer.precise
        ) { [weak self] partial in self?.analysisPreview?.weekPlan = partial.days }

        return (assessment.output.report(weekPlan: plan.output.days), plan.modelName, assessment.notice ?? plan.notice)
    }

    /// Fixes in code what needs no judgment (labels, rest days, training days, minutes, hard days in a row), then
    /// asks the model once to fix what's left (e.g. sessions longer than the free time). Returns a notice when code
    /// changed the plan or problems remain.
    private func checkPlan(_ report: inout AnalysisReport, labels: [String], context: PlanContext, pinned: [Int: PlannedDay]) async -> String? {
        let outcome = await PlanRepair.run(&report, labels: labels, profile: profile, context: context, pinned: pinned, log: { debugLog($0) }) { instructions, prompt in
            analysisStep = "Fixing the plan…"
            analysisPreview?.weekPlan = nil
            return try await generate(WeekPlan.self, instructions: instructions, fullPrompt: prompt, compactPrompt: prompt, options: AppleAnalyzer.precise).output
        }
        let days = Set(outcome.changes.compactMap { $0.split(separator: ":").first }).count
        let changed = days == 0 ? nil : "Stride eased \(days == 1 ? "1 day" : "\(days) days") of the plan to fit your settings and recent training."
        let left = outcome.problems.isEmpty ? nil : "Check the plan: it may not fit your settings (\(outcome.problems.count == 1 ? "1 problem" : "\(outcome.problems.count) problems") left)."
        return [changed, left].compactMap(\.self).joined(separator: " ").nilIfEmpty
    }

    func deleteAnalyses(at offsets: IndexSet) {
        var remaining = history
        for index in offsets.sorted(by: >) { remaining.remove(at: index) }
        history = remaining
    }

    // MARK: - Workout reviews

    /// Reviews workouts from the last two days that have no review yet, one at a time. Each is tried once, so a
    /// failure (or a workout the model can't handle) doesn't repeat on every refresh. In the background the model
    /// often can't run, so a failure there doesn't count as the try: the app tries again when it opens.
    func reviewNewWorkouts(inBackground: Bool = false) async {
        guard autoReviewWorkouts, currentAIBlocker() == nil, let snapshot else { return }
        let since = Date.now.addingTimeInterval(-Limits.autoReviewWindow)
        var tried = AutoReviewLog()
        // Oldest first, so trimming the log keeps the most recent IDs.
        let candidates = snapshot.workouts.reversed()
            .filter { $0.start >= since && runAnalyses[$0.id] == nil && !tried.contains($0.id) && !analyzingWorkoutIDs.contains($0.id) }
            .prefix(Limits.autoReviewBatch)
        for workout in candidates {
            tried.add(workout.id)
            do {
                let detail = try await workoutDetail(for: workout)
                _ = try await analyzeWorkout(detail, note: "")
                debugLog("Auto-reviewed \(workout.sport) on \(workout.start.formatted())")
            } catch {
                // Cancelled by a newer refresh, or failed in the background where the model often can't run: leave
                // it for the next try instead of marking it as tried.
                if Task.isCancelled || inBackground {
                    tried.remove(workout.id)
                    debugLog("Auto-review \(Task.isCancelled ? "cancelled" : "failed in the background"): \(error)")
                    return
                }
                debugLog("Auto-review failed: \(error)")
            }
        }
    }

    /// Reviews one workout and stores the result. Returns a notice if Apple Intelligence fell back to on-device.
    func analyzeWorkout(_ detail: WorkoutDetail, note: String) async throws -> String? {
        guard let snapshot, let metrics else { throw AnalyzerError.notReady("Health data isn't loaded yet.") }
        if let blocker = currentAIBlocker() { throw AnalyzerError.notReady(blocker) }
        let id = detail.summary.id
        guard analyzingWorkoutIDs.insert(id).inserted else { return nil }
        defer { analyzingWorkoutIDs.remove(id) }

        let strengthSession = strength.session(for: detail.summary)
        let strengthHistory = strength.sessions ?? []
        func prompt(compact: Bool) -> String {
            RunPromptBuilder(
                detail: detail,
                snapshot: snapshot,
                metrics: metrics,
                profile: profile,
                plannedSession: plannedSession(on: detail.summary.start),
                note: note,
                compact: compact,
                strengthSession: strengthSession,
                strengthHistory: strengthHistory
            ).prompt
        }
        defer { runPreviews[id] = nil }
        let instructions = RunPromptBuilder.instructions(for: detail.summary.kind)
        var analysis: RunAnalysis
        let modelName: String
        let notice: String?
        if detail.summary.kind == .strength {
            let result = try await generate(
                StrengthReview.self, instructions: instructions, fullPrompt: prompt(compact: false), compactPrompt: prompt(compact: true)
            ) { [weak self] partial in self?.runPreviews[id] = RunAnalysis.PartiallyGenerated(partial) }
            (analysis, modelName, notice) = (result.output.analysis, result.modelName, result.notice)
        } else {
            let result = try await generate(
                RunAnalysis.self, instructions: instructions, fullPrompt: prompt(compact: false), compactPrompt: prompt(compact: true)
            ) { [weak self] partial in self?.runPreviews[id] = partial }
            (analysis, modelName, notice) = (result.output, result.modelName, result.notice)
            if let measured = EffortLevel.measured(
                zoneSeconds: detail.zoneSeconds(zones: metrics.heartRateZones),
                durationMinutes: detail.summary.durationMinutes
            ) {
                analysis.effort = measured
            }
        }
        runAnalyses[id] = SavedRunAnalysis(
            workoutID: id,
            createdAt: .now,
            modelName: modelName,
            note: note,
            analysis: analysis
        )
        writeDebugState(detail: detail)
        return notice
    }

    // MARK: - The model

    /// Runs one guided generation on Apple Intelligence (Private Cloud Compute when allowed and available, else
    /// on-device). The notice says when it had to fall back.
    func generate<Output: Generable & Sendable>(
        _: Output.Type,
        instructions: String,
        fullPrompt: String,
        compactPrompt: String,
        options: GenerationOptions = AppleAnalyzer.writing,
        onPartial: AppleAnalyzer.PartialHandler<Output>? = nil
    ) async throws -> (output: Output, modelName: String, notice: String?) {
        let result = try await AppleAnalyzer(allowPrivateCloud: usesPrivateCloud).analyze(
            Output.self,
            instructions: instructions,
            fullPrompt: fullPrompt,
            compactPrompt: compactPrompt,
            options: options,
            onPartial: onPartial
        )
        return (result.report, result.route.title, result.fallbackReason.map { "\($0) Used the on-device model instead." })
    }
}

/// The workouts an automatic review already tried, newest last, kept across launches.
private struct AutoReviewLog {
    private var ids = UserDefaults.standard.stringArray(forKey: DefaultsKey.autoReviewAttempted) ?? []

    func contains(_ id: UUID) -> Bool { ids.contains(id.uuidString) }

    mutating func add(_ id: UUID) {
        ids = Array((ids + [id.uuidString]).suffix(AppModel.Limits.autoReviewMemory))
        save()
    }

    mutating func remove(_ id: UUID) {
        ids.removeAll { $0 == id.uuidString }
        save()
    }

    private func save() {
        UserDefaults.standard.set(ids, forKey: DefaultsKey.autoReviewAttempted)
    }
}
