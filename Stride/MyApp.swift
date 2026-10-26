import SwiftUI

@main struct StrideApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

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
                    repeat {
                        model.refreshModelAvailability()
                        try? await Task.sleep(for: .seconds(5))
                    } while !Task.isCancelled && model.onDeviceBlocker != nil
                }
        }
    }
}
