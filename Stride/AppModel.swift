import Foundation
import Observation

enum AppTab: String, Hashable {
    case dashboard, coach, plan, settings
}

enum DashboardDestination: Hashable {
    case allWorkouts
    case workout(WorkoutSummary)
}

@Observable
final class AppModel {
    var profile: UserProfile {
        didSet {
            persist(profile, key: Keys.profile)
            recomputeMetrics()
        }
    }
    var engine: AIEngine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: Keys.engine) }
    }
    var useDemoData: Bool {
        didSet {
            UserDefaults.standard.set(useDemoData, forKey: Keys.demo)
            Task { await refresh() }
        }
    }
    var apiKey: String {
        didSet {
            if !KeychainStore.save(apiKey, for: Keys.apiKey) { debugLog("Couldn't save the API key to the Keychain") }
        }
    }
    /// Apple Intelligence: use the larger Private Cloud Compute model when available.
    var allowPrivateCloud: Bool {
        didSet { UserDefaults.standard.set(allowPrivateCloud, forKey: Keys.privateCloud) }
    }
    var usesPrivateCloud: Bool { allowPrivateCloud && AppleAnalyzer.isPrivateCloudInBuild }

    private(set) var snapshot: HealthSnapshot?
    private(set) var metrics: MetricsReport?
    private(set) var needsHealthAuthorization = false
    private(set) var isLoadingHealth = false
    private(set) var healthError: String?

    private(set) var history: [SavedAnalysis]
    private(set) var isAnalyzing = false
    /// Workouts with a coach review in flight, so leaving and reopening a workout can't start a second one.
    private(set) var analyzingWorkoutIDs: Set<UUID> = []
    var analysisError: String?
    /// Explains why the last analysis didn't use Private Cloud Compute.
    private(set) var analysisNotice: String?
    /// Per-workout coach feedback, keyed by workout ID.
    private(set) var runAnalyses: [UUID: SavedRunAnalysis]

    var selectedTab = AppTab.dashboard
    var dashboardPath: [DashboardDestination] = []

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

    /// nil when the selected engine can run, otherwise why not.
    var engineBlocker: String? {
        switch engine {
        case .claude: apiKey.isEmpty ? "Add your Anthropic API key in Settings." : nil
        case .apple: AppleAnalyzer.unavailableReason(allowPrivateCloud: usesPrivateCloud)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        profile = defaults.data(forKey: Keys.profile).flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) } ?? UserProfile()
        engine = defaults.string(forKey: Keys.engine).flatMap(AIEngine.init) ?? .claude
        // Default to demo data where HealthKit doesn't exist (e.g. iPad).
        // bool(forKey:) also understands "YES"/"NO" strings, e.g. from launch arguments.
        useDemoData = defaults.object(forKey: Keys.demo) != nil ? defaults.bool(forKey: Keys.demo) : !HealthKitService.isAvailable
        apiKey = KeychainStore.read(Keys.apiKey) ?? ""
        allowPrivateCloud = defaults.object(forKey: Keys.privateCloud) != nil ? defaults.bool(forKey: Keys.privateCloud) : true
        history = JSONStore.load([SavedAnalysis].self, from: JSONStore.analyses) ?? []
        let savedRuns = JSONStore.load([SavedRunAnalysis].self, from: JSONStore.runAnalyses) ?? []
        runAnalyses = Dictionary(savedRuns.map { ($0.workoutID, $0) }, uniquingKeysWith: { latest, _ in latest })
        #if DEBUG
        fixture = Self.loadFixture()
        #endif
    }

    // MARK: - Health data

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        healthError = nil
        defer { writeDebugState() }
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

    private func recomputeMetrics() {
        metrics = snapshot.map { MetricsReport(snapshot: $0, profile: profile) }
    }

    // MARK: - Analysis

    func runAnalysis() async {
        guard let snapshot, let metrics, !isAnalyzing else { return }
        analysisError = nil
        analysisNotice = nil
        isAnalyzing = true
        defer {
            isAnalyzing = false
            writeDebugState()
        }

        let calendar = Calendar.current
        let planStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        func prompt(compact: Bool) -> String {
            PromptBuilder(snapshot: snapshot, metrics: metrics, profile: profile, planStart: planStart, compact: compact).prompt
        }

        do {
            let result = try await generate(
                AnalysisReport.self,
                instructions: PromptBuilder.instructions,
                fullPrompt: prompt(compact: false),
                compactPrompt: prompt(compact: true)
            )
            analysisNotice = result.notice
            let saved = SavedAnalysis(createdAt: .now, engine: engine, modelName: result.modelName, planStartDate: planStart, report: result.output)
            history = Array(([saved] + history).prefix(Self.maxSavedAnalyses))
            JSONStore.save(history, to: JSONStore.analyses)
        } catch {
            analysisError = error.localizedDescription
            debugLog("Weekly analysis failed: \(error)")
        }
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

    /// Reviews one workout and stores the result. Returns a notice if Apple Intelligence fell back to on-device.
    func analyzeWorkout(_ detail: WorkoutDetail, note: String) async throws -> String? {
        guard let snapshot, let metrics else { throw AnalyzerError.notReady("Health data isn't loaded yet.") }
        if let blocker = engineBlocker { throw AnalyzerError.notReady(blocker) }
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
        let result = try await generate(
            RunAnalysis.self,
            instructions: RunPromptBuilder.instructions,
            fullPrompt: prompt(compact: false),
            compactPrompt: prompt(compact: true)
        )
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

    /// The session the latest weekly plan had for that day, if the plan covers it.
    func plannedSession(on date: Date) -> PlannedDay? {
        let calendar = Calendar.current
        let label = PromptBuilder.dayLabel(date, calendar: calendar)
        for analysis in history where calendar.startOfDay(for: date) >= analysis.planStartDate {
            return analysis.report.weekPlan.first { $0.day == label }
        }
        return nil
    }

    private func generate<Output: StructuredOutput>(
        _: Output.Type,
        instructions: String,
        fullPrompt: String,
        compactPrompt: String
    ) async throws -> (output: Output, modelName: String, notice: String?) {
        switch engine {
        case .claude:
            let output = try await ClaudeAnalyzer(apiKey: apiKey).analyze(Output.self, instructions: instructions, prompt: fullPrompt)
            return (output, ClaudeAnalyzer.displayName, nil)
        case .apple:
            let result = try await AppleAnalyzer(allowPrivateCloud: usesPrivateCloud).analyze(
                Output.self,
                instructions: instructions,
                fullPrompt: fullPrompt,
                compactPrompt: compactPrompt
            )
            return (result.report, result.route.title, result.fallbackReason.map { "\($0) Used the on-device model instead." })
        }
    }

    // MARK: - Persistence

    private func persist(_ value: some Encodable, key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static let maxSavedAnalyses = 30

    private enum Keys {
        static let profile = "profile"
        static let engine = "engine"
        static let demo = "useDemoData"
        static let apiKey = "anthropicAPIKey"
        static let privateCloud = "allowPrivateCloud"
    }
}
