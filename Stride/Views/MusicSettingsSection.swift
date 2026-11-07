import SwiftUI

/// Where playlists come from: the iPhone's music library or Spotify (the athlete's own Spotify app, see `SpotifyClient`).
struct MusicSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var isConnecting = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        @Bindable var playlists = model.playlists
        Section {
            Picker("Playlists in", selection: $playlists.source) {
                ForEach(MusicSource.allCases) { Text($0.title).tag($0) }
            }
            if playlists.source == .spotify {
                if playlists.isSpotifyConnected {
                    LabeledContent("Account", value: playlists.spotifyAccountName ?? "Connected")
                    Button("Disconnect Spotify", role: .destructive) { playlists.disconnectSpotify() }
                } else {
                    TextField("Client ID", text: $playlists.spotifyClientID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.body.monospaced())
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Text("Connect Spotify")
                            if isConnecting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(playlists.spotifyClientID.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Set up once:").bold()
                        Text("1. Create an app in the Spotify developer dashboard (select Web API).")
                        Text("2. Add this redirect URI to it:")
                        Button {
                            UIPasteboard.general.string = SpotifyClient.redirectURI
                            copied = true
                        } label: {
                            Label(SpotifyClient.redirectURI, systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.footnote.monospaced())
                        }
                        .buttonStyle(.borderless)
                        Text("3. Copy the app's Client ID into the field above and connect.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Link("Open the Spotify developer dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
        } header: {
            Text("Music")
        } footer: {
            switch playlists.source {
            case .appleMusic:
                Text("Playlists use the songs in your music library, ranked by how often you play them. Songs you only stream don't count: add them with + / Add to Library, and turn on Settings → Apps → Music → Sync Library.")
            case .spotify:
                Text("Playlists use your top, recently played and liked songs on Spotify, and are saved as private playlists in your account. Spotify only lets an app like this run when its owner has Premium; the login stays in this iPhone's Keychain.")
            }
        }
    }

    private func connect() async {
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do {
            try await model.playlists.connectSpotify()
        } catch is CancellationError {
            // The athlete closed the login.
        } catch {
            self.error = error.localizedDescription
        }
    }
}
