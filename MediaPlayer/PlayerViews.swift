import SwiftUI

struct ArtworkView: View {
    private enum Source: Equatable {
        case track(Track)
        case remote(URL)
        case none(isPodcast: Bool)
    }

    private let source: Source
    private let size: ArtworkLoader.Size
    private let cornerRadius: CGFloat
    @State private var image: UIImage?

    init(track: Track?, size: ArtworkLoader.Size = .thumb, cornerRadius: CGFloat = 6) {
        source = track.map { .track($0) } ?? .none(isPodcast: false)
        self.size = size
        self.cornerRadius = cornerRadius
        _image = State(initialValue: cachedImage)
    }

    init(remoteURL: URL?, size: ArtworkLoader.Size = .thumb, cornerRadius: CGFloat = 6) {
        source = remoteURL.map { .remote($0) } ?? .none(isPodcast: true)
        self.size = size
        self.cornerRadius = cornerRadius
        _image = State(initialValue: cachedImage)
    }

    private var cachedImage: UIImage? {
        switch source {
        case .track(let track): ArtworkLoader.shared.cachedImage(for: track, size: size)
        case .remote(let url): ArtworkLoader.shared.cachedImage(remote: url, size: size)
        case .none: nil
        }
    }

    private var placeholderSymbol: String {
        switch source {
        case .track(let track): track.isPodcast ? "mic.fill" : "music.note"
        case .remote, .none(isPodcast: true): "mic.fill"
        case .none: "music.note"
        }
    }

    private var sourceKey: String {
        switch source {
        case .track(let track): track.id
        case .remote(let url): url.absoluteString
        case .none: ""
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(.tertiarySystemFill))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    GeometryReader { geo in
                        Image(systemName: placeholderSymbol)
                            .font(.system(size: geo.size.width * 0.4))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: sourceKey) {
                if let cached = cachedImage {
                    image = cached
                    return
                }
                let loaded: UIImage? = switch source {
                case .track(let track): await ArtworkLoader.shared.image(for: track, size: size)
                case .remote(let url): await ArtworkLoader.shared.image(remote: url, size: size)
                case .none: nil
                }
                // Only swap once the new image is known, so the old one doesn't blink to the placeholder.
                image = loaded
            }
    }
}

struct MiniPlayer: View {
    @EnvironmentObject private var player: AudioPlayer
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: player.current, cornerRadius: 6)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.current?.title ?? "Not Playing")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let artist = player.current?.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .contentTransition(.symbolEffect(.replace))
            }
            if player.current?.isPodcast == true {
                Button {
                    player.skip(by: AudioPlayer.skipForward)
                } label: {
                    Image(systemName: "goforward.30").font(.title3).frame(width: 36, height: 36)
                }
            } else {
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill").font(.title3).frame(width: 36, height: 36)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

private final class ScrubState: ObservableObject {
    @Published var isActive = false
    @Published var time: TimeInterval = 0
}

struct NowPlayingView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scrub = ScrubState()

    var body: some View {
        let track = player.current
        let isPodcast = track?.isPodcast == true
        let shownTime = scrub.isActive ? scrub.time : player.currentTime

        VStack(spacing: 0) {
            Spacer(minLength: 24)

            ArtworkView(track: track, size: .large, cornerRadius: 14)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                .scaleEffect(player.isPlaying ? 1 : 0.88)
                .animation(.spring(duration: 0.4), value: player.isPlaying)
                .padding(.horizontal, 8)

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(track?.title ?? "Not Playing")
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                Text(track?.artist ?? (isPodcast ? "Podcast" : "Unknown Artist"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                Slider(
                    value: Binding(get: { shownTime }, set: { scrub.time = $0 }),
                    in: 0...max(player.duration, 1)
                ) { editing in
                    if editing {
                        scrub.time = player.currentTime
                        scrub.isActive = true
                    } else if scrub.isActive {
                        player.seek(to: scrub.time)
                        scrub.isActive = false
                    }
                }
                HStack {
                    Text(Format.time(shownTime))
                    Spacer()
                    Text("-" + Format.time(max(player.duration - shownTime, 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.top, 20)

            HStack {
                Spacer()
                if isPodcast {
                    controlButton("gobackward.15", size: 32) { player.skip(by: -AudioPlayer.skipBack) }
                } else {
                    controlButton("backward.fill", size: 32) { player.previous() }
                }
                Spacer()
                controlButton(player.isPlaying ? "pause.fill" : "play.fill", size: 52) { player.togglePlayPause() }
                    .contentTransition(.symbolEffect(.replace))
                Spacer()
                if isPodcast {
                    controlButton("goforward.30", size: 32) { player.skip(by: AudioPlayer.skipForward) }
                } else {
                    controlButton("forward.fill", size: 32) { player.next() }
                }
                Spacer()
            }
            .padding(.vertical, 28)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .tint(.primary)
        .presentationDragIndicator(.visible)
        .onChange(of: track?.id) { scrub.isActive = false }
        .onChange(of: player.current == nil) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: size + 24, height: size + 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track)
                .frame(width: 48, height: 48)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                        Image(systemName: "waveform")
                            .foregroundStyle(.white)
                            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                Text([track.artist, track.album].compactMap { $0 }.joined(separator: " · ").ifEmpty("Unknown Artist"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let duration = track.duration {
                Text(Format.time(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

extension EdgeInsets {
    /// Section header insets that line the title up with the left edge of the cards below it.
    static let cardAligned = EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0)
}
