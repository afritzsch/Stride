import CoreLocation
import Foundation
import Observation

/// Suggested times for the planned sessions, from the calendar and the forecast. Demo data uses a made-up calendar
/// and forecast (`DemoSchedule`) and keeps added sessions in memory instead of writing to the real calendar.
@Observable
final class ScheduleModel {
    var settings: ScheduleSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            Task { await refresh() }
        }
    }
    private(set) var calendarAccess = CalendarService.access
    private(set) var weatherError: String?
    private(set) var isRefreshing = false
    /// Apple's Weather mark and legal link, shown wherever WeatherKit data is.
    private(set) var appleAttribution: WeatherAttribution?

    private var calendarBusy: [BusyInterval] = []
    private var liveForecast: WeatherForecast?
    /// Sessions "added" while showing demo data.
    private var demoSessions: [BusyInterval] = []

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored let calendar = CalendarService()
    /// Source and location the live forecast was fetched for, to refetch when either changes.
    @ObservationIgnored private var forecastKey: String?
    @ObservationIgnored private var demoCache: (day: Date, busy: [BusyInterval], forecast: WeatherForecast)?
    @ObservationIgnored private var changeObserver: Task<Void, Never>?

    struct WeatherAttribution: Equatable {
        var mark: URL
        var darkMark: URL
        var legal: URL
    }

    init(model: AppModel) {
        self.model = model
        settings = UserDefaults.standard.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(ScheduleSettings.self, from: $0) } ?? ScheduleSettings()
        changeObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: CalendarService.changed) {
                self?.reloadCalendar()
            }
        }
    }

    var isDemo: Bool { model?.snapshot?.isDemo == true }

    /// Times are suggested for demo data, or once the athlete turned it on and allowed calendar access.
    var isActive: Bool { isDemo || (settings.suggestTimes && calendarAccess == .granted) }

    var busy: [BusyInterval] {
        isDemo ? demo.busy + demoSessions : calendarBusy
    }

    var forecast: WeatherForecast? {
        guard settings.weatherSource != .off else { return nil }
        return isDemo ? demo.forecast : liveForecast
    }

    /// The suggestions for a planned session on a date, or nil for rest days, days without a plan, and today
    /// once something was recorded.
    func schedule(on date: Date) -> DaySchedule? {
        guard isActive, let model, let session = model.plannedSession(on: date), !session.isRest else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date), !model.todaysWorkouts.isEmpty { return nil }
        return SessionScheduler.schedule(
            date: date, session: session, busy: busy, forecast: forecast, settings: settings,
            habits: StartHabits(workouts: model.snapshot?.workouts ?? []), calendar: calendar
        )
    }

    /// Today and the next 7 days, training days only.
    var days: [DaySchedule] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<8).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }.compactMap(schedule(on:))
    }

    /// For the weekly prompt: free time and rain per plan day, or nothing when suggestions are off.
    func availability(start: Date, compact: Bool) -> [String] {
        guard isActive else { return [] }
        let calendar = Calendar.current
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }.map { date in
            SessionScheduler.availabilityLine(
                date: date, label: PromptBuilder.dayLabel(date, calendar: calendar), busy: busy, forecast: forecast,
                settings: settings, compact: compact, calendar: calendar
            )
        }
    }

    // MARK: - Loading

    func refresh(forceWeather: Bool = false) async {
        calendarAccess = CalendarService.access
        guard !isDemo, settings.suggestTimes, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        reloadCalendar()
        await refreshWeather(force: forceWeather)
    }

    /// Asks for calendar access and turns suggestions on if it's given.
    func enable() async {
        if calendarAccess == .notDetermined {
            calendarAccess = await calendar.requestAccess()
        }
        settings.suggestTimes = calendarAccess == .granted
    }

    private func reloadCalendar() {
        calendarAccess = CalendarService.access
        let today = Calendar.current.startOfDay(for: .now)
        calendarBusy = calendar.busy(from: today, to: today.addingTimeInterval(9 * 86400))
    }

    private func refreshWeather(force: Bool) async {
        let source = settings.weatherSource
        guard source != .off else {
            liveForecast = nil
            weatherError = nil
            return
        }
        let key = "\(source.rawValue)|" + (settings.useCurrentLocation ? "here" : settings.place.map { "\($0.latitude),\($0.longitude)" } ?? "none")
        if !force, key == forecastKey, let liveForecast, Date.now.timeIntervalSince(liveForecast.fetchedAt) < 3600 { return }
        do {
            let place: WeatherPlace
            if settings.useCurrentLocation {
                let current = try await WeatherClient.currentLocation().coordinate
                place = WeatherPlace(name: "", latitude: current.latitude, longitude: current.longitude)
            } else if let chosen = settings.place {
                place = chosen
            } else {
                weatherError = "Enter a place for the weather in Settings."
                return
            }
            liveForecast = try await WeatherClient.forecast(source: source, place: place)
            forecastKey = key
            weatherError = nil
            #if WEATHERKIT
            if source == .apple, appleAttribution == nil, let marks = await WeatherClient.appleAttribution() {
                appleAttribution = WeatherAttribution(mark: marks.mark, darkMark: marks.darkMark, legal: marks.legal)
            }
            #endif
        } catch {
            weatherError = "No forecast: \(error.localizedDescription)"
            model?.debugLog("Weather failed: \(error)")
        }
    }

    private var demo: (busy: [BusyInterval], forecast: WeatherForecast) {
        let today = Calendar.current.startOfDay(for: .now)
        if let demoCache, demoCache.day == today { return (demoCache.busy, demoCache.forecast) }
        let fresh = (day: today, busy: DemoSchedule.busy(), forecast: DemoSchedule.forecast())
        demoCache = fresh
        return (fresh.busy, fresh.forecast)
    }

    // MARK: - Calendar events

    /// Puts a session in the calendar at `start`, moving the one Stride added for that day before.
    func add(_ session: PlannedDay, on date: Date, at start: Date) throws {
        let day = Calendar.current.startOfDay(for: date)
        let end = start.addingTimeInterval(TimeInterval(max(session.durationMinutes, 15) * 60))
        if isDemo {
            demoSessions.removeAll { $0.sessionDate == day }
            demoSessions.append(BusyInterval(start: start, end: end, title: session.session, sessionDate: day, eventID: UUID().uuidString))
            model?.debugLog("Demo session added: \(session.session) at \(start.formatted())")
            return
        }
        let existing = calendarBusy.first { $0.sessionDate == day }
        let event = try calendar.add(
            session: session, start: start, end: end, day: day, calendarID: settings.calendarID, replacing: existing?.eventID
        )
        calendarBusy.removeAll { $0.sessionDate == day }
        calendarBusy.append(event)
        calendarBusy.sort { $0.start < $1.start }
    }

    func removeSession(on date: Date) throws {
        let day = Calendar.current.startOfDay(for: date)
        if isDemo {
            demoSessions.removeAll { $0.sessionDate == day }
            return
        }
        for event in calendarBusy where event.sessionDate == day {
            if let id = event.eventID { try calendar.remove(eventID: id) }
        }
        calendarBusy.removeAll { $0.sessionDate == day }
    }

    /// Keeps the calendar in step after the plan for a day changed: the event moves out for a rest day, and
    /// otherwise keeps its start with the new title and length.
    func sessionChanged(on date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        guard let event = busy.first(where: { $0.sessionDate == day }) else { return }
        do {
            if let session = model?.plannedSession(on: day), !session.isRest {
                try add(session, on: day, at: event.start)
            } else {
                try removeSession(on: day)
            }
        } catch {
            model?.debugLog("Updating the calendar event failed: \(error)")
        }
    }

    private static let settingsKey = "scheduleSettings"
}
