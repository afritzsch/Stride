import BackgroundTasks
import Foundation
import HealthKit
import UIKit
import UserNotifications

/// Reaching the athlete while the app isn't open: HealthKit background delivery and a background app refresh task
/// wake the app, which rereads Apple Health, notifies about this morning's readiness and new workouts, keeps the
/// session reminders in step with the calendar and tries the coach reviews. Notification text comes from
/// `NotificationPlanner` only; the model runs when the app opens (and in the background only when it happens to work).
extension AppModel {
    /// The BGAppRefreshTask identifier (also in BGTaskSchedulerPermittedIdentifiers, see the build settings).
    static let backgroundRefreshTaskID = "com.afritzsch.stride.refresh"

    /// In the foreground (also while launching or switching apps, which is `.inactive`), as opposed to a
    /// background wake-up.
    private var isAppActive: Bool { UIApplication.shared.applicationState != .background }

    /// Real data only: demo data and fixtures don't change in the background.
    private var usesLiveHealthData: Bool { fixture == nil && !useDemoData && HealthKitService.isAvailable }

    // MARK: - Settings

    static func loadNotificationSettings() -> NotificationSettings {
        let defaults = UserDefaults.standard
        var settings = NotificationSettings()
        settings.readiness = defaults.bool(forKey: DefaultsKey.notifyReadiness)
        settings.newWorkouts = defaults.bool(forKey: DefaultsKey.notifyNewWorkouts)
        settings.sessionReminders = defaults.bool(forKey: DefaultsKey.notifySessionReminders)
        let lead = defaults.integer(forKey: DefaultsKey.sessionReminderMinutes)
        if lead > 0 { settings.reminderLeadMinutes = lead }
        return settings
    }

    func saveNotificationSettings(oldValue: NotificationSettings) {
        guard notificationSettings != oldValue else { return }
        let defaults = UserDefaults.standard
        defaults.set(notificationSettings.readiness, forKey: DefaultsKey.notifyReadiness)
        defaults.set(notificationSettings.newWorkouts, forKey: DefaultsKey.notifyNewWorkouts)
        defaults.set(notificationSettings.sessionReminders, forKey: DefaultsKey.notifySessionReminders)
        defaults.set(notificationSettings.reminderLeadMinutes, forKey: DefaultsKey.sessionReminderMinutes)
        if notificationSettings.anyOn != oldValue.anyOn {
            Task { await updateBackgroundDelivery() }
        }
        if notificationSettings.sessionReminders != oldValue.sessionReminders || notificationSettings.reminderLeadMinutes != oldValue.reminderLeadMinutes {
            syncSessionReminders()
        }
    }

    /// Turns one kind on or off. The first time one is turned on, iOS asks for permission; if it's refused the
    /// switch stays off.
    func setNotifications(_ kind: NotificationKind, on: Bool) async {
        if on {
            let allowed = await notifier.requestAuthorization()
            notificationAuthorization = await notifier.authorizationStatus()
            guard allowed else { return }
            // What's already here was seen in the app; only what arrives from now on is news.
            checkNotifications()
        }
        switch kind {
        case .readiness: notificationSettings.readiness = on
        case .workout: notificationSettings.newWorkouts = on
        case .session: notificationSettings.sessionReminders = on
        }
    }

    func refreshNotificationAuthorization() async {
        notificationAuthorization = await notifier.authorizationStatus()
    }

    // MARK: - Waking up

    /// Called at launch (also a background launch by HealthKit): observes new workouts, sleep and recovery samples.
    func startBackgroundObservers() async {
        guard healthObservers.isEmpty, usesLiveHealthData, await !health.needsAuthorizationPrompt() else { return }
        // The model lives as long as the app, so holding it here is fine.
        healthObservers = health.observeChanges { completion in
            Task { @MainActor in self.healthDataChanged(completion: completion) }
        }
        await updateBackgroundDelivery()
    }

    /// Background delivery only while a notification is on: otherwise nothing would happen with the wake-up.
    func updateBackgroundDelivery() async {
        guard usesLiveHealthData, await !health.needsAuthorizationPrompt() else { return }
        await health.setBackgroundDelivery(enabled: notificationSettings.anyOn)
    }

    /// One HealthKit observer fired. Several fire together (and once each at launch), so they share one update;
    /// each completion handler is called when it's done.
    func healthDataChanged(completion: @escaping @Sendable () -> Void) {
        pendingHealthCompletions.append(completion)
        guard backgroundUpdateTask == nil else { return }
        backgroundUpdateTask = Task {
            // Let the other observers of the same sync arrive first.
            try? await Task.sleep(for: .seconds(1))
            await backgroundUpdate(reason: "Apple Health changed")
            let completions = pendingHealthCompletions
            pendingHealthCompletions = []
            backgroundUpdateTask = nil
            completions.forEach { $0() }
        }
    }

    /// The BGAppRefreshTask: the same update, for when HealthKit didn't wake the app (or the calendar changed).
    func backgroundAppRefresh() async {
        scheduleBackgroundRefresh()
        await backgroundUpdate(reason: "background refresh")
    }

    /// Asks iOS for the next background refresh. iOS decides when it runs; the earliest is in an hour.
    func scheduleBackgroundRefresh() {
        guard notificationSettings.anyOn else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundRefreshTaskID)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(3600)
        Task {
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } catch {
                // Always fails in the Simulator.
                debugLog("Scheduling the background refresh failed: \(error)")
            }
        }
    }

    /// Rereads Apple Health and acts on it. In the background it notifies and tries the coach reviews; in the
    /// foreground the screens show the news, so it only refreshes (unless the data is fresh) and marks it as seen.
    func backgroundUpdate(reason: String) async {
        let active = isAppActive
        guard usesLiveHealthData else { return }
        // Health data is encrypted while the iPhone is locked: reading it then returns nothing, which mustn't
        // replace the snapshot.
        guard active || UIApplication.shared.isProtectedDataAvailable else {
            debugLog("Skipped a background update (\(reason)): the iPhone is locked.")
            return
        }
        let isFresh = snapshot.map { Date.now.timeIntervalSince($0.fetchedAt) < 60 } ?? false
        if !(active && (isFresh || isLoadingHealth)) {
            await refresh(loadsArchive: active)
        }
        guard snapshot != nil, healthError == nil else { return }
        checkNotifications()
        await schedule.refresh()
        syncSessionReminders()
        if !isAppActive {
            debugLog("Background update (\(reason)) done; trying reviews.")
            await reviewNewWorkouts(inBackground: true)
        }
    }

    // MARK: - Deciding

    /// Notifies about this morning's readiness and new workouts, each once. While the app is open nothing is
    /// posted, only marked as seen: the dashboard shows it.
    func checkNotifications() {
        guard let snapshot, let metrics, !snapshot.isDemo, fixture == nil else { return }
        let posting = !isAppActive
        let now = Date.now
        var log = notificationLog
        var messages: [NotificationMessage] = []
        let readiness = Readiness(snapshot: snapshot, metrics: metrics, profile: profile, healthIssues: healthIssues)
        if let message = NotificationPlanner.readiness(readiness, snapshot: snapshot, planned: todaysPlan, log: log, now: now) {
            log.insert(message.id)
            if notificationSettings.readiness { messages.append(message) }
        }
        for message in NotificationPlanner.newWorkouts(snapshot.workouts, log: log, now: now) where notificationSettings.newWorkouts {
            messages.append(message)
        }
        // Everything recent is handled now, including workouts beyond the batch: a backlog isn't news later either.
        for workout in snapshot.workouts where now.timeIntervalSince(NotificationPlanner.end(of: workout)) <= NotificationPlanner.newWorkoutWindow {
            log.insert(NotificationPlanner.workoutKey(workout.id))
        }
        notificationLog = log
        guard posting, !messages.isEmpty else { return }
        Task {
            for message in messages {
                do {
                    try await notifier.post(message)
                    debugLog("Notified: \(message.title) | \(message.subtitle) | \(message.body)")
                } catch {
                    debugLog("Notifying failed: \(error)")
                }
            }
        }
    }

    /// Schedules a reminder before each session Stride put in the calendar, and drops the ones for sessions that
    /// moved, were removed or are done. Called whenever the calendar, the plan or the settings change.
    func syncSessionReminders() {
        let messages: [NotificationMessage]
        if notificationSettings.sessionReminders {
            messages = NotificationPlanner.sessionReminders(
                sessions: schedule.busy.filter(\.isSession), plannedOn: plannedSession(on:), workouts: snapshot?.workouts ?? [],
                forecast: schedule.forecast, leadMinutes: notificationSettings.reminderLeadMinutes, now: .now
            )
        } else {
            messages = []
        }
        Task { await notifier.replaceSessionReminders(with: messages) }
    }

    // MARK: - Opening

    /// A tap on a notification.
    func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        guard let route = userInfo[NotificationService.routeKey] as? String else { return }
        debugLog("Opened from a notification: \(route)")
        open(route: route)
    }

    /// Opens a screen by route (the `-route` launch argument uses the same names):
    /// dashboard | progress | coach | chat | plan | settings | workouts | strength
    /// | workout:<selector> | review:<selector> (the workout, scrolled to its coach review, which runs if missing)
    /// | skill:<name> | metric:<name>. Workout routes wait for the first refresh.
    func open(route: String) {
        pendingRoute = route
        applyPendingRoute()
    }

    func applyPendingRoute() {
        guard let route = pendingRoute else { return }
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        if name == "workout" || name == "review", snapshot == nil { return }
        pendingRoute = nil
        showsCoachChat = false
        dashboardPath = []
        progressPath = []
        switch name {
        case "progress": selectedTab = .progress
        case "skill":
            selectedTab = .progress
            if let skill = Skill(rawValue: argument) { progressPath = [skill] }
        case "coach": selectedTab = .coach
        case "chat":
            selectedTab = .coach
            showsCoachChat = true
        case "plan": selectedTab = .plan
        case "settings": selectedTab = .settings
        case "workouts":
            selectedTab = .dashboard
            dashboardPath = [.allWorkouts]
        case "strength":
            selectedTab = .dashboard
            dashboardPath = [.strength]
        case "health":
            selectedTab = .dashboard
            dashboardPath = [.healthLog]
        case "workout", "review":
            selectedTab = .dashboard
            if let workout = workout(matching: argument.isEmpty ? "latest" : argument) {
                if name == "review" { reviewRequestID = workout.id }
                dashboardPath = [.workout(workout)]
            }
        case "metric":
            selectedTab = .dashboard
            if let metric = DashboardMetric(rawValue: argument) { dashboardPath = [.metric(metric)] }
        default:
            selectedTab = .dashboard
        }
    }

    /// True once for the workout opened from its notification: its screen then shows the review.
    func consumeReviewRequest(for id: UUID) -> Bool {
        guard reviewRequestID == id else { return false }
        reviewRequestID = nil
        return true
    }
}
