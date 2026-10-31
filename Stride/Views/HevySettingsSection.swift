import SwiftUI

/// Connects the Hevy lifting log with the athlete's API key (Hevy Pro).
struct HevySettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var apiKey = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        let strength = model.strength
        Section {
            if strength.isConnected {
                LabeledContent("Account", value: strength.accountName ?? "Connected")
                LabeledContent("Workouts read", value: "\(strength.sessions?.count ?? 0)")
                if let lastSync = strength.lastSync {
                    LabeledContent("Last sync") {
                        Text(lastSync, format: .relative(presentation: .named))
                    }
                }
                if let syncError = strength.syncError {
                    Text(syncError).font(.footnote).foregroundStyle(.orange)
                }
                Button {
                    Task { await strength.sync(force: true) }
                } label: {
                    HStack {
                        Text("Sync now")
                        if strength.isSyncing { Spacer(); ProgressView() }
                    }
                }
                .disabled(strength.isSyncing)
                Button("Disconnect Hevy", role: .destructive) { strength.disconnect() }
            } else {
                SecureField("API key", text: $apiKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Text("Connect Hevy")
                        if isConnecting { Spacer(); ProgressView() }
                    }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                Link("Get your API key", destination: URL(string: "https://hevy.com/settings?developer")!)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Strength log")
        } footer: {
            Text("Hevy records the exercises, sets and weights that Apple Health never gets. With it connected, strength workouts show what you lifted and coach reviews judge the lifting itself. The API key needs Hevy Pro and stays in this iPhone's Keychain; Stride only reads your workouts.")
        }
    }

    private func connect() async {
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do {
            try await model.strength.connect(apiKey: apiKey)
            apiKey = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
