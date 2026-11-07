import SwiftUI

/// The playlist for today's session: its sections and songs, with Play, Save to Music and Try again.
struct PlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var day: PlannedDay

    var body: some View {
        let playlists = model.playlists
        NavigationStack {
            List {
                if let playlist = playlists.playlist, !playlists.isBuilding {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(playlist.name).font(.title2.bold())
                            Text(playlist.note).font(.subheadline).foregroundStyle(.secondary)
                            Label(
                                "\(playlist.songs.count) songs · \(playlist.seconds / 60) min for a \(day.durationMinutes)-min session",
                                systemImage: playlist.madeByModel ? "sparkles" : "music.note.list"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        HStack {
                            Button("Play", systemImage: "play.fill") { playlists.play() }
                                .buttonStyle(.borderedProminent)
                            Button(playlists.isSaved ? "Saved" : "Save to Music", systemImage: playlists.isSaved ? "checkmark" : "plus") {
                                Task { await playlists.save() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(playlists.isSaved)
                        }
                        .font(.subheadline)
                    }
                    ForEach(Array(playlist.sections.enumerated()), id: \.offset) { _, section in
                        Section {
                            ForEach(section.songs) { song in
                                SongRow(song: song)
                            }
                        } header: {
                            Text("\(section.segment.role.rawValue) · \(section.segment.minutes) min · \(section.segment.energy.title)")
                        }
                    }
                } else if playlists.isBuilding {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Picking songs from your library…").foregroundStyle(.secondary)
                    }
                }
                if let error = playlists.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if let notice = playlists.notice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Try again", systemImage: "arrow.clockwise") {
                        Task { await playlists.build(for: day) }
                    }
                    .disabled(playlists.isBuilding)
                }
            }
            .task {
                // Keep a playlist made earlier today for the same session.
                if let playlist = playlists.playlist, Calendar.current.isDateInToday(playlist.date), playlist.session == day { return }
                await playlists.build(for: day)
            }
        }
    }
}

private struct SongRow: View {
    var song: LibrarySong

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                Text(song.artist).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(PlaylistBuilder.clock(song.seconds))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
