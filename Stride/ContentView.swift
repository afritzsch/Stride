import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("Dashboard", systemImage: "chart.bar.xaxis") {
                DashboardView()
            }
            Tab("AI Coach", systemImage: "sparkles") {
                AnalysisView()
            }
            Tab("Plan", systemImage: "calendar") {
                PlanView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .task { await model.refresh() }
    }
}

#Preview {
    let model = AppModel()
    model.useDemoData = true
    return ContentView().environment(model)
}
