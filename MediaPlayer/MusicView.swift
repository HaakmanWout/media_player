import SwiftUI

/// Music tab: one playlist per subfolder of the Music folder.
struct MusicView: View {
    @ObservedObject var library: LocalLibrary
    @Binding var showNowPlaying: Bool

    var body: some View {
        NavigationStack {
            // A ZStack (not Group) so `.task` runs once per appearance instead of per child view.
            ZStack {
                if library.playlists.isEmpty {
                    if !library.hasLoaded {
                        ProgressView("Loading music…")
                    } else {
                        // Scrollable so pull-to-refresh works on the empty screen too.
                        ScrollView {
                            EmptyLibraryView(library: library, title: "No Playlists")
                                .containerRelativeFrame(.vertical)
                        }
                    }
                } else {
                    List {
                        Section {
                            ForEach(library.playlists) { playlist in
                                NavigationLink(value: playlist.id) {
                                    PlaylistRow(playlist: playlist)
                                }
                            }
                        } header: {
                            Text("Playlists")
                                .listRowInsets(.cardAligned)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .task { await library.reload() }
            .navigationTitle("Music")
            .navigationDestination(for: String.self) { id in
                PlaylistView(library: library, playlistID: id, showNowPlaying: $showNowPlaying)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    LibraryFolderButton(library: library)
                }
            }
            .refreshable { await library.reload() }
            .legacyMiniPlayer(showNowPlaying: $showNowPlaying)
        }
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            PlaylistArtwork(tracks: playlist.tracks, cornerRadius: 8)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(playlist.tracks.count == 1 ? "1 song" : "\(playlist.tracks.count) songs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 2×2 mosaic of the first four songs' artwork; a single cover when the playlist has fewer than four.
private struct PlaylistArtwork: View {
    let tracks: [Track]
    let cornerRadius: CGFloat

    var body: some View {
        if tracks.count >= 4 {
            VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { column in
                            ArtworkView(track: tracks[row * 2 + column], cornerRadius: 0)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            ArtworkView(track: tracks.first, cornerRadius: cornerRadius)
        }
    }
}

struct PlaylistView: View {
    @ObservedObject var library: LocalLibrary
    let playlistID: String
    @Binding var showNowPlaying: Bool
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        if let playlist = library.playlists.first(where: { $0.id == playlistID }) {
            let tracks = playlist.tracks
            List {
                if !tracks.isEmpty {
                    HStack(spacing: 12) {
                        playButton("Play", symbol: "play.fill") { player.play(tracks) }
                        playButton("Shuffle", symbol: "shuffle") { player.play(tracks.shuffled()) }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    if tracks.isEmpty {
                        Text("This folder has no MP3 files yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                        Button {
                            player.play(tracks, startAt: offset)
                        } label: {
                            TrackRow(track: track, isCurrent: player.current?.id == track.id, isPlaying: player.isPlaying)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(tracks.count == 1 ? "1 Song" : "\(tracks.count) Songs")
                        .listRowInsets(.cardAligned)
                }
            }
            .navigationTitle(playlist.name)
            .task { await library.reload() }
            .refreshable { await library.reload() }
            .legacyMiniPlayer(showNowPlaying: $showNowPlaying)
        } else {
            ContentUnavailableView("Playlist Not Found", systemImage: "music.note.list",
                                   description: Text("The folder may have been renamed or removed."))
        }
    }

    private func playButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}
