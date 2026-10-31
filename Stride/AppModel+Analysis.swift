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
        func prompt(compact: Bool) -> String {
            PromptBuilder(
                snapshot: snapshot, metrics: metrics, profile: profile, planStart: planStart, compact: compact,
                history: history, reviews: runAnalyses, athleteDays: athleteDays,
                availability: compact ? availability.compact : availability.full
            ).prompt
        }

        do {
            let result = try await generate(
                AnalysisReport.self,
                instructions: PromptBuilder.instructions,
                fullPrompt: prompt(compact: false),
                compactPrompt: prompt(compact: true)
            ) { [weak self] partial in self?.analysisPreview = partial }
            var report = result.output
            let labels = PromptBuilder.planLabels(start: planStart, calendar: calendar)
            let pinned = trainingPlan.pinnedDays(start: planStart, calendar: calendar)
            let planNotice = await checkPlan(&report, labels: labels, pinned: pinned)
            analysisNotice = [result.notice, planNotice].compactMap(\.self).joined(separator: " ").nilIfEmpty
            let saved = SavedAnalysis(createdAt: .now, modelName: result.modelName, planStartDate: planStart, report: report)
            history = Array(([saved] + history).prefix(Limits.savedAnalyses))
        } catch {
            analysisError = error.localizedDescription
            debugLog("Weekly analysis failed: \(error)")
        }
    }

    /// Fixes labels and rest days in code, then asks the model once to fix rules it broke (hours, training days,
    /// back-to-back hard days). Returns a notice when problems remain.
    private func checkPlan(_ report: inout AnalysisReport, labels: [String], pinned: [Int: PlannedDay]) async -> String? {
        let problems = await PlanRepair.run(&report, labels: labels, profile: profile, pinned: pinned, log: { debugLog($0) }) { instructions, prompt in
            analysisStep = "Fixing the plan…"
            analysisPreview?.weekPlan = nil
            return try await generate(WeekPlan.self, instructions: instructions, fullPrompt: prompt, compactPrompt: prompt).output
        }
        guard !problems.isEmpty else { return nil }
        return "Check the plan: it may not fit your settings (\(problems.count == 1 ? "1 problem" : "\(problems.count) problems") left)."
    }

    func deleteAnalyses(at offsets: IndexSet) {
        var remaining = history
        for index in offsets.sorted(by: >) { remaining.remove(at: index) }
        history = remaining
    }

    // MARK: - Workout reviews

    /// Reviews workouts from the last two days that have no review yet, one at a time. Each is tried once, so a
    /// failure (or a workout the model can't handle) doesn't repeat on every refresh.
    func reviewNewWorkouts() async {
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
                // Cancelled by a newer refresh: leave it for that one instead of marking it as tried.
                if Task.isCancelled {
                    tried.remove(workout.id)
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
        let result = try await generate(
            RunAnalysis.self,
            instructions: RunPromptBuilder.instructions(for: detail.summary.kind),
            fullPrompt: prompt(compact: false),
            compactPrompt: prompt(compact: true)
        ) { [weak self] partial in self?.runPreviews[id] = partial }
        var analysis = result.output
        if detail.summary.kind == .strength {
            analysis.effort = nil
        } else if let measured = EffortLevel.measured(
            zoneSeconds: detail.zoneSeconds(zones: metrics.heartRateZones),
            durationMinutes: detail.summary.durationMinutes
        ) {
            analysis.effort = measured
        }
        runAnalyses[id] = SavedRunAnalysis(
            workoutID: id,
            createdAt: .now,
            modelName: result.modelName,
            note: note,
            analysis: analysis
        )
        writeDebugState(detail: detail)
        return result.notice
    }

    // MARK: - The model

    /// Runs one guided generation on Apple Intelligence (Private Cloud Compute when allowed and available, else
    /// on-device). The notice says when it had to fall back.
    func generate<Output: Generable & Sendable>(
        _: Output.Type,
        instructions: String,
        fullPrompt: String,
        compactPrompt: String,
        onPartial: AppleAnalyzer.PartialHandler<Output>? = nil
    ) async throws -> (output: Output, modelName: String, notice: String?) {
        let result = try await AppleAnalyzer(allowPrivateCloud: usesPrivateCloud).analyze(
            Output.self,
            instructions: instructions,
            fullPrompt: fullPrompt,
            compactPrompt: compactPrompt,
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
