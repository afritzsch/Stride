import Foundation
import Observation

nonisolated enum HevyConnectError: LocalizedError {
    case keychainWriteFailed

    var errorDescription: String? { "Stride couldn't store the API key in the Keychain." }
}

/// The athlete's lifting log from Hevy, when connected: exercises, sets and weights that Apple Health never gets.
/// Without it, strength screens fall back to what the watch records (time and heart rate). Demo data comes with
/// a made-up log (`DemoStrength`) unless launched with `-demoHevy NO`.
@Observable
final class StrengthModel {
    enum Source: Equatable {
        case none, hevy, demo
    }

    private(set) var isConnected: Bool
    private(set) var accountName: String?
    private(set) var lastSync: Date?
    private(set) var isSyncing = false
    private(set) var syncError: String?
    /// Cached Hevy workouts, oldest first.
    private var logged: [StrengthSession]

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var demoCache: (fetchedAt: Date, sessions: [StrengthSession])?
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    /// How far back the first sync reads (a page has 10 workouts).
    private static let historyDays = 365
    private static let maxPages = 60
    private static let minSyncInterval: TimeInterval = 10 * 60

    init(model: AppModel) {
        self.model = model
        let connected = HevyKeychain.load() != nil
        isConnected = connected
        let defaults = UserDefaults.standard
        accountName = defaults.string(forKey: DefaultsKey.hevyAccountName)
        lastSync = defaults.object(forKey: DefaultsKey.hevyLastSync) as? Date
        logged = connected ? JSONStore.load([StrengthSession].self, from: JSONStore.hevyWorkouts) ?? [] : []
    }

    var source: Source {
        if model?.snapshot?.isDemo == true {
            return UserDefaults.standard.bool(forKey: DefaultsKey.demoHevy, default: true) ? .demo : .none
        }
        return isConnected ? .hevy : .none
    }

    /// The logged sessions, oldest first, or nil when there's no log and screens use the watch data only.
    var sessions: [StrengthSession]? {
        switch source {
        case .none: return nil
        case .hevy: return logged
        case .demo:
            guard let snapshot = model?.snapshot else { return [] }
            if let demoCache, demoCache.fetchedAt == snapshot.fetchedAt { return demoCache.sessions }
            let sessions = DemoStrength.sessions(for: snapshot.workouts)
            demoCache = (snapshot.fetchedAt, sessions)
            return sessions
        }
    }

    func session(for workout: WorkoutSummary) -> StrengthSession? {
        guard workout.kind == .strength, let sessions else { return nil }
        return StrengthLog.session(for: workout, in: sessions)
    }

    var report: StrengthReport? {
        guard let snapshot = model?.snapshot else { return nil }
        return StrengthReport(workouts: snapshot.workouts, sessions: sessions)
    }

    /// Whether there's any strength training to show: a strength workout or a logged session in the last 8 weeks.
    var hasStrengthTraining: Bool {
        guard let snapshot = model?.snapshot else { return false }
        let since = snapshot.days.first?.date ?? .distantPast
        return snapshot.workouts.contains { $0.kind == .strength } || (sessions ?? []).contains { $0.start >= since }
    }

    // MARK: - Connecting

    /// Checks the key with Hevy, then keeps it and reads the workouts.
    func connect(apiKey: String) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = try await HevyClient(apiKey: key).account()
        guard HevyKeychain.save(key) else { throw HevyConnectError.keychainWriteFailed }
        isConnected = true
        accountName = account.name
        UserDefaults.standard.set(account.name, forKey: DefaultsKey.hevyAccountName)
        logged = []
        setLastSync(nil)
        await sync(force: true)
    }

    func disconnect() {
        syncTask?.cancel()
        HevyKeychain.delete()
        isConnected = false
        accountName = nil
        syncError = nil
        logged = []
        setLastSync(nil)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.hevyAccountName)
        JSONStore.delete(JSONStore.hevyWorkouts)
    }

    // MARK: - Syncing

    /// Reads new and changed workouts: a year of history the first time, then only changes since the last sync.
    /// A forced sync (new key, pull to refresh) replaces one that's running, which may be reading with an old key;
    /// an ordinary one gives way to it.
    func sync(force: Bool = false) async {
        guard isConnected, let key = HevyKeychain.load() else { return }
        while isSyncing {
            guard force else { return }
            syncTask?.cancel()
            await syncTask?.value
        }
        if !force, let lastSync, Date.now.timeIntervalSince(lastSync) < Self.minSyncInterval { return }
        isSyncing = true
        syncError = nil
        let task = Task { await read(with: key) }
        syncTask = task
        await task.value
    }

    /// One sync run. It throws away its result when cancelled, so a replaced or disconnected run never writes.
    private func read(with key: String) async {
        defer { isSyncing = false }
        let client = HevyClient(apiKey: key)
        let started = Date.now
        do {
            let fresh: [StrengthSession]
            if let lastSync, !logged.isEmpty {
                fresh = try await applyChanges(to: logged, client: client, since: lastSync.addingTimeInterval(-60))
            } else {
                fresh = try await readHistory(client: client)
            }
            try Task.checkCancellation()
            guard isConnected else { return }
            logged = fresh
            if !JSONStore.save(logged, to: JSONStore.hevyWorkouts) {
                model?.debugLog("Couldn't cache the Hevy workouts; they'll be read again next launch.")
            }
            setLastSync(started)
            model?.debugLog("Hevy sync: \(logged.count) workouts")
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            syncError = error.localizedDescription
            model?.debugLog("Hevy sync failed: \(error)")
        }
    }

    private func readHistory(client: HevyClient) async throws -> [StrengthSession] {
        let cutoff = Date.now.addingTimeInterval(-Double(Self.historyDays) * 86400)
        var sessions: [StrengthSession] = []
        var page = 1
        while page <= Self.maxPages {
            let result = try await client.workouts(page: page)
            sessions += result.sessions
            // Newest first: stop once a page reaches past the cutoff.
            if result.sessions.isEmpty || page >= result.pageCount || (result.sessions.last?.start ?? .now) < cutoff { break }
            page += 1
        }
        return sessions.filter { $0.start >= cutoff }.sorted { $0.start < $1.start }
    }

    private func applyChanges(to sessions: [StrengthSession], client: HevyClient, since: Date) async throws -> [StrengthSession] {
        var byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        var page = 1
        while page <= Self.maxPages {
            let result = try await client.events(since: since, page: page)
            for event in result.events {
                switch event {
                case .updated(let session): byID[session.id] = session
                case .deleted(let id): byID[id] = nil
                }
            }
            if result.events.isEmpty || page >= result.pageCount { break }
            page += 1
        }
        return byID.values.sorted { $0.start < $1.start }
    }

    private func setLastSync(_ date: Date?) {
        lastSync = date
        UserDefaults.standard.set(date, forKey: DefaultsKey.hevyLastSync)
    }
}
