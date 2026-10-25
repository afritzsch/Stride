import Foundation
import Observation

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
        didSet { KeychainStore.save(apiKey, for: Keys.apiKey) }
    }

    private(set) var snapshot: HealthSnapshot?
    private(set) var metrics: MetricsReport?
    private(set) var needsHealthAuthorization = false
    private(set) var isLoadingHealth = false
    private(set) var healthError: String?

    private(set) var history: [SavedAnalysis]
    private(set) var isAnalyzing = false
    var analysisError: String?

    private let health = HealthKitService()

    var latestAnalysis: SavedAnalysis? { history.first }

    /// nil when the selected engine can run, otherwise why not.
    var engineBlocker: String? {
        switch engine {
        case .claude: apiKey.isEmpty ? "Add your Anthropic API key in Settings." : nil
        case .onDevice: OnDeviceAnalyzer.unavailableReason
        }
    }

    init() {
        let defaults = UserDefaults.standard
        profile = defaults.data(forKey: Keys.profile).flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) } ?? UserProfile()
        engine = defaults.string(forKey: Keys.engine).flatMap(AIEngine.init) ?? .claude
        // Default to demo data where HealthKit doesn't exist (e.g. iPad).
        useDemoData = defaults.object(forKey: Keys.demo) as? Bool ?? !HealthKitService.isAvailable
        apiKey = KeychainStore.read(Keys.apiKey) ?? ""
        history = AnalysisStore.load()
    }

    // MARK: - Health data

    func refresh() async {
        healthError = nil
        if useDemoData {
            snapshot = DemoData.snapshot()
            needsHealthAuthorization = false
            recomputeMetrics()
            return
        }
        guard HealthKitService.isAvailable else {
            healthError = "Apple Health isn't available on this device."
            return
        }
        needsHealthAuthorization = await health.needsAuthorizationPrompt()
        guard !needsHealthAuthorization else { return }

        isLoadingHealth = true
        defer { isLoadingHealth = false }
        do {
            snapshot = try await health.fetchSnapshot()
            recomputeMetrics()
        } catch {
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
        isAnalyzing = true
        defer { isAnalyzing = false }

        let calendar = Calendar.current
        let planStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        let builder = PromptBuilder(
            snapshot: snapshot,
            metrics: metrics,
            profile: profile,
            planStart: planStart,
            compact: engine == .onDevice
        )

        do {
            let report = switch engine {
            case .claude:
                try await ClaudeAnalyzer(apiKey: apiKey).analyze(instructions: PromptBuilder.instructions, prompt: builder.prompt)
            case .onDevice:
                try await OnDeviceAnalyzer().analyze(instructions: PromptBuilder.instructions, prompt: builder.prompt)
            }
            let saved = SavedAnalysis(createdAt: .now, engine: engine, planStartDate: planStart, report: report)
            history.insert(saved, at: 0)
            history = Array(history.prefix(30))
            AnalysisStore.save(history)
        } catch {
            analysisError = error.localizedDescription
        }
    }

    func deleteAnalyses(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) { history.remove(at: index) }
        AnalysisStore.save(history)
    }

    // MARK: - Persistence

    private func persist(_ value: some Encodable, key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private enum Keys {
        static let profile = "profile"
        static let engine = "engine"
        static let demo = "useDemoData"
        static let apiKey = "anthropicAPIKey"
    }
}
