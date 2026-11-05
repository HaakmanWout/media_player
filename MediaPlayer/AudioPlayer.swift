import AVFoundation
import MediaPlayer
import UIKit

/// Single shared player: queue handling, background audio, lock screen / Control Center controls,
/// and saving podcast positions.
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// True while the player is waiting on the network, e.g. a stream starting up or rebuffering.
    @Published private(set) var isLoading = false
    /// The track that just failed to play; cleared shortly after, or when a track is loaded again.
    @Published private(set) var failedTrackID: String?

    static let skipBack: TimeInterval = 15
    static let skipForward: TimeInterval = 30
    static let failureDisplayTime: Duration = .seconds(5)

    var podcastStore: PodcastStore?
    var downloads: DownloadManager?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var artwork: UIImage?
    private var lastProgressSave = Date.distantPast
    private var currentItemFailed = false
    private var activeSeek: UUID?
    private var failureResetTask: Task<Void, Never>?
    private let sessionFile = URL.applicationSupportDirectory.appending(path: "playback.json")

    /// What was playing, so it can be picked up again after a relaunch. Tracks are stored by ID and looked
    /// up again on restore, because file locations and tags can change between launches.
    private struct PlaybackSession: Codable {
        var queue: [String]
        var currentID: String
        var position: TimeInterval
    }

    var hasNext: Bool { index + 1 < queue.count }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        configureRemoteCommands()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = status == .waitingToPlayAtSpecifiedRate
                let playing = status != .paused
                guard self.isPlaying != playing else { return }
                self.isPlaying = playing
                if !playing { self.saveProgress() }
                self.updateNowPlaying()
            }
        }

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.itemDidFinish(item) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, item === self.player.currentItem else { return }
                self.playbackFailed()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.handleInterruption(info) }
        })
    }

    // MARK: - Playback

    func play(_ tracks: [Track], startAt startIndex: Int = 0) {
        guard tracks.indices.contains(startIndex) else { return }
        queue = tracks
        index = startIndex
        load(tracks[startIndex])
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard let current else { return }
        // A failed item can't be restarted, so pressing play tries the track again from scratch.
        if currentItemFailed {
            load(current)
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    func pause() {
        player.pause()
    }

    func next() {
        if hasNext {
            index += 1
            load(queue[index])
        } else if current?.isPodcast == false {
            // Music starts the playlist over when it reaches the end.
            index = 0
            load(queue[index])
        } else {
            pause()
            seek(to: 0)
        }
    }

    func previous() {
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            load(queue[index])
        }
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, duration > 0 ? min(time, duration) : time)
        currentTime = clamped
        startSeek(to: clamped)
        updateNowPlaying()
        saveProgress()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    /// Puts back the track and queue from the last run, paused where it was. `available` is every track
    /// the libraries and feeds know about; anything no longer among them is left out.
    func restoreSession(from available: [Track]) {
        guard current == nil,
              let data = try? Data(contentsOf: sessionFile),
              let session = try? JSONDecoder().decode(PlaybackSession.self, from: data)
        else { return }
        let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tracks = session.queue.compactMap { byID[$0] }
        guard let start = tracks.firstIndex(where: { $0.id == session.currentID }) else { return }
        queue = tracks
        index = start
        load(tracks[start], resumeAt: session.position, autoplay: false)
    }

    /// Picks up changes from a library rescan: new tags on queued tracks, and files that have gone.
    func refreshTracks(_ tracks: [Track]) {
        let fresh = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentID = current?.id
        // A renamed or deleted file can't be played any more, unless it's already playing.
        queue = queue.map { fresh[$0.id] ?? $0 }.filter {
            !$0.isLocal || $0.id == currentID || FileManager.default.fileExists(atPath: $0.url.path)
        }
        guard let currentID else { return }
        index = queue.firstIndex { $0.id == currentID } ?? 0
        if let updated = fresh[currentID], updated != current {
            current = updated
            updateNowPlaying()
        }
        saveSession()
    }

    private func load(_ track: Track, resumeAt: TimeInterval = 0, autoplay: Bool = true) {
        saveProgress()
        current = track
        artwork = nil
        duration = track.duration ?? 0
        currentTime = 0
        failedTrackID = nil
        currentItemFailed = false
        failureResetTask?.cancel()
        activeSeek = nil

        let item = AVPlayerItem(url: downloads?.localURL(for: track.id) ?? track.url)
        let trackID = track.id
        itemStatusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.current?.id == trackID else { return }
                self.playbackFailed()
            }
        }
        player.replaceCurrentItem(with: item)

        if track.isPodcast, let store = podcastStore {
            let saved = store.progress(for: track.id)
            let nearEnd = duration > 0 && saved.position > duration - 15
            if saved.position > 5, !nearEnd {
                currentTime = saved.position
                startSeek(to: saved.position)
            }
        } else if resumeAt > 0 {
            currentTime = resumeAt
            startSeek(to: resumeAt)
        }

        updateCommandAvailability()
        if autoplay { resume() }
        updateNowPlaying()
        saveSession()

        Task {
            let image = await ArtworkLoader.shared.image(for: track, size: .large)
            guard current?.id == track.id else { return }
            artwork = image
            updateNowPlaying()
        }
    }

    /// Until a seek completes the player still reports the old position, which `tick` has to ignore.
    private func startSeek(to time: TimeInterval) {
        let id = UUID()
        activeSeek = id
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                if self?.activeSeek == id { self?.activeSeek = nil }
            }
        }
    }

    private func playbackFailed() {
        failedTrackID = current?.id
        currentItemFailed = true
        isLoading = false
        pause()
        failureResetTask?.cancel()
        failureResetTask = Task { [weak self] in
            try? await Task.sleep(for: Self.failureDisplayTime)
            guard !Task.isCancelled else { return }
            self?.failedTrackID = nil
        }
    }

    private func tick(_ time: CMTime) {
        if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0,
           abs(itemDuration - duration) > 0.5 {
            duration = itemDuration
            updateNowPlaying()
        }
        let seconds = time.seconds
        if seconds.isFinite, activeSeek == nil { currentTime = seconds }
        if isPlaying, Date.now.timeIntervalSince(lastProgressSave) > 10 {
            saveProgress()
        }
    }

    private func itemDidFinish(_ item: AVPlayerItem?) {
        guard let item, item === player.currentItem, let track = current else { return }
        if track.isPodcast {
            podcastStore?.setPlayed(true, for: track.id)
            lastProgressSave = .now
            if hasNext { next() } else { pause() }
        } else {
            next()
        }
    }

    private func saveProgress() {
        guard let track = current else { return }
        lastProgressSave = .now
        saveSession()
        guard track.isPodcast, let store = podcastStore, currentTime > 0 else { return }
        if duration > 0, currentTime > duration - 15 {
            store.setPlayed(true, for: track.id)
        } else {
            store.setPosition(currentTime, for: track.id)
        }
    }

    private func saveSession() {
        guard let current else { return }
        let session = PlaybackSession(queue: queue.map(\.id), currentID: current.id, position: currentTime)
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: sessionFile, options: .atomic)
        }
    }

    private func handleInterruption(_ info: [AnyHashable: Any]?) {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended,
              let optionsRaw = info?[AVAudioSessionInterruptionOptionKey] as? UInt,
              AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
        else { return }
        resume()
    }

    // MARK: - Lock screen & Control Center

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.addTarget { event in
                Task { @MainActor in action(event) }
                return .success
            }
        }
        handle(center.playCommand) { [weak self] _ in self?.resume() }
        handle(center.pauseCommand) { [weak self] _ in self?.pause() }
        handle(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlayPause() }
        handle(center.nextTrackCommand) { [weak self] _ in self?.next() }
        handle(center.previousTrackCommand) { [weak self] _ in self?.previous() }
        handle(center.skipForwardCommand) { [weak self] _ in self?.skip(by: Self.skipForward) }
        handle(center.skipBackwardCommand) { [weak self] _ in self?.skip(by: -Self.skipBack) }
        handle(center.changePlaybackPositionCommand) { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: event.positionTime) }
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForward)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBack)]
        updateCommandAvailability()
    }

    private func updateCommandAvailability() {
        let center = MPRemoteCommandCenter.shared()
        let podcast = current?.isPodcast == true
        center.nextTrackCommand.isEnabled = !podcast
        center.previousTrackCommand.isEnabled = !podcast
        center.skipForwardCommand.isEnabled = podcast
        center.skipBackwardCommand.isEnabled = podcast
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artist = track.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork { info[MPMediaItemPropertyArtwork] = Self.mediaArtwork(artwork) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // The artwork closure is called off the main thread, so it must not inherit main-actor isolation.
    private nonisolated static func mediaArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
