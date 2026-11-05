import SwiftUI

struct PodcastsView: View {
    @ObservedObject var localLibrary: LocalLibrary
    @Binding var showNowPlaying: Bool
    @EnvironmentObject private var store: PodcastStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("subscriptionsExpanded") private var subscriptionsExpanded = false
    @State private var showAddFeed = false
    @State private var newFeedURL = ""
    @State private var isAdding = false
    @State private var addError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.feeds.isEmpty {
                        Button {
                            showAddFeed = true
                        } label: {
                            Label("Add an RSS feed", systemImage: "plus.circle.fill")
                        }
                    }
                    if !isCollapsible || subscriptionsExpanded {
                        ForEach(store.feeds) { feed in
                            NavigationLink(value: feed.id) {
                                FeedRow(feed: feed, hasNewEpisode: store.hasNewEpisode(feed))
                            }
                        }
                        .onDelete(perform: store.removeFeeds)
                    }
                } header: {
                    subscriptionsHeader
                        .listRowInsets(.cardAligned)
                }

                Section {
                    if localLibrary.tracks.isEmpty {
                        Text(localLibrary.isLoading ? "Scanning…" : "No MP3 files found.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(localLibrary.tracks.enumerated()), id: \.element.id) { offset, track in
                        Button {
                            player.play(localLibrary.tracks, startAt: offset)
                        } label: {
                            EpisodeRow(track: track, progress: store.progress(for: track.id), isCurrent: player.current?.id == track.id)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            PlayedToggle(trackID: track.id)
                        }
                    }
                    .onDelete { offsets in
                        let tracks = localLibrary.tracks
                        for index in offsets {
                            localLibrary.delete(tracks[index])
                            downloads.forget(tracks[index].id)
                        }
                    }
                } header: {
                    Text("Files")
                        .listRowInsets(.cardAligned)
                }
            }
            .task { await localLibrary.reload() }
            .navigationTitle("Podcasts")
            .navigationDestination(for: UUID.self) { id in
                FeedDetailView(feedID: id, showNowPlaying: $showNowPlaying)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddFeed = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Podcast")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    LibraryFolderButton(library: localLibrary)
                }
            }
            .refreshable {
                async let feeds: Void = store.refreshAll()
                async let files: Void = localLibrary.reload()
                _ = await (feeds, files)
            }
            .overlay {
                if isAdding {
                    ProgressView("Adding podcast…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("Add Podcast", isPresented: $showAddFeed) {
                TextField("https://example.com/feed.xml", text: $newFeedURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") { addFeed() }
                Button("Cancel", role: .cancel) { newFeedURL = "" }
            } message: {
                Text("Enter the podcast's RSS feed URL.")
            }
            .alert("Couldn't Add Podcast", isPresented: Binding(
                get: { addError != nil },
                set: { if !$0 { addError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(addError ?? "")
            }
            .alert("Download Failed", isPresented: Binding(
                get: { downloads.errorMessage != nil },
                set: { if !$0 { downloads.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(downloads.errorMessage ?? "")
            }
            .legacyMiniPlayer(showNowPlaying: $showNowPlaying)
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await store.refreshIfStale() }
        }
    }

    /// Long subscription lists fold away so the files below stay in reach.
    private var isCollapsible: Bool { store.feeds.count > 3 }

    @ViewBuilder
    private var subscriptionsHeader: some View {
        if isCollapsible {
            Button {
                withAnimation { subscriptionsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Subscriptions")
                    Text("\(store.feeds.count)")
                        .foregroundStyle(.tertiary)
                    if !subscriptionsExpanded, store.feeds.contains(where: store.hasNewEpisode) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("New episodes")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(subscriptionsExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(subscriptionsExpanded ? "Collapses the list" : "Expands the list")
        } else {
            Text("Subscriptions")
        }
    }

    private func addFeed() {
        let input = newFeedURL
        newFeedURL = ""
        isAdding = true
        Task {
            do {
                try await store.addFeed(input)
            } catch {
                addError = error.localizedDescription
            }
            isAdding = false
        }
    }
}

private struct FeedRow: View {
    let feed: PodcastFeed
    let hasNewEpisode: Bool

    private var details: String {
        var parts: [String] = []
        if let latest = feed.episodes.compactMap(\.pubDate).max() {
            parts.append("Latest \(Self.relative(latest))")
        }
        parts.append(feed.episodes.count == 1 ? "1 episode" : "\(feed.episodes.count) episodes")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(remoteURL: feed.imageURL, cornerRadius: 8)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(feed.title)
                    .font(.headline)
                    .lineLimit(2)
                if let author = feed.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if hasNewEpisode {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel("New episode")
            }
        }
    }

    private static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        return Format.date(date)
    }
}

struct FeedDetailView: View {
    let feedID: UUID
    @Binding var showNowPlaying: Bool
    @EnvironmentObject private var store: PodcastStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: DownloadManager
    @State private var refreshError: String?
    @State private var hidePlayed = false

    var body: some View {
        if let feed = store.feed(id: feedID) {
            let episodes = feed.episodes
                .filter { !hidePlayed || !store.progress(for: feed.track(for: $0).id).played }
            List {
                header(feed)
                    .listRowSeparator(.hidden)

                ForEach(episodes) { episode in
                    let track = feed.track(for: episode)
                    HStack(spacing: 8) {
                        Button {
                            player.play([track])
                        } label: {
                            EpisodeRow(track: track, progress: store.progress(for: track.id), isCurrent: player.current?.id == track.id)
                        }
                        .buttonStyle(.plain)
                        DownloadButton(trackID: track.id) {
                            downloads.download(episode, in: feed)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        PlayedToggle(trackID: track.id)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(feed.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        hidePlayed.toggle()
                    } label: {
                        Image(systemName: hidePlayed ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .refreshable {
                do {
                    try await store.refresh(feedID)
                } catch {
                    refreshError = error.localizedDescription
                }
            }
            .alert("Refresh Failed", isPresented: Binding(
                get: { refreshError != nil },
                set: { if !$0 { refreshError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(refreshError ?? "")
            }
            .legacyMiniPlayer(showNowPlaying: $showNowPlaying)
        } else {
            ContentUnavailableView("Podcast Removed", systemImage: "mic.slash")
        }
    }

    private func header(_ feed: PodcastFeed) -> some View {
        VStack(spacing: 12) {
            ArtworkView(remoteURL: feed.imageURL, size: .large, cornerRadius: 12)
                .frame(width: 180, height: 180)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            Text(feed.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            if let author = feed.author, !author.isEmpty {
                Text(author)
                    .foregroundStyle(.secondary)
            }
            if let summary = feed.summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct EpisodeRow: View {
    let track: Track
    let progress: EpisodeProgress
    let isCurrent: Bool

    private var detail: String {
        var parts: [String] = []
        if track.isLocal, let podcast = track.artist { parts.append(podcast) }
        if let date = track.date, !track.isLocal { parts.append(Format.date(date)) }
        if let duration = track.duration {
            if progress.position > 0, !progress.played {
                parts.append("\(Format.duration(max(duration - progress.position, 60))) left")
            } else {
                parts.append(Format.duration(duration))
            }
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkView(track: track)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isCurrent ? Color.accentColor : progress.played ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if progress.played {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    Text(detail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let duration = track.duration, progress.position > 0, !progress.played {
                    ProgressView(value: min(progress.position / duration, 1))
                        .frame(maxWidth: 120)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Download / progress (tap to cancel) / downloaded (menu to remove) control for an episode row.
private struct DownloadButton: View {
    let trackID: String
    let download: () -> Void
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        Group {
            switch downloads.state(for: trackID) {
            case .none:
                Button(action: download) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel("Download")
            case .downloading(let progress):
                Button {
                    downloads.cancel(trackID)
                } label: {
                    ZStack {
                        Circle().stroke(Color(.quaternaryLabel), lineWidth: 2.5)
                        if let progress {
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.2), value: progress)
                        } else {
                            SpinningArc()
                        }
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    }
                    .frame(width: 24, height: 24)
                }
                .accessibilityLabel("Cancel download")
            case .downloaded:
                Menu {
                    Button(role: .destructive) {
                        downloads.delete(trackID)
                    } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Downloaded")
            }
        }
        .buttonStyle(.borderless)
        .frame(width: 32, height: 32)
    }
}

/// Indeterminate progress drawn on the same ring, for downloads whose size isn't known yet.
private struct SpinningArc: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

private struct PlayedToggle: View {
    let trackID: String
    @EnvironmentObject private var store: PodcastStore

    var body: some View {
        let played = store.progress(for: trackID).played
        Button {
            store.setPlayed(!played, for: trackID)
        } label: {
            Label(played ? "Unplayed" : "Played", systemImage: played ? "circle" : "checkmark.circle")
        }
        .tint(.accentColor)
    }
}
