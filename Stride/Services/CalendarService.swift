import EventKit
import Foundation

nonisolated enum CalendarError: LocalizedError {
    case noAccess
    case noCalendar

    var errorDescription: String? {
        switch self {
        case .noAccess: "Stride can't see your calendar. Allow full access in Settings → Apps → Stride → Calendars."
        case .noCalendar: "There's no calendar to add sessions to."
        }
    }
}

/// Reads busy time from the athlete's calendars and adds planned sessions as events. Events Stride adds carry a
/// `stride://session/<yyyy-MM-dd>` URL, so they're recognized as sessions instead of being planned around.
final class CalendarService {
    enum Access: Equatable { case notDetermined, denied, granted }

    private let store = EKEventStore()

    static var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() async -> Access {
        _ = try? await store.requestFullAccessToEvents()
        return Self.access
    }

    /// Timed events that block time (all-day events, free events and declined or cancelled ones don't).
    func busy(from start: Date, to end: Date) -> [BusyInterval] {
        guard Self.access == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { event in
                !event.isAllDay && event.availability != .free && event.status != .canceled
                    && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
            }
            .map { event in
                BusyInterval(
                    start: event.startDate,
                    end: event.endDate,
                    title: event.title ?? "",
                    sessionDate: event.url.flatMap(Self.sessionDate),
                    eventID: event.eventIdentifier
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// Calendars sessions can be added to.
    func writableCalendars() -> [EKCalendar] {
        store.calendars(for: .event).filter(\.allowsContentModifications).sorted { $0.title < $1.title }
    }

    var defaultCalendarID: String? { store.defaultCalendarForNewEvents?.calendarIdentifier }

    /// Adds a session, replacing the event Stride added for the same day before (so moving it doesn't duplicate it).
    func add(session: PlannedDay, start: Date, end: Date, day: Date, calendarID: String?, replacing eventID: String?) throws -> BusyInterval {
        guard Self.access == .granted else { throw CalendarError.noAccess }
        guard let target = calendarID.flatMap(store.calendar(withIdentifier:)) ?? store.defaultCalendarForNewEvents else {
            throw CalendarError.noCalendar
        }
        if let eventID { try remove(eventID: eventID) }
        let event = EKEvent(eventStore: store)
        event.calendar = target
        event.title = session.session
        event.startDate = start
        event.endDate = end
        event.url = Self.sessionURL(for: day)
        event.notes = [session.briefDescription, session.details, "Planned in Stride."].filter { !$0.isEmpty }.joined(separator: "\n")
        try store.save(event, span: .thisEvent)
        return BusyInterval(start: start, end: end, title: event.title, sessionDate: Calendar.current.startOfDay(for: day), eventID: event.eventIdentifier)
    }

    func remove(eventID: String) throws {
        guard let event = store.event(withIdentifier: eventID) else { return }
        try store.remove(event, span: .thisEvent)
    }

    /// Posted when any calendar changes, inside or outside the app.
    static let changed = Notification.Name.EKEventStoreChanged

    nonisolated static func sessionURL(for day: Date) -> URL {
        URL(string: "stride://session/\(dayFormatter().string(from: day))")!
    }

    nonisolated static func sessionDate(from url: URL) -> Date? {
        guard url.scheme == "stride", url.host() == "session" else { return nil }
        return dayFormatter().date(from: url.lastPathComponent)
    }

    nonisolated private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
