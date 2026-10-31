import Foundation
import UserNotifications

/// Posts and schedules Stride's local notifications. What to send and its words come from `NotificationPlanner`.
nonisolated struct NotificationService: Sendable {
    /// userInfo key holding a `NotificationMessage.route`.
    static let routeKey = "route"
    static let kindKey = "kind"

    private var center: UNUserNotificationCenter { .current() }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Asks once; afterwards returns whether notifications are allowed.
    func requestAuthorization() async -> Bool {
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    func post(_ message: NotificationMessage, delay: TimeInterval? = nil) async throws {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.subtitle = message.subtitle
        content.body = message.body
        content.sound = .default
        content.threadIdentifier = message.kind.rawValue
        content.userInfo = [Self.routeKey: message.route, Self.kindKey: message.kind.rawValue]
        let trigger: UNNotificationTrigger?
        if let delay {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 1), repeats: false)
        } else if let fireDate = message.fireDate {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
            trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        } else {
            trigger = nil
        }
        try await center.add(UNNotificationRequest(identifier: message.id, content: content, trigger: trigger))
    }

    /// Makes the pending session reminders exactly `messages`: others are removed, these added or replaced (a
    /// request with the same identifier replaces the old one, so a moved session moves its reminder).
    func replaceSessionReminders(with messages: [NotificationMessage]) async {
        let wanted = Set(messages.map(\.id))
        let stale = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix("session-") && !wanted.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for message in messages {
            do {
                try await post(message)
            } catch {
                print("Stride: scheduling \(message.id) failed: \(error)")
            }
        }
    }
}
