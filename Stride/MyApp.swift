import SwiftUI
import UIKit
import UserNotifications

@main struct StrideApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                #if DEBUG
                .task { await model.probeModelIfAsked() }
                #endif
                .task(id: scenePhase) {
                    // Model availability isn't observable and changes while the app runs (e.g. the model finishes
                    // downloading or gets updated), so re-check on activation and while it isn't ready.
                    guard scenePhase == .active else { return }
                    await model.refreshNotificationAuthorization()
                    repeat {
                        model.refreshModelAvailability()
                        try? await Task.sleep(for: .seconds(5))
                    } while !Task.isCancelled && model.onDeviceBlocker != nil
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.scheduleBackgroundRefresh() }
        }
        .backgroundTask(.appRefresh(AppModel.backgroundRefreshTaskID)) {
            await model.backgroundAppRefresh()
        }
    }
}

/// Owns the model, so that a background launch (HealthKit delivering new samples, a notification tap) reaches it
/// before any view exists: observer queries have to be running before launching finishes, and the notification
/// delegate has to be set by then.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { await model.startBackgroundObservers() }
        return true
    }

    /// Shows notifications while the app is open too (session reminders, the debug hooks).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        model.handleNotificationTap(userInfo: response.notification.request.content.userInfo)
    }
}
