import Foundation
import Observation

/// A playlist for a planned session from the athlete's own music library (owned by `AppModel` like `strength`).
/// Code picks the sections and a shortlist of real songs (`PlaylistBuilder`); the on-device model only chooses
/// among them and names the playlist. Without Apple Intelligence, code picks alone. Demo data uses `DemoMusic`.
@Observable
final class PlaylistModel {
    /// Shows the playlist sheet (the Today card's button, or the `playlist` route).
    var isShowing = false
    private(set) var playlist: WorkoutPlaylist?
    private(set) var isBuilding = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var isSaved = false

    @ObservationIgnored private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    private var isDemo: Bool { model?.snapshot?.isDemo == true }

    /// Today's planned session, or the athlete's usual one on a rest day or without a plan.
    var todaysSession: PlannedDay {
        if let planned = model?.todaysPlan, !planned.isRest, planned.durationMinutes > 0 { return planned }
        return PlaylistBuilder.usualSession(recent: model?.snapshot?.workouts ?? [], now: .now)
    }

    func build(for day: PlannedDay, on date: Date = .now) async {
        guard let model, !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }
        error = nil
        notice = nil
        isSaved = false
        // A second try avoids the last playlist's songs.
        let avoid = Set(playlist?.songs.map(\.id) ?? [])

        let library: [LibrarySong]
        if isDemo {
            library = DemoMusic.library(workouts: model.snapshot?.workouts ?? [])
        } else {
            guard await MusicLibraryService.requestAccess() else {
                error = "Stride can't read your music library. Allow it in Settings → Apps → Stride → Media & Apple Music."
                return
            }
            library = MusicLibraryService.songs()
        }

        let segments = PlaylistBuilder.segments(for: day)
        guard !segments.isEmpty else { error = PlaylistError.restDay.localizedDescription; return }
        let workouts = model.snapshot?.workouts ?? []
        let shortlists = PlaylistBuilder.shortlists(for: segments, library: library, workouts: workouts, avoid: avoid, now: date)
        let candidates = shortlists.reduce(0) { $0 + $1.count }
        guard candidates >= PlaylistBuilder.minimumLibrary else {
            error = PlaylistError.tooFewSongs(candidates).localizedDescription
            return
        }

        var draft: PlaylistDraft?
        if let blocker = model.currentAIBlocker() {
            notice = "Picked by your play counts. \(blocker)"
        } else {
            let prompt = PlaylistBuilder.prompt(
                day: day, segments: segments, shortlists: shortlists,
                favouriteArtists: PlaylistBuilder.favouriteArtists(in: library)
            )
            do {
                draft = try await model.generate(
                    PlaylistDraft.self,
                    instructions: PlaylistBuilder.instructions,
                    fullPrompt: prompt,
                    compactPrompt: prompt,
                    options: AppleAnalyzer.precise
                ).output
            } catch {
                model.debugLog("Playlist generation failed: \(error.localizedDescription)")
                notice = "Apple Intelligence couldn't pick the songs, so Stride picked by your play counts."
            }
        }
        playlist = PlaylistBuilder.assemble(day: day, date: date, segments: segments, shortlists: shortlists, draft: draft)
    }

    func save() async {
        guard let playlist else { return }
        if isDemo {
            notice = "Demo data: the playlist isn't saved to Music."
            isSaved = true
            return
        }
        do {
            try await MusicLibraryService.save(playlist)
            isSaved = true
            notice = "Saved to Music as “\(playlist.name)”."
        } catch {
            self.error = "Couldn't save the playlist: \(error.localizedDescription)"
        }
    }

    func play() {
        guard let playlist else { return }
        if isDemo {
            notice = "Demo data: there's nothing to play."
            return
        }
        MusicLibraryService.play(playlist)
    }
}
