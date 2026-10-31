import SwiftUI
import UIKit

/// One switch per notification. Permission is asked when the first one is turned on.
struct NotificationSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var model = model
        let settings = model.notificationSettings

        Section {
            toggle("Morning readiness", kind: .readiness, isOn: settings.readiness)
            toggle("New workouts", kind: .workout, isOn: settings.newWorkouts)
            toggle("Session reminders", kind: .session, isOn: settings.sessionReminders)
            if settings.sessionReminders {
                Picker("Remind me", selection: $model.notificationSettings.reminderLeadMinutes) {
                    ForEach(NotificationSettings.leadChoices, id: \.self) { Text("\($0) min before").tag($0) }
                }
            }
            if model.notificationAuthorization == .denied {
                Button("Allow notifications in iOS Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(footer(settings))
        }
    }

    private func toggle(_ title: String, kind: NotificationKind, isOn: Bool) -> some View {
        Toggle(title, isOn: Binding(
            get: { isOn },
            set: { on in Task { await model.setNotifications(kind, on: on) } }
        ))
    }

    private func footer(_ settings: NotificationSettings) -> String {
        var lines = [
            "Morning readiness: when your resting HR, HRV or sleep are off and a session is planned. New workouts: when a workout syncs, with the coach review a tap away. Session reminders: before the sessions Stride put in your calendar, with the forecast.",
        ]
        if model.notificationAuthorization == .denied {
            lines.append("Notifications are turned off for Stride in iOS Settings.")
        } else if settings.sessionReminders, !model.schedule.isActive {
            lines.append("Session reminders need time suggestions (above) and a session added to your calendar.")
        }
        if settings.anyOn {
            lines.append("Stride checks Apple Health in the background when your watch syncs. The coach writes its reviews when you open the app, or in the background when Apple Intelligence allows it.")
        }
        return lines.joined(separator: "\n\n")
    }
}
