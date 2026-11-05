import Foundation

/// Anything the player can play: a local MP3 (music or podcast) or a streamed RSS episode.
struct Track: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    var title: String
    var artist: String?
    var album: String?
    var duration: TimeInterval?
    var artworkURL: URL?
    var date: Date?
    var isPodcast: Bool
    /// Top-level subfolder of the library the file lives in (nil when it sits directly in the library folder).
    var folder: String? = nil

    var isLocal: Bool { url.isFileURL }
}

/// A music playlist: one top-level subfolder of the Music folder.
struct Playlist: Identifiable, Hashable {
    static let looseSongsID = "\u{0}loose"

    let id: String
    let name: String
    let tracks: [Track]
}

struct Episode: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var pubDate: Date?
    var duration: TimeInterval?
    var audioURL: URL
    var imageURL: URL?
}

struct PodcastFeed: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var feedURL: URL
    var title: String
    var author: String?
    var summary: String?
    var imageURL: URL?
    var episodes: [Episode]
    var lastUpdated: Date?

    func track(for episode: Episode) -> Track {
        Track(
            id: "episode:\(episode.id)",
            url: episode.audioURL,
            title: episode.title,
            artist: title,
            album: title,
            duration: episode.duration,
            artworkURL: episode.imageURL ?? imageURL,
            date: episode.pubDate,
            isPodcast: true
        )
    }
}

struct EpisodeProgress: Codable, Hashable, Sendable {
    var position: TimeInterval = 0
    var played = false
}

enum Format {
    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
    }

    static func date(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
