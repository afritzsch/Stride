import Foundation
import FoundationModels
import HealthKit
import Observation
import UserNotifications

enum AppTab: String, Hashable {
    case dashboard, progress, coach, plan, settings
}

enum DashboardDestination: Hashable {
    case allWorkouts
    case workout(WorkoutSummary)
    case strength
    case strengthSession(StrengthSession)
    case metric(DashboardMetric)
}

/// The app's state and the owner of its services. The behavior lives in extensions by topic:
/// `AppModel+Health` (reading Apple Health, metrics, history), `AppModel+Analysis` (weekly analysis, workout reviews,
/// model calls), `AppModel+Plan` (today's readiness adjustment, the athlete's own plan) and `AppModel+Debug`.
///
/// Swift has no cross-file `private`, so state the extensions write isn't `private(set)`: views only read it.
@Observable
final class AppModel {
    var profile: UserProfile {
        didSet {
            UserDefaults.standard.setEncoded(profile, forKey: DefaultsKey.profile)
            recomputeMetrics()
        }
    }
    /// Switching it re-reads the data; a newer switch replaces a refresh still running for the older one.
    var useDemoData: Bool {
        didSet {
            UserDefaults.standard.set(useDemoData, forKey: DefaultsKey.useDemoData)
            demoToggleRefresh?.cancel()
            demoToggleRefresh = Task { await refresh() }
        }
    }
    /// Apple Intelligence: use the larger Private Cloud Compute model when available.
    var allowPrivateCloud: Bool {
        didSet { UserDefaults.standard.set(allowPrivateCloud, forKey: DefaultsKey.allowPrivateCloud) }
    }
    var usesPrivateCloud: Bool { allowPrivateCloud && AppleAnalyzer.isPrivateCloudInBuild }
    /// Review new workouts on the device as they sync (it's free and private).
    var autoReviewWorkouts: Bool {
        didSet { UserDefaults.standard.set(autoReviewWorkouts, forKey: DefaultsKey.autoReviewWorkouts) }
    }

    // MARK: Health data (AppModel+Health)

    var snapshot: HealthSnapshot?
    var metrics: MetricsReport?
    var needsHealthAuthorization = false
    var isLoadingHealth = false
    var healthError: String?
    /// Levels, records and period totals over all history (the archive plus the current snapshot).
    var progress: ProgressReport?
    var isLoadingArchive = false
    /// Years of history before the snapshot, for the progress screen. Cached on disk because reading it takes a while.
    var archive: HealthSnapshot?
    /// Bumped by each refresh so a slower, older one (e.g. after toggling demo data) can't overwrite a newer result.
    @ObservationIgnored var refreshGeneration = 0
    @ObservationIgnored var demoToggleRefresh: Task<Void, Never>?
    let health = HealthKitService()

    // MARK: Analysis and reviews (AppModel+Analysis)

    /// Saved weekly analyses, newest first. Saved to disk on every change.
    var history: [SavedAnalysis] {
        didSet { JSONStore.save(history, to: JSONStore.analyses) }
    }
    var isAnalyzing = false
    /// Workouts with a coach review in flight, so leaving and reopening a workout can't start a second one.
    var analyzingWorkoutIDs: Set<UUID> = []
    var analysisError: String?
    /// Explains why the last analysis didn't use Private Cloud Compute.
    var analysisNotice: String?
    /// Per-workout coach feedback, keyed by workout ID. Saved to disk on every change.
    var runAnalyses: [UUID: SavedRunAnalysis] {
        didSet { JSONStore.save(Array(runAnalyses.values), to: JSONStore.runAnalyses) }
    }
    /// What's been written so far while Apple Intelligence streams the weekly analysis.
    var analysisPreview: AnalysisReport.PartiallyGenerated?
    /// What the running analysis is doing besides writing, e.g. checking the plan.
    var analysisStep: String?
    /// Coach reviews being streamed, by workout ID.
    var runPreviews: [UUID: RunAnalysis.PartiallyGenerated] = [:]

    // MARK: Plan and today (AppModel+Plan)

    /// Days the athlete planned or changed themselves; they win over the coach's plans. Saved to disk on every change.
    var athleteDays: [AthletePlanDay] {
        didSet { JSONStore.save(athleteDays, to: JSONStore.athletePlan) }
    }
    /// Today's readiness-based change to the plan, once suggested.
    var todayAdjustment: SavedAdjustment? {
        didSet { UserDefaults.standard.setEncoded(todayAdjustment, forKey: DefaultsKey.todayAdjustment) }
    }
    var isAdjustingToday = false
    var adjustmentError: String?

    // MARK: Background refresh and notifications (AppModel+Background)

    /// Which notifications are on. Saved to UserDefaults on every change.
    var notificationSettings: NotificationSettings {
        didSet { saveNotificationSettings(oldValue: oldValue) }
    }
    /// Whether iOS lets Stride notify, as last read; `.denied` explains in Settings why nothing arrives.
    var notificationAuthorization = UNAuthorizationStatus.notDetermined
    /// What was notified (or seen in the app), so each workout and morning notifies once.
    @ObservationIgnored var notificationLog: NotificationLog {
        didSet { UserDefaults.standard.setEncoded(notificationLog, forKey: DefaultsKey.notificationLog) }
    }
    @ObservationIgnored let notifier = NotificationService()
    /// The HealthKit observer queries, once started.
    @ObservationIgnored var healthObservers: [HKObserverQuery] = []
    /// HealthKit completion handlers waiting for the running background update.
    @ObservationIgnored var pendingHealthCompletions: [@Sendable () -> Void] = []
    @ObservationIgnored var backgroundUpdateTask: Task<Void, Never>?
    /// A route from a notification tap that waits for the data it needs (e.g. a workout before the first refresh).
    @ObservationIgnored var pendingRoute: String?
    /// A workout opened from its notification: its screen runs (or shows) the coach review.
    @ObservationIgnored var reviewRequestID: UUID?

    // MARK: Services and navigation

    /// The "Ask the coach" conversation, kept while the app runs.
    @ObservationIgnored private(set) lazy var chat = CoachChat(model: self)
    /// Suggested times for planned sessions, from the calendar and the forecast.
    @ObservationIgnored private(set) lazy var schedule = ScheduleModel(model: self)
    /// The Hevy lifting log, when connected.
    @ObservationIgnored private(set) lazy var strength = StrengthModel(model: self)

    var selectedTab = AppTab.dashboard
    var showsCoachChat = false
    var dashboardPath: [DashboardDestination] = []
    var progressPath: [Skill] = []

    // MARK: Debugging (AppModel+Debug)

    /// Exported real data replayed instead of HealthKit (debug builds).
    var fixture: HealthFixture?
    /// Last workout opened, included in the debug state dump.
    @ObservationIgnored var debugDetail: WorkoutDetail?
    /// Recent errors and notices, included in the debug state dump.
    @ObservationIgnored var debugEvents: [String] = []
    /// The -scrollTo/-analyze launch hooks apply to the first workout opened only.
    @ObservationIgnored var launchHooksConsumed = false

    // MARK: -

    var latestAnalysis: SavedAnalysis? { history.first }

    /// Newest first, so index 0 (or "#1" for the coach) is the latest workout.
    var workoutsNewestFirst: [WorkoutSummary] { Array((snapshot?.workouts ?? []).reversed()) }

    /// 28-day resting HR median, or a typical value until there's data.
    var restingHRBaseline: Double { metrics?.indicators.restingHRBaseline ?? 60 }
    var heartRateZones: HeartRateZones { metrics?.heartRateZones ?? profile.heartRateZones(restingHR: restingHRBaseline) }

    /// Why the on-device model can't run, or nil. `SystemLanguageModel.availability` isn't observable, so views
    /// read this copy, which `refreshModelAvailability()` updates.
    private(set) var onDeviceBlocker = AppleAnalyzer.onDeviceBlocker

    /// nil when Apple Intelligence can run, otherwise why not.
    var aiBlocker: String? {
        if usesPrivateCloud, AppleAnalyzer.privateCloudBlocker == nil { return nil }
        return onDeviceBlocker
    }

    func refreshModelAvailability() {
        let blocker = AppleAnalyzer.onDeviceBlocker
        if blocker != onDeviceBlocker { onDeviceBlocker = blocker }
    }

    /// `aiBlocker` after re-reading the model's availability: what to check before each request.
    func currentAIBlocker() -> String? {
        refreshModelAvailability()
        return aiBlocker
    }

    init() {
        let defaults = UserDefaults.standard
        profile = defaults.decoded(UserProfile.self, forKey: DefaultsKey.profile) ?? UserProfile()
        // Default to demo data where HealthKit doesn't exist (e.g. iPad).
        useDemoData = defaults.bool(forKey: DefaultsKey.useDemoData, default: !HealthKitService.isAvailable)
        allowPrivateCloud = defaults.bool(forKey: DefaultsKey.allowPrivateCloud, default: true)
        autoReviewWorkouts = defaults.bool(forKey: DefaultsKey.autoReviewWorkouts, default: true)
        history = JSONStore.load([SavedAnalysis].self, from: JSONStore.analyses) ?? []
        athleteDays = JSONStore.load([AthletePlanDay].self, from: JSONStore.athletePlan) ?? []
        todayAdjustment = defaults.decoded(SavedAdjustment.self, forKey: DefaultsKey.todayAdjustment)
            .flatMap { Calendar.current.isDateInToday($0.date) ? $0 : nil }
        let savedRuns = JSONStore.load([SavedRunAnalysis].self, from: JSONStore.runAnalyses) ?? []
        runAnalyses = Dictionary(savedRuns.map { ($0.workoutID, $0) }, uniquingKeysWith: { latest, _ in latest })
        archive = JSONStore.load(HealthSnapshot.self, from: JSONStore.archive)
        notificationSettings = Self.loadNotificationSettings()
        notificationLog = defaults.decoded(NotificationLog.self, forKey: DefaultsKey.notificationLog) ?? NotificationLog()
        #if DEBUG
        fixture = Self.loadFixture()
        #endif
        Self.removeClaudeSettings()
        Self.deleteHealthExport()
        Self.removeUnwantedDebugState()
    }

    /// Earlier versions could use Claude with the user's own Anthropic key; don't leave that key behind.
    private static func removeClaudeSettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: DefaultsKey.removedClaudeSettings) else { return }
        LegacyKeychain.deleteAnthropicKey()
        defaults.removeObject(forKey: DefaultsKey.legacyEngine)
        defaults.set(true, forKey: DefaultsKey.removedClaudeSettings)
    }

    /// Limits that keep saved data and prompts bounded.
    enum Limits {
        static let savedAnalyses = 30
        /// Athlete-planned days older than this are dropped; nothing looks back further.
        static let athleteDayRetentionDays = 60
        static let archiveMaxAge: TimeInterval = 7 * 86400
        /// Automatic reviews: workouts from this many days back, at most this many per refresh.
        static let autoReviewWindow: TimeInterval = 2 * 24 * 3600
        static let autoReviewBatch = 3
        /// How many workouts an automatic review remembers having tried.
        static let autoReviewMemory = 50
    }
}
