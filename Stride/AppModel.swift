import Foundation
import FoundationModels
import Observation

enum AppTab: String, Hashable {
    case dashboard, progress, coach, plan, settings
}

enum DashboardDestination: Hashable {
    case allWorkouts
    case workout(WorkoutSummary)
    case metric(DashboardMetric)
}

@Observable
final class AppModel {
    var profile: UserProfile {
        didSet {
            persist(profile, key: Keys.profile)
            recomputeMetrics()
        }
    }
    var useDemoData: Bool {
        didSet {
            UserDefaults.standard.set(useDemoData, forKey: Keys.demo)
            Task { await refresh() }
        }
    }
    /// Apple Intelligence: use the larger Private Cloud Compute model when available.
    var allowPrivateCloud: Bool {
        didSet { UserDefaults.standard.set(allowPrivateCloud, forKey: Keys.privateCloud) }
    }
    var usesPrivateCloud: Bool { allowPrivateCloud && AppleAnalyzer.isPrivateCloudInBuild }
    /// Review new workouts on the device as they sync (it's free and private).
    var autoReviewWorkouts: Bool {
        didSet { UserDefaults.standard.set(autoReviewWorkouts, forKey: Keys.autoReview) }
    }

    private(set) var snapshot: HealthSnapshot?
    private(set) var metrics: MetricsReport?
    private(set) var needsHealthAuthorization = false
    private(set) var isLoadingHealth = false
    private(set) var healthError: String?
    /// Levels, records and period totals over all history (the archive plus the current snapshot).
    private(set) var progress: ProgressReport?
    private(set) var isLoadingArchive = false
    /// Years of history before the snapshot, for the progress screen. Cached on disk because reading it takes a while.
    private var archive: HealthSnapshot?

    private(set) var history: [SavedAnalysis]
    private(set) var isAnalyzing = false
    /// Workouts with a coach review in flight, so leaving and reopening a workout can't start a second one.
    private(set) var analyzingWorkoutIDs: Set<UUID> = []
    var analysisError: String?
    /// Explains why the last analysis didn't use Private Cloud Compute.
    private(set) var analysisNotice: String?
    /// Per-workout coach feedback, keyed by workout ID.
    private(set) var runAnalyses: [UUID: SavedRunAnalysis]
    /// What's been written so far while Apple Intelligence streams the weekly analysis.
    private(set) var analysisPreview: AnalysisReport.PartiallyGenerated?
    /// What the running analysis is doing besides writing, e.g. checking the plan.
    private(set) var analysisStep: String?
    /// Coach reviews being streamed, by workout ID.
    private(set) var runPreviews: [UUID: RunAnalysis.PartiallyGenerated] = [:]
    /// Today's readiness-based change to the plan, once suggested.
    private(set) var todayAdjustment: SavedAdjustment? {
        didSet { persist(todayAdjustment, key: Keys.todayAdjustment) }
    }
    private(set) var isAdjustingToday = false
    /// The "Ask the coach" conversation, kept while the app runs.
    @ObservationIgnored private(set) lazy var chat = CoachChat(model: self)
    private(set) var adjustmentError: String?

    var selectedTab = AppTab.dashboard
    var showsCoachChat = false
    var dashboardPath: [DashboardDestination] = []
    var progressPath: [Skill] = []

    /// Exported real data replayed instead of HealthKit (debug builds; see AppModel+Debug).
    var fixture: HealthFixture?
    /// Last workout opened, included in the debug state dump.
    @ObservationIgnored var debugDetail: WorkoutDetail?
    /// Recent errors and notices, included in the debug state dump.
    @ObservationIgnored var debugEvents: [String] = []
    /// The -scrollTo/-analyze launch hooks apply to the first workout opened only.
    @ObservationIgnored var launchHooksConsumed = false
    /// Bumped by each refresh so a slower, older one (e.g. after toggling demo data) can't overwrite a newer result.
    @ObservationIgnored private var refreshGeneration = 0
    let health = HealthKitService()

    var latestAnalysis: SavedAnalysis? { history.first }

    /// 28-day resting HR median, or a typical value until there's data.
    var restingHRBaseline: Double { metrics?.indicators.restingHRBaseline ?? 60 }
    var heartRateZones: HeartRateZones { metrics?.heartRateZones ?? profile.heartRateZones(restingHR: restingHRBaseline) }

    /// nil when Apple Intelligence can run, otherwise why not.
    var aiBlocker: String? {
        AppleAnalyzer.unavailableReason(allowPrivateCloud: usesPrivateCloud)
    }

    init() {
        let defaults = UserDefaults.standard
        profile = defaults.data(forKey: Keys.profile).flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) } ?? UserProfile()
        // Default to demo data where HealthKit doesn't exist (e.g. iPad).
        // bool(forKey:) also understands "YES"/"NO" strings, e.g. from launch arguments.
        useDemoData = defaults.object(forKey: Keys.demo) != nil ? defaults.bool(forKey: Keys.demo) : !HealthKitService.isAvailable
        allowPrivateCloud = defaults.object(forKey: Keys.privateCloud) != nil ? defaults.bool(forKey: Keys.privateCloud) : true
        autoReviewWorkouts = defaults.object(forKey: Keys.autoReview) != nil ? defaults.bool(forKey: Keys.autoReview) : true
        history = JSONStore.load([SavedAnalysis].self, from: JSONStore.analyses) ?? []
        todayAdjustment = defaults.data(forKey: Keys.todayAdjustment)
            .flatMap { try? JSONDecoder().decode(SavedAdjustment.self, from: $0) }
            .flatMap { Calendar.current.isDateInToday($0.date) ? $0 : nil }
        let savedRuns = JSONStore.load([SavedRunAnalysis].self, from: JSONStore.runAnalyses) ?? []
        runAnalyses = Dictionary(savedRuns.map { ($0.workoutID, $0) }, uniquingKeysWith: { latest, _ in latest })
        archive = JSONStore.load(HealthSnapshot.self, from: JSONStore.archive)
        #if DEBUG
        fixture = Self.loadFixture()
        #endif
        Self.removeClaudeSettings()
    }

    /// Earlier versions could use Claude with the user's own Anthropic key; don't leave that key behind.
    private static func removeClaudeSettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Keys.removedClaude) else { return }
        LegacyKeychain.deleteAnthropicKey()
        defaults.removeObject(forKey: "engine")
        defaults.set(true, forKey: Keys.removedClaude)
    }

    // MARK: - Health data

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        healthError = nil
        defer {
            writeDebugState()
            if generation == refreshGeneration { Task { await refreshArchive() } }
        }
        if let fixture {
            snapshot = fixture.snapshot
            needsHealthAuthorization = false
            recomputeMetrics()
            return
        }
        if useDemoData {
            snapshot = DemoData.snapshot()
            needsHealthAuthorization = false
            recomputeMetrics()
            return
        }
        // Don't keep showing (or analyzing) demo data once it's switched off.
        if snapshot?.isDemo == true {
            snapshot = nil
            metrics = nil
        }
        guard HealthKitService.isAvailable else {
            healthError = "Apple Health isn't available on this device."
            return
        }
        let needsAuthorization = await health.needsAuthorizationPrompt()
        guard generation == refreshGeneration else { return }
        needsHealthAuthorization = needsAuthorization
        guard !needsAuthorization else { return }

        isLoadingHealth = true
        defer { if generation == refreshGeneration { isLoadingHealth = false } }
        do {
            let fetched = try await health.fetchSnapshot()
            guard generation == refreshGeneration else { return }
            snapshot = fetched
            recomputeMetrics()
        } catch {
            guard generation == refreshGeneration else { return }
            healthError = error.localizedDescription
        }
    }

    func connectHealth() async {
        do {
            try await health.requestAuthorization()
            await refresh()
        } catch {
            healthError = error.localizedDescription
        }
    }

    /// Demo data and fixtures are replayed, so weigh-ins only go to Apple Health when it's the data source.
    var savesToHealth: Bool { fixture == nil && snapshot?.isDemo != true }

    /// Saves a weigh-in to Apple Health, or for demo data and fixtures only to the data in memory (until the next refresh).
    func logWeight(kg: Double, at date: Date) async throws {
        guard savesToHealth else {
            let calendar = Calendar.current
            guard var updated = snapshot,
                  let index = updated.days.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: date) }) else { return }
            updated.days[index].bodyMassKg = kg
            snapshot = updated
            recomputeMetrics()
            writeDebugState()
            return
        }
        try await health.saveBodyMass(kg: kg, at: date)
        await refresh()
    }

    private func recomputeMetrics() {
        metrics = snapshot.map { MetricsReport(snapshot: $0, profile: profile) }
        // Never mix demo history with real data (or the reverse) while the archive catches up after a switch.
        let archive = archive?.isDemo == snapshot?.isDemo ? archive : nil
        progress = snapshot.map { ProgressReport(snapshot: $0.prepending(archive), profile: profile) }
    }

    /// Loads the long history behind the snapshot. Apple Health is reread at most once a week unless forced,
    /// since years of workouts and sleep take a while; the snapshot covers recent changes in between.
    func refreshArchive(force: Bool = false) async {
        guard let snapshot, !isLoadingArchive else { return }
        if fixture != nil {
            // Fixtures only hold the snapshot window.
            archive = nil
        } else if snapshot.isDemo {
            archive = DemoData.archive(before: snapshot.days.first?.date ?? snapshot.fetchedAt)
        } else {
            if archive?.isDemo != false { archive = JSONStore.load(HealthSnapshot.self, from: JSONStore.archive) }
            if force || archive.map({ Date.now.timeIntervalSince($0.fetchedAt) > Self.archiveMaxAge }) ?? true {
                isLoadingArchive = true
                defer { isLoadingArchive = false }
                do {
                    let fetched = try await health.fetchHistory()
                    // Demo data or a fixture may have been switched on meanwhile.
                    guard self.snapshot?.isDemo == false, fixture == nil else { return }
                    archive = fetched
                    JSONStore.save(fetched, to: JSONStore.archive)
                } catch {
                    debugLog("Reading history failed: \(error)")
                }
            }
        }
        recomputeMetrics()
        writeDebugState()
    }

    // MARK: - Analysis

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
        func prompt(compact: Bool) -> String {
            PromptBuilder(
                snapshot: snapshot, metrics: metrics, profile: profile, planStart: planStart, compact: compact,
                history: history, reviews: runAnalyses
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
            let planNotice = await checkPlan(&report, labels: labels)
            analysisNotice = [result.notice, planNotice].compactMap(\.self).joined(separator: " ").nilIfEmpty
            let saved = SavedAnalysis(createdAt: .now, modelName: result.modelName, planStartDate: planStart, report: report)
            history = Array(([saved] + history).prefix(Self.maxSavedAnalyses))
            JSONStore.save(history, to: JSONStore.analyses)
        } catch {
            analysisError = error.localizedDescription
            debugLog("Weekly analysis failed: \(error)")
        }
    }

    /// Fixes labels and rest days in code, then asks the model once to fix rules it broke (hours, training days,
    /// back-to-back hard days). Returns a notice when problems remain.
    private func checkPlan(_ report: inout AnalysisReport, labels: [String]) async -> String? {
        let problems = await PlanRepair.run(&report, labels: labels, profile: profile, log: { debugLog($0) }) { instructions, prompt in
            analysisStep = "Fixing the plan…"
            analysisPreview?.weekPlan = nil
            return try await generate(WeekPlan.self, instructions: instructions, fullPrompt: prompt, compactPrompt: prompt).output
        }
        guard !problems.isEmpty else { return nil }
        return "Check the plan: it may not fit your settings (\(problems.count == 1 ? "1 problem" : "\(problems.count) problems") left)."
    }

    func deleteAnalyses(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) { history.remove(at: index) }
        JSONStore.save(history, to: JSONStore.analyses)
    }

    // MARK: - Single workouts

    func workoutDetail(for workout: WorkoutSummary) async throws -> WorkoutDetail {
        if let fixture {
            guard let raw = fixture.workouts.first(where: { $0.workoutID == workout.id }) else { throw CocoaError(.fileNoSuchFile) }
            return WorkoutDetail.build(summary: workout, raw: raw)
        }
        if snapshot?.isDemo == true { return DemoData.detail(for: workout) }
        return try await health.workoutDetail(for: workout)
    }

    /// Writes everything the app reads to a JSON file for debugging, and returns its location.
    func exportHealthData() async throws -> URL {
        let export: HealthFixture
        if let fixture {
            export = fixture
        } else if let snapshot, snapshot.isDemo {
            export = HealthFixture(exportedAt: .now, snapshot: snapshot, workouts: snapshot.workouts.map(DemoData.rawWorkout))
        } else {
            export = try await health.exportFixture()
        }
        let url = URL.temporaryDirectory.appending(path: "stride-health-export.json")
        try HealthFixture.encoder().encode(export).write(to: url, options: .atomic)
        return url
    }

    /// Reviews workouts from the last two days that have no review yet, one at a time. Each is tried once, so a
    /// failure (or a workout the model can't handle) doesn't repeat on every refresh.
    func reviewNewWorkouts() async {
        guard autoReviewWorkouts, aiBlocker == nil, let snapshot else { return }
        let since = Date.now.addingTimeInterval(-2 * 24 * 3600)
        // Oldest first, so trimming keeps the most recent IDs.
        var attempted = UserDefaults.standard.stringArray(forKey: Keys.autoReviewAttempted) ?? []
        let candidates = snapshot.workouts.reversed()
            .filter { $0.start >= since && runAnalyses[$0.id] == nil && !attempted.contains($0.id.uuidString) && !analyzingWorkoutIDs.contains($0.id) }
            .prefix(3)
        for workout in candidates {
            attempted = Array((attempted + [workout.id.uuidString]).suffix(50))
            UserDefaults.standard.set(attempted, forKey: Keys.autoReviewAttempted)
            do {
                let detail = try await workoutDetail(for: workout)
                _ = try await analyzeWorkout(detail, note: "")
                debugLog("Auto-reviewed \(workout.sport) on \(workout.start.formatted())")
            } catch {
                // Cancelled by a newer refresh: leave it for that one instead of marking it as tried.
                if Task.isCancelled {
                    attempted.removeAll { $0 == workout.id.uuidString }
                    UserDefaults.standard.set(attempted, forKey: Keys.autoReviewAttempted)
                    return
                }
                debugLog("Auto-review failed: \(error)")
            }
        }
    }

    /// Reviews one workout and stores the result. Returns a notice if Apple Intelligence fell back to on-device.
    func analyzeWorkout(_ detail: WorkoutDetail, note: String) async throws -> String? {
        guard let snapshot, let metrics else { throw AnalyzerError.notReady("Health data isn't loaded yet.") }
        if let blocker = aiBlocker { throw AnalyzerError.notReady(blocker) }
        let id = detail.summary.id
        guard analyzingWorkoutIDs.insert(id).inserted else { return nil }
        defer { analyzingWorkoutIDs.remove(id) }

        func prompt(compact: Bool) -> String {
            RunPromptBuilder(
                detail: detail,
                snapshot: snapshot,
                metrics: metrics,
                profile: profile,
                plannedSession: plannedSession(on: detail.summary.start),
                note: note,
                compact: compact
            ).prompt
        }
        defer { runPreviews[id] = nil }
        let result = try await generate(
            RunAnalysis.self,
            instructions: RunPromptBuilder.instructions,
            fullPrompt: prompt(compact: false),
            compactPrompt: prompt(compact: true)
        ) { [weak self] partial in self?.runPreviews[id] = partial }
        var analysis = result.output
        if let measured = EffortLevel.measured(
            zoneSeconds: detail.zoneSeconds(zones: metrics.heartRateZones),
            durationMinutes: detail.summary.durationMinutes
        ) {
            analysis.effort = measured
        }
        runAnalyses[detail.summary.id] = SavedRunAnalysis(
            workoutID: detail.summary.id,
            createdAt: .now,
            modelName: result.modelName,
            note: note,
            analysis: analysis
        )
        JSONStore.save(Array(runAnalyses.values), to: JSONStore.runAnalyses)
        writeDebugState(detail: detail)
        return result.notice
    }

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
        guard aiBlocker == nil, !isAdjustingToday, todayAdjustment == nil || !automatically,
              let snapshot, let metrics, snapshot.isEmpty == false,
              let planned = todaysPlan, !planned.isRest, todaysWorkouts.isEmpty else { return }
        let readiness = Readiness(snapshot: snapshot, metrics: metrics, profile: profile)
        guard readiness.suggestsAdjusting else { return }

        isAdjustingToday = true
        adjustmentError = nil
        defer { isAdjustingToday = false }
        let prompt = DayAdjustment.prompt(planned: planned, readiness: readiness, metrics: metrics, profile: profile)
        do {
            let result = try await generate(DayAdjustment.self, instructions: DayAdjustment.instructions, fullPrompt: prompt, compactPrompt: prompt)
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
            guard updatePlannedDay(on: adjustment.date, with: session) else { return }
        }
        adjustment.state = accept ? .accepted : .declined
        todayAdjustment = adjustment
    }

    /// Replaces a day in the newest plan that covers it. Returns false when no saved plan covers the date.
    @discardableResult
    func updatePlannedDay(on date: Date, with day: PlannedDay) -> Bool {
        let calendar = Calendar.current
        for (index, analysis) in history.enumerated() {
            guard analysis.plannedDay(on: date, calendar: calendar) != nil,
                  let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: analysis.planStartDate), to: calendar.startOfDay(for: date)).day
            else { continue }
            var day = day
            day.day = PromptBuilder.dayLabel(date, calendar: calendar)
            history[index].report.weekPlan[offset] = day
            JSONStore.save(history, to: JSONStore.analyses)
            return true
        }
        return false
    }

    /// How the planned days of the last week went.
    var planAdherence: PlanAdherence? {
        guard let snapshot, let metrics else { return nil }
        return PlanAdherence(history: history, workouts: snapshot.workouts, zones: metrics.heartRateZones)
    }

    /// The session the latest weekly plan had for that day, if the plan covers it.
    func plannedSession(on date: Date) -> PlannedDay? {
        history.plannedDay(on: date)
    }

    private func generate<Output: Generable & Sendable>(
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

    // MARK: - Persistence

    private func persist(_ value: some Encodable, key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static let maxSavedAnalyses = 30
    private static let archiveMaxAge: TimeInterval = 7 * 86400

    private enum Keys {
        static let profile = "profile"
        static let demo = "useDemoData"
        static let removedClaude = "removedClaudeSettings"
        static let privateCloud = "allowPrivateCloud"
        static let todayAdjustment = "todayAdjustment"
        static let autoReview = "autoReviewWorkouts"
        static let autoReviewAttempted = "autoReviewAttempted"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
