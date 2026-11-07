import Foundation
import MediaPlayer

/// The athlete's music library through MediaPlayer. Unlike MusicKit's catalog and `MusicLibrary` APIs, this needs
/// no MusicKit app service (a paid developer account), only `NSAppleMusicUsageDescription`. It sees songs in the
/// library (bought, synced or added from Apple Music), not the Apple Music catalog.
enum MusicLibraryService {
    static var isAuthorized: Bool { MPMediaLibrary.authorizationStatus() == .authorized }

    static func requestAccess() async -> Bool {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: return true
        case .notDetermined: return await MPMediaLibrary.requestAuthorization() == .authorized
        default: return false
        }
    }

    /// Music in the library, without podcasts, audiobooks or videos.
    static func songs() -> [LibrarySong] {
        let items = MPMediaQuery.songs().items ?? []
        return items.compactMap { item in
            guard item.mediaType.contains(.music), let title = item.title else { return nil }
            return LibrarySong(
                id: String(item.persistentID),
                title: title,
                artist: item.artist ?? item.albumArtist ?? "Unknown artist",
                genre: item.genre ?? "",
                seconds: Int(item.playbackDuration),
                playCount: item.playCount,
                skipCount: item.skipCount,
                lastPlayed: item.lastPlayedDate,
                added: item.dateAdded
            )
        }
    }

    /// Adds the playlist to the Music app's library.
    static func save(_ playlist: WorkoutPlaylist) async throws {
        let metadata = MPMediaPlaylistCreationMetadata(name: playlist.name)
        metadata.descriptionText = playlist.note
        let created = try await MPMediaLibrary.default().getPlaylist(with: playlist.id, creationMetadata: metadata)
        try await created.add(items(for: playlist))
    }

    /// Plays the playlist in the Music app's player, so it keeps playing with Stride closed.
    static func play(_ playlist: WorkoutPlaylist) {
        let player = MPMusicPlayerController.systemMusicPlayer
        player.setQueue(with: MPMediaItemCollection(items: items(for: playlist)))
        player.play()
    }

    private static func items(for playlist: WorkoutPlaylist) -> [MPMediaItem] {
        playlist.songs.compactMap { song in
            guard let id = UInt64(song.id) else { return nil }
            let query = MPMediaQuery()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID))
            return query.items?.first
        }
    }
}
