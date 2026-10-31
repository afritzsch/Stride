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
                    sessionDate: Self.isOwnSession(event) ? event.url.flatMap(Self.sessionDate) : nil,
                    eventID: event.eventIdentifier
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// Calendars sessions can be added to.
    func writableCalendars() -> [EKCalendar] {
        store.calendars(for: .event).filter(\.allowsContentModifications).sorted { $0.title < $1.title }
    }

    /// Adds a session, replacing the event Stride added for the same day before (so moving it doesn't duplicate it).
    func add(session: PlannedDay, start: Date, end: Date, day: Date, calendarID: String?, replacing eventID: String?) throws -> BusyInterval {
        guard Self.access == .granted else { throw CalendarError.noAccess }
        guard let target = calendarID.flatMap(store.calendar(withIdentifier:)) ?? store.defaultCalendarForNewEvents else {
            throw CalendarError.noCalendar
        }
        let event = EKEvent(eventStore: store)
        event.calendar = target
        event.title = session.session
        event.startDate = start
        event.endDate = end
        event.url = Self.sessionURL(for: day)
        event.notes = [session.briefDescription, session.details, "Planned in Stride."].filter { !$0.isEmpty }.joined(separator: "\n")
        try store.save(event, span: .thisEvent)
        // Only after the new event is saved, so a failed save doesn't lose the old one. If the old one can't be
        // removed, the new session is still in the calendar and is what the caller should track.
        if let eventID, eventID != event.eventIdentifier { try? remove(eventID: eventID) }
        return BusyInterval(start: start, end: end, title: event.title, sessionDate: Calendar.current.startOfDay(for: day), eventID: event.eventIdentifier)
    }

    /// Removes a session Stride added. Anything else (an invite or someone else's event that happens to carry a
    /// session URL) is left alone.
    func remove(eventID: String) throws {
        guard let event = store.event(withIdentifier: eventID), Self.isOwnSession(event) else { return }
        try store.remove(event, span: .thisEvent)
    }

    /// Whether the event can be one Stride added: a session URL is only trusted on an event in a calendar the
    /// athlete can edit, with no other participants and no organizer but the athlete. Otherwise anyone who sends an
    /// invite with such a URL could have Stride move or delete it.
    private static func isOwnSession(_ event: EKEvent) -> Bool {
        guard let url = event.url, sessionDate(from: url) != nil, event.calendar?.allowsContentModifications == true,
              event.calendar?.type != .subscription, event.calendar?.type != .birthday
        else { return false }
        if let organizer = event.organizer, !organizer.isCurrentUser { return false }
        return event.attendees?.allSatisfy(\.isCurrentUser) ?? true
    }

    /// Posted when any calendar changes, inside or outside the app.
    static let changed = Notification.Name.EKEventStoreChanged

    nonisolated static func sessionURL(for day: Date) -> URL {
        let parts = gregorian.dateComponents([.year, .month, .day], from: day)
        let text = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return URL(string: "stride://session/\(text)")!
    }

    /// The day in a `stride://session/<yyyy-MM-dd>` URL, at the start of that day; nil for any other URL.
    nonisolated static func sessionDate(from url: URL) -> Date? {
        guard url.scheme == "stride", url.host() == "session" else { return nil }
        let parts = url.lastPathComponent.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2] else { return nil }
        let calendar = gregorian
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day)
        else { return nil }
        return date
    }

    /// The URL's dates are Gregorian and in the current time zone whatever calendar the user's locale prefers.
    nonisolated private static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}
