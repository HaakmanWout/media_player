import AVFoundation
import UIKit

/// Loads and caches cover art: embedded ID3 artwork for local MP3s, or images from RSS feeds.
@MainActor
final class ArtworkLoader {
    static let shared = ArtworkLoader()

    enum Size: CGFloat {
        case thumb = 180
        case large = 1000
    }

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 60_000_000 // bytes of decoded images
        return cache
    }()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Loads artwork into the cache ahead of time so rows show it on their first appearance.
    func prefetch(_ tracks: [Track], size: Size = .thumb) {
        let missing = tracks.filter { cachedImage(for: $0, size: size) == nil }
        guard !missing.isEmpty else { return }
        Task(priority: .utility) {
            for track in missing { _ = await image(for: track, size: size) }
        }
    }

    func prefetch(remote urls: [URL], size: Size = .thumb) {
        let missing = urls.filter { cachedImage(remote: $0, size: size) == nil }
        guard !missing.isEmpty else { return }
        Task(priority: .utility) {
            for url in missing { _ = await image(remote: url, size: size) }
        }
    }

    /// Synchronous cache lookup, so views that get recreated can show artwork without a placeholder flash.
    func cachedImage(for track: Track, size: Size) -> UIImage? {
        guard let key = Self.key(for: track) else { return nil }
        return cache.object(forKey: Self.cacheKey(key, size) as NSString)
    }

    func cachedImage(remote url: URL, size: Size) -> UIImage? {
        cache.object(forKey: Self.cacheKey(url.absoluteString, size) as NSString)
    }

    func image(for track: Track, size: Size) async -> UIImage? {
        if track.isLocal {
            // Downloaded episodes fall back to the feed's artwork when the file has none embedded.
            let url = track.url, remote = track.artworkURL
            return await image(key: url.absoluteString, size: size) {
                if let embedded = await Self.embeddedArtwork(url) { return embedded }
                guard let remote else { return nil }
                return try? await URLSession.shared.data(from: remote).0
            }
        }
        guard let remote = track.artworkURL else { return nil }
        return await image(remote: remote, size: size)
    }

    func image(remote url: URL, size: Size) async -> UIImage? {
        await image(key: url.absoluteString, size: size) {
            try? await URLSession.shared.data(from: url).0
        }
    }

    private static func key(for track: Track) -> String? {
        track.isLocal ? track.url.absoluteString : track.artworkURL?.absoluteString
    }

    private static func cacheKey(_ key: String, _ size: Size) -> String {
        "\(Int(size.rawValue))|\(key)"
    }

    private func image(key: String, size: Size, fetch: @escaping @Sendable () async -> Data?) async -> UIImage? {
        let cacheKey = Self.cacheKey(key, size)
        if let cached = cache.object(forKey: cacheKey as NSString) { return cached }
        if let running = inFlight[cacheKey] { return await running.value }

        let task = Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = await fetch(), let image = UIImage(data: data) else { return nil }
            let maxSide = max(image.size.width, image.size.height)
            // Decode here, off the main thread, so the first draw doesn't stall scrolling or transitions.
            guard maxSide > size.rawValue else { return await image.byPreparingForDisplay() ?? image }
            let scale = size.rawValue / maxSide
            let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            return await image.byPreparingThumbnail(ofSize: target) ?? image
        }
        inFlight[cacheKey] = task
        let image = await task.value
        inFlight[cacheKey] = nil
        if let image {
            let bytes = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            cache.setObject(image, forKey: cacheKey as NSString, cost: bytes)
        }
        return image
    }

    private nonisolated static func embeddedArtwork(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }
}
