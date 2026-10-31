import Foundation
import FoundationModels

/// Hooks for driving the app from the Simulator (see tools/stride-mcp). Debug builds only read these
/// launch arguments:
///   -route dashboard | coach | chat | plan | settings | workouts | strength
///          | workout:<latest | latest-run | latest-strength | index | uuid>
///          | progress | skill:<endurance | power | strength | explorer | vitality | rest | discipline>
///          | metric:<load | acwr | sleep | restingHR | hrv | steps | weight>
///   -scrollTo <section>   scroll the first opened workout to route, heart-rate, zones, splits, review, or analysis;
///                         on the progress route: trend, compare, records, or achievements; on the plan route: adherence
///   -planSheet <sheet>    on the plan route, open week (the week editor), edit:<n> or time:<n> for the day n days from today
///   -analyze YES          review the first opened workout
///   -demoHevy NO          demo data without its made-up Hevy log, to see the strength screens from watch data only
///   -fixture <path>       replay an exported HealthFixture (default: Documents/fixture.json)
///   -exportFixture YES    write what the app reads to Documents/export.json
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
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        dashboardPath = []
        progressPath = []
        switch parts.first ?? "" {
        case "progress": selectedTab = .progress
        case "skill":
            selectedTab = .progress
            if let skill = Skill(rawValue: parts.count > 1 ? parts[1] : "") { progressPath = [skill] }
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
        case "workout":
            selectedTab = .dashboard
            if let workout = workout(matching: parts.count > 1 ? parts[1] : "latest") {
                dashboardPath = [.workout(workout)]
            }
        case "metric":
            selectedTab = .dashboard
            if let metric = DashboardMetric(rawValue: parts.count > 1 ? parts[1] : "") {
                dashboardPath = [.metric(metric)]
            }
        default:
            selectedTab = .dashboard
        }
        #endif
    }

    func handleLaunchExport() async {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: DefaultsKey.exportFixture) else { return }
        do {
            let url = try await exportHealthData()
            let target = URL.documentsDirectory.appending(path: "export.json")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: url, to: target)
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
        ]
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
