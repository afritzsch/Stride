import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        TabView(selection: $model.selectedTab) {
            Tab("Dashboard", systemImage: "chart.bar.xaxis", value: AppTab.dashboard) {
                DashboardView()
            }
            Tab("AI Coach", systemImage: "sparkles", value: AppTab.coach) {
                AnalysisView()
            }
            Tab("Plan", systemImage: "calendar", value: AppTab.plan) {
                PlanView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .task {
            await model.refresh()
            model.applyLaunchRoute()
            await model.handleLaunchExport()
        }
    }
}

#Preview {
    let model = AppModel()
    model.useDemoData = true
    return ContentView().environment(model)
}
