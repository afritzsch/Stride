import Foundation
import FoundationModels

/// Hooks for driving the app from the Simulator (see tools/stride-mcp). Debug builds only read these
/// launch arguments:
///   -route dashboard | coach | chat | plan | settings | workouts | strength | playlist
///          | workout:<latest | latest-run | latest-strength | index | uuid> | review:<same> (opens the coach review)
///          | progress | skill:<endurance | power | strength | explorer | vitality | rest | discipline>
///          | metric:<load | acwr | sleep | restingHR | hrv | steps | weight>
///   -scrollTo <section>   scroll the first opened workout to route, heart-rate, zones, splits, review, or analysis;
///                         on the progress route: trend, compare, records, or achievements; on the plan route: adherence
///   -planSheet <sheet>    on the plan route, open week (the week editor), edit:<n> or time:<n> for the day n days from today
///   -analyze YES          review the first opened workout
///   -demoHevy NO          demo data without its made-up Hevy log, to see the strength screens from watch data only
///   -fixture <path>       replay an exported HealthFixture (default: Documents/fixture.json)
///   -exportFixture YES    write what the app reads to Documents/export.json
///   -debugState YES       also write Documents/debug-state.json on a device (always written in the Simulator)
///   -notify <kind>        post that notification (readiness, workout, session or all) a few seconds after launch,
///                         from the current data, whatever the switches and the time of day
///   -notifyOpen <kind>    handle a tap on that notification (readiness, workout or session) after launch
///   -probeModel YES       ask the on-device model for one word whatever `availability` says; writes Documents/model-probe.json
extension AppModel {
    static func loadFixture() -> HealthFixture? {
        let path = UserDefaults.standard.string(forKey: DefaultsKey.fixture) ?? URL.documentsDirectory.appending(path: "fixture.json").path()
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        do {
            return try HealthFixture.decoder().decode(HealthFixture.self, from: data)
        } catch {
            print("Stride: couldn't decode fixture at \(path): \(error)")
            return nil
        }
    }

    /// The -scrollTo and -analyze hooks, returned once so later workouts opened in the session don't repeat them.
    func consumeLaunchHooks() -> (scrollTarget: String?, analyze: Bool) {
        #if DEBUG
        guard !launchHooksConsumed else { return (nil, false) }
        launchHooksConsumed = true
        return (UserDefaults.standard.string(forKey: DefaultsKey.scrollTo), UserDefaults.standard.bool(forKey: DefaultsKey.analyze))
        #else
        return (nil, false)
        #endif
    }

    func applyLaunchRoute() {
        #if DEBUG
        guard let route = UserDefaults.standard.string(forKey: DefaultsKey.route) else { return }
        open(route: route)
        #endif
    }

    func handleLaunchExport() async {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: DefaultsKey.exportFixture) else { return }
        do {
            let url = try await exportHealthData(includeRoutes: true)
            let target = URL.documentsDirectory.appending(path: "export.json")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            print("Stride: export failed: \(error)")
        }
        #endif
    }

    /// Newest-first selector: "latest", "latest-run", an index (0 = newest) or a workout UUID.
    func workout(matching selector: String) -> WorkoutSummary? {
        let newestFirst = workoutsNewestFirst
        switch selector {
        case "latest": return newestFirst.first
        case "latest-run": return newestFirst.first { $0.sport == Sport.running }
        case "latest-strength": return newestFirst.first { $0.kind == .strength }
        default:
            if let index = Int(selector), newestFirst.indices.contains(index) { return newestFirst[index] }
            return newestFirst.first { $0.id.uuidString.caseInsensitiveCompare(selector) == .orderedSame }
        }
    }

    /// Records an error or notice for the debug state (no-op in release builds).
    func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        let message = message()
        print("Stride: \(message)")
        debugEvents = Array((debugEvents + ["\(ISO8601DateFormatter().string(from: .now)) \(message)"]).suffix(20))
        writeDebugState()
        #endif
    }
}

#if DEBUG
extension AppModel {
    func probeModelIfAsked() async {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.probeModel) else { return }
        let model = SystemLanguageModel.default
        var probe: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: .now),
            "availability": String(describing: model.availability),
            "supportsCurrentLocale": model.supportsLocale(),
            "locale": Locale.current.identifier,
            "contextSize": model.contextSize,
        ]
        // What the weekly analysis spends before its prompt: instructions plus the report's schema.
        if let instructions = try? await model.tokenCount(for: PromptBuilder.instructions),
           let schema = try? await model.tokenCount(for: AnalysisReport.generationSchema) {
            probe["weeklyFixedTokens"] = instructions + schema
        }
        let url = URL.documentsDirectory.appending(path: "model-probe.json")
        func save() {
            let data = try? JSONSerialization.data(withJSONObject: probe, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: url)
        }
        save()  // before generating, in case it never returns
        do {
            probe["response"] = try await LanguageModelSession().respond(to: "Reply with the single word OK.").content
        } catch {
            probe["error"] = String(describing: error)
        }
        probe["availabilityAfter"] = String(describing: model.availability)
        save()
    }
}
#endif

#if DEBUG
extension AppModel {
    /// The -notify and -notifyOpen hooks: post a notification (asking for permission first, which shows the
    /// system prompt once per install) or handle a tap on one, so each can be checked in the Simulator, where
    /// HealthKit never delivers anything in the background. The text comes from `NotificationPlanner` with the
    /// current data; only the decision (time of day, readiness actually down, new data) is skipped.
    func handleNotificationHooks() async {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: DefaultsKey.notify) {
            let kinds = value == "all" ? NotificationKind.allCases : value.split(separator: ",").compactMap { NotificationKind(rawValue: String($0)) }
            let allowed = await notifier.requestAuthorization()
            notificationAuthorization = await notifier.authorizationStatus()
            guard allowed else {
                debugLog("-notify: notifications aren't allowed")
                return
            }
            for (index, kind) in kinds.enumerated() {
                guard var message = debugNotification(kind) else {
                    debugLog("-notify \(kind.rawValue): no data to notify about")
                    continue
                }
                message.id += "-debug"
                do {
                    // A few seconds apart, so each banner can be seen (and screenshotted) on its own.
                    try await notifier.post(message, delay: 3 + Double(index) * 8)
                    debugLog("Debug notification \(kind.rawValue): \(message.title) | \(message.subtitle) | \(message.body) | route \(message.route)")
                } catch {
                    debugLog("-notify \(kind.rawValue) failed: \(error)")
                }
            }
        }
        if let kind = defaults.string(forKey: DefaultsKey.notifyOpen).flatMap(NotificationKind.init(rawValue:)),
           let message = debugNotification(kind) {
            handleNotificationTap(userInfo: [NotificationService.routeKey: message.route])
        }
    }

    private func debugNotification(_ kind: NotificationKind) -> NotificationMessage? {
        let calendar = Calendar.current
        let standIn = PlannedDay(day: "", sport: Sport.running, intensity: .hard, session: "Tempo run", durationMinutes: 50, targetZone: 4, details: "")
        func planned(on date: Date) -> PlannedDay {
            plannedSession(on: date).flatMap { $0.isRest ? nil : $0 } ?? standIn
        }
        switch kind {
        case .readiness:
            guard let readiness else { return nil }
            return NotificationPlanner.readinessMessage(readiness, planned: planned(on: .now), now: .now, calendar: calendar)
        case .workout:
            return workoutsNewestFirst.first.map(NotificationPlanner.workoutMessage)
        case .session:
            // The next session Stride put in the calendar, or one made up for a moment from now.
            let lead = notificationSettings.reminderLeadMinutes
            let event = schedule.busy.first { $0.isSession && $0.start > .now } ?? {
                let start = Date.now.addingTimeInterval(TimeInterval(lead * 60))
                let session = planned(on: start)
                return BusyInterval(
                    start: start, end: start.addingTimeInterval(TimeInterval(max(session.durationMinutes, 15) * 60)),
                    title: session.session, sessionDate: calendar.startOfDay(for: start)
                )
            }()
            let session = planned(on: event.start)
            return NotificationPlanner.sessionMessage(
                event, planned: session, weather: NotificationPlanner.weather(for: event, sport: session.sport, forecast: schedule.forecast),
                leadMinutes: lead, fireDate: nil, calendar: calendar
            )
        }
    }
}
#endif
