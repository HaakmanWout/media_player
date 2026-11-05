import SwiftUI

@main
struct MediaPlayerApp: App {
    @StateObject private var player: AudioPlayer
    @StateObject private var podcasts: PodcastStore
    @StateObject private var downloads: DownloadManager
    @StateObject private var music = LocalLibrary(kind: .music)
    @StateObject private var localPodcasts: LocalLibrary

    init() {
        URLCache.shared = URLCache(memoryCapacity: 20_000_000, diskCapacity: 200_000_000)

        // Wire the objects together up front, before any view can trigger a folder scan or playback.
        let player = AudioPlayer()
        let podcasts = PodcastStore()
        let downloads = DownloadManager()
        let localPodcasts = LocalLibrary(kind: .podcasts)
        player.podcastStore = podcasts
        player.downloads = downloads
        downloads.library = localPodcasts
        localPodcasts.downloads = downloads

        _player = StateObject(wrappedValue: player)
        _podcasts = StateObject(wrappedValue: podcasts)
        _downloads = StateObject(wrappedValue: downloads)
        _localPodcasts = StateObject(wrappedValue: localPodcasts)
    }

    var body: some Scene {
        WindowGroup {
            RootView(music: music, localPodcasts: localPodcasts)
                .environmentObject(player)
                .environmentObject(podcasts)
                .environmentObject(downloads)
        }
    }
}

struct RootView: View {
    @ObservedObject var music: LocalLibrary
    @ObservedObject var localPodcasts: LocalLibrary
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var podcasts: PodcastStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNowPlaying = false
    /// Set from the iOS Settings app (Settings.bundle).
    @AppStorage("appearance") private var appearance = AppAppearance.system

    var body: some View {
        tabs
            .sheet(isPresented: $showNowPlaying) {
                NowPlayingView()
            }
            .onAppear { appearance.apply() }
            .onChange(of: appearance) { _, newValue in newValue.apply() }
            .task {
                // Scan both folders up front so a tab's first visit doesn't show it filling in.
                ArtworkLoader.shared.prefetch(remote: podcasts.feeds.compactMap(\.imageURL))
                async let songs: Void = music.reload()
                async let episodes: Void = localPodcasts.reload()
                _ = await (songs, episodes)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                // The appearance may have been changed in the Settings app while we were in the background.
                appearance.apply()
                // Pick up files added in the Files app while we were in the background.
                guard music.hasLoaded || localPodcasts.hasLoaded else { return }
                Task {
                    async let songs: Void = music.reload()
                    async let episodes: Void = localPodcasts.reload()
                    _ = await (songs, episodes)
                }
            }
    }

    @ViewBuilder
    private var tabs: some View {
        let tabView = TabView {
            MusicView(library: music, showNowPlaying: $showNowPlaying)
                .tabItem { Image(systemName: "music.note").accessibilityLabel("Music") }
            PodcastsView(localLibrary: localPodcasts, showNowPlaying: $showNowPlaying)
                .tabItem { Image(systemName: "mic.fill").accessibilityLabel("Podcasts") }
        }
        if #available(iOS 26.1, *) {
            tabView
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory(isEnabled: player.current != nil) {
                    MiniPlayer { showNowPlaying = true }
                }
        } else {
            tabView
        }
    }
}

extension View {
    /// Pre-iOS 26.1 fallback: pin the mini player above the tab bar inside each tab.
    @ViewBuilder
    func legacyMiniPlayer(showNowPlaying: Binding<Bool>) -> some View {
        if #available(iOS 26.1, *) {
            self
        } else {
            safeAreaInset(edge: .bottom) {
                LegacyMiniPlayerContainer { showNowPlaying.wrappedValue = true }
            }
        }
    }
}

private struct LegacyMiniPlayerContainer: View {
    @EnvironmentObject private var player: AudioPlayer
    let onTap: () -> Void

    var body: some View {
        if player.current != nil {
            MiniPlayer(onTap: onTap)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
    }
}

/// Light / Dark override chosen in the iOS Settings app; `system` follows the phone.
enum AppAppearance: String {
    case system, light, dark

    /// Applied to the windows directly (not `preferredColorScheme`), so switching back to System
    /// reliably follows the phone again, including for sheets.
    @MainActor
    func apply() {
        let style: UIUserInterfaceStyle = switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach { $0.overrideUserInterfaceStyle = style }
        }
    }
}
