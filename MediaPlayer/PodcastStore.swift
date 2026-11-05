import Foundation

/// Subscribed RSS feeds plus listening progress for every podcast episode (streamed or local).
@MainActor
final class PodcastStore: ObservableObject {
    @Published private(set) var feeds: [PodcastFeed] = []
    @Published private(set) var progress: [String: EpisodeProgress] = [:]
    @Published private(set) var isRefreshing = false

    private let feedsFile: URL
    private let progressFile: URL

    init() {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        feedsFile = dir.appending(path: "feeds.json")
        progressFile = dir.appending(path: "progress.json")

        if let data = try? Data(contentsOf: feedsFile),
           let saved = try? JSONDecoder().decode([PodcastFeed].self, from: data) {
            feeds = saved
        }
        if let data = try? Data(contentsOf: progressFile),
           let saved = try? JSONDecoder().decode([String: EpisodeProgress].self, from: data) {
            progress = saved
        }
    }

    func feed(id: UUID) -> PodcastFeed? {
        feeds.first { $0.id == id }
    }

    // MARK: - Feeds

    func addFeed(_ input: String) async throws {
        guard let url = Self.normalizedURL(input) else { throw URLError(.badURL) }
        if feeds.contains(where: { $0.feedURL == url }) { return }

        let parsed = try await Self.fetch(url)
        feeds.append(PodcastFeed(
            id: UUID(),
            feedURL: url,
            title: parsed.title.isEmpty ? url.host() ?? "Podcast" : parsed.title,
            author: parsed.author,
            summary: parsed.summary,
            imageURL: parsed.imageURL,
            episodes: Self.sorted(parsed.episodes),
            lastUpdated: .now
        ))
        saveFeeds()
    }

    func refresh(_ id: UUID) async throws {
        guard let feed = feed(id: id) else { return }
        let parsed = try await Self.fetch(feed.feedURL)
        guard let index = feeds.firstIndex(where: { $0.id == id }) else { return }
        if !parsed.title.isEmpty { feeds[index].title = parsed.title }
        feeds[index].author = parsed.author ?? feeds[index].author
        feeds[index].summary = parsed.summary ?? feeds[index].summary
        feeds[index].imageURL = parsed.imageURL ?? feeds[index].imageURL
        feeds[index].episodes = Self.sorted(parsed.episodes)
        feeds[index].lastUpdated = .now
        saveFeeds()
    }

    func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for feed in feeds {
                group.addTask { try? await self.refresh(feed.id) }
            }
        }
    }

    /// Refreshes feeds that haven't been checked recently; used when the app comes to the foreground.
    func refreshIfStale(olderThan interval: TimeInterval = 30 * 60) async {
        guard !isRefreshing else { return }
        let stale = feeds.filter { ($0.lastUpdated ?? .distantPast) < Date.now.addingTimeInterval(-interval) }
        guard !stale.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for feed in stale {
                group.addTask { try? await self.refresh(feed.id) }
            }
        }
    }

    /// True when the feed has an unplayed episode published in the last two days.
    func hasNewEpisode(_ feed: PodcastFeed) -> Bool {
        let cutoff = Date.now.addingTimeInterval(-2 * 24 * 60 * 60)
        return feed.episodes.contains { episode in
            guard let date = episode.pubDate, date >= cutoff else { return false }
            return !progress(for: feed.track(for: episode).id).played
        }
    }

    func removeFeeds(at offsets: IndexSet) {
        feeds.remove(atOffsets: offsets)
        saveFeeds()
    }

    // MARK: - Progress

    func progress(for trackID: String) -> EpisodeProgress {
        progress[trackID] ?? EpisodeProgress()
    }

    func setPosition(_ position: TimeInterval, for trackID: String) {
        progress[trackID, default: EpisodeProgress()].position = position
        saveProgress()
    }

    func setPlayed(_ played: Bool, for trackID: String) {
        progress[trackID] = EpisodeProgress(position: 0, played: played)
        saveProgress()
    }

    // MARK: - Persistence

    private func saveFeeds() {
        if let data = try? JSONEncoder().encode(feeds) {
            try? data.write(to: feedsFile, options: .atomic)
        }
    }

    private func saveProgress() {
        if let data = try? JSONEncoder().encode(progress) {
            try? data.write(to: progressFile, options: .atomic)
        }
    }

    // MARK: - Helpers

    private static func fetch(_ url: URL) async throws -> ParsedFeed {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try await Task.detached { try RSSParser.parse(data) }.value
    }

    private static func sorted(_ episodes: [Episode]) -> [Episode] {
        episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
    }

    static func normalizedURL(_ input: String) -> URL? {
        var string = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        for scheme in ["feed://", "podcast://", "pcast://", "itpc://"] where string.lowercased().hasPrefix(scheme) {
            string = "https://" + string.dropFirst(scheme.count)
        }
        if !string.contains("://") { string = "https://" + string }
        guard let url = URL(string: string), url.host() != nil else { return nil }
        return url
    }
}
