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
    @Published var podcastRate: Float = UserDefaults.standard.object(forKey: "podcastRate") as? Float ?? 1.0 {
        didSet {
            UserDefaults.standard.set(podcastRate, forKey: "podcastRate")
            applyRate()
        }
    }

    static let skipBack: TimeInterval = 15
    static let skipForward: TimeInterval = 30

    var podcastStore: PodcastStore?
    var downloads: DownloadManager?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var artwork: UIImage?
    private var lastProgressSave = Date.distantPast

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
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, self.isPlaying != playing else { return }
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
        guard current != nil else { return }
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
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        updateNowPlaying()
        saveProgress()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    private func load(_ track: Track) {
        saveProgress()
        current = track
        artwork = nil
        duration = track.duration ?? 0
        currentTime = 0

        let item = AVPlayerItem(url: downloads?.localURL(for: track.id) ?? track.url)
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)

        if track.isPodcast, let store = podcastStore {
            let saved = store.progress(for: track.id)
            let nearEnd = duration > 0 && saved.position > duration - 15
            if saved.position > 5, !nearEnd {
                currentTime = saved.position
                player.seek(to: CMTime(seconds: saved.position, preferredTimescale: 600))
            }
        }

        applyRate()
        updateCommandAvailability()
        resume()
        updateNowPlaying()

        Task {
            let image = await ArtworkLoader.shared.image(for: track, size: .large)
            guard current?.id == track.id else { return }
            artwork = image
            updateNowPlaying()
        }
    }

    private func applyRate() {
        let rate = current?.isPodcast == true ? podcastRate : 1
        player.defaultRate = rate
        if isPlaying { player.rate = rate }
        updateNowPlaying()
    }

    private func tick(_ time: CMTime) {
        if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0,
           abs(itemDuration - duration) > 0.5 {
            duration = itemDuration
            updateNowPlaying()
        }
        let seconds = time.seconds
        if seconds.isFinite { currentTime = seconds }
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
        guard let track = current, track.isPodcast, let store = podcastStore, currentTime > 0 else { return }
        lastProgressSave = .now
        if duration > 0, currentTime > duration - 15 {
            store.setPlayed(true, for: track.id)
        } else {
            store.setPosition(currentTime, for: track.id)
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(player.defaultRate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(player.defaultRate),
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
