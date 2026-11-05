import AVFoundation
import Foundation

/// MP3 files from a folder in Files. Defaults to the app's own folder
/// (Files › On My iPhone › Media Player › Music/Podcasts), but any folder can be picked.
@MainActor
final class LocalLibrary: ObservableObject {
    enum Kind: String {
        case music = "Music"
        case podcasts = "Podcasts"
    }

    let kind: Kind
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var pendingDownloads = 0
    @Published private(set) var folderURL: URL
    @Published private(set) var usesCustomFolder = false
    @Published var errorMessage: String?

    /// Set for the podcasts library so downloaded episode files keep their episode identity.
    weak var downloads: DownloadManager?

    private var scopedURL: URL?
    private var reloadAgain = false
    /// Tags read on earlier scans, keyed by file path, so rescans only open new or changed files.
    private var metadataCache: [String: (modified: Date?, track: Track)] = [:]
    private var bookmarkKey: String { "folderBookmark.\(kind.rawValue)" }

    static func appFolder(for kind: Kind) -> URL {
        URL.documentsDirectory.appending(path: kind.rawValue, directoryHint: .isDirectory)
    }

    init(kind: Kind) {
        self.kind = kind
        let appFolder = Self.appFolder(for: kind)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        folderURL = appFolder

        if let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale),
               url.startAccessingSecurityScopedResource() {
                scopedURL = url
                folderURL = url
                usesCustomFolder = true
                if isStale, let fresh = try? url.bookmarkData() {
                    UserDefaults.standard.set(fresh, forKey: bookmarkKey)
                }
            }
        }
    }

    var folderDescription: String {
        usesCustomFolder ? folderURL.lastPathComponent : "On My iPhone › Media Player › \(kind.rawValue)"
    }

    func chooseFolder(_ url: URL) async {
        let appFolder = Self.appFolder(for: kind)
        if url.standardizedFileURL.resolvingSymlinksInPath().path == appFolder.standardizedFileURL.resolvingSymlinksInPath().path {
            await useAppFolder()
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Couldn't get access to “\(url.lastPathComponent)”."
            return
        }
        do {
            UserDefaults.standard.set(try url.bookmarkData(), forKey: bookmarkKey)
        } catch {
            errorMessage = "Couldn't remember this folder: \(error.localizedDescription)"
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url
        folderURL = url
        usesCustomFolder = true
        metadataCache = [:]
        await reload()
    }

    private func useAppFolder() async {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        folderURL = Self.appFolder(for: kind)
        usesCustomFolder = false
        metadataCache = [:]
        await reload()
    }

    func reload() async {
        guard !isLoading else {
            // A rescan was requested mid-scan (e.g. a download just finished): run once more afterwards.
            reloadAgain = true
            return
        }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        repeat {
            reloadAgain = false
            await scanFolder()
        } while reloadAgain
    }

    /// Deletes a file from the folder (swipe to delete).
    func delete(_ track: Track) {
        guard track.isLocal else { return }
        try? FileManager.default.removeItem(at: track.url)
        metadataCache[track.url.path] = nil
        removeTrack(id: track.id)
    }

    func removeTrack(id: String) {
        tracks.removeAll { $0.id == id }
    }

    private func scanFolder() async {
        let folder = folderURL
        let kind = kind
        let extensions: Set<String> = kind == .podcasts ? ["mp3", "m4a"] : ["mp3"]
        let scan = await Task.detached(priority: .userInitiated) { Self.scan(folder, extensions: extensions) }.value

        // Only read tags for files that are new or changed since the last scan.
        let changed = scan.files.filter { metadataCache[$0.url.path]?.modified != $0.modified }
        let fresh = await Self.loadTracks(changed.map(\.url), root: folder, kind: kind)
        let freshByPath = Dictionary(fresh.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        var cache: [String: (modified: Date?, track: Track)] = [:]
        for file in scan.files {
            if let track = freshByPath[file.url.path] ?? metadataCache[file.url.path]?.track {
                cache[file.url.path] = (file.modified, track)
            }
        }
        metadataCache = cache
        var loaded = cache.values.map(\.track)

        if let downloads {
            let prefix = "\(kind.rawValue):"
            loaded = downloads.resolve(loaded.map { (String($0.id.dropFirst(prefix.count)), $0) })
        }

        tracks = loaded.sorted {
            if kind == .podcasts {
                if let a = $0.date, let b = $1.date, a != b { return a > b }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            // Music follows the file names (and so the folder structure), e.g. "01 Intro.mp3", "02 …".
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
        playlists = Self.playlists(from: tracks, folders: scan.folders)
        pendingDownloads = scan.pending

        // Warm the artwork for what's on screen first: the top of the podcast list, and each playlist's
        // mosaic plus its first screenful of songs.
        ArtworkLoader.shared.prefetch(kind == .podcasts
            ? Array(tracks.prefix(15))
            : playlists.flatMap { $0.tracks.prefix(12) })
    }

    private static func playlists(from tracks: [Track], folders: [String]) -> [Playlist] {
        let grouped = Dictionary(grouping: tracks) { $0.folder }
        var result = folders
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Playlist(id: $0, name: $0, tracks: grouped[$0] ?? []) }
        if let loose = grouped[nil], !loose.isEmpty {
            result.append(Playlist(id: Playlist.looseSongsID, name: "Other Songs", tracks: loose))
        }
        return result
    }

    // MARK: - Scanning

    private nonisolated static func scan(_ folder: URL, extensions: Set<String>)
        -> (files: [(url: URL, modified: Date?)], folders: [String], pending: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return ([], folders, 0)
        }
        var files: [(url: URL, modified: Date?)] = []
        var pending = 0
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                // Not yet downloaded from iCloud Drive: request it so it shows up on the next refresh.
                let realName = String(name.dropFirst().dropLast(".icloud".count))
                guard extensions.contains((realName as NSString).pathExtension.lowercased()) else { continue }
                try? FileManager.default.startDownloadingUbiquitousItem(
                    at: url.deletingLastPathComponent().appending(path: realName))
                pending += 1
            } else if !name.hasPrefix("."), extensions.contains(url.pathExtension.lowercased()) {
                files.append((url, try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate))
            }
        }
        return (files, folders, pending)
    }

    private nonisolated static func loadTracks(_ files: [URL], root: URL, kind: Kind) async -> [Track] {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var result: [Track] = []
        // Read tags a batch at a time so huge folders don't spawn hundreds of concurrent readers.
        for batch in stride(from: 0, to: files.count, by: 12).map({ Array(files[$0..<min($0 + 12, files.count)]) }) {
            await withTaskGroup(of: Track.self) { group in
                for url in batch {
                    group.addTask {
                        let fullPath = url.standardizedFileURL.resolvingSymlinksInPath().path
                        let relative = fullPath.hasPrefix(rootPath) ? String(fullPath.dropFirst(rootPath.count)) : url.lastPathComponent
                        var track = await makeTrack(url: url, id: "\(kind.rawValue):\(relative)", isPodcast: kind == .podcasts)
                        let components = relative.split(separator: "/")
                        if components.count > 1 { track.folder = String(components[0]) }
                        return track
                    }
                }
                for await track in group { result.append(track) }
            }
        }
        return result
    }

    private nonisolated static func makeTrack(url: URL, id: String, isPodcast: Bool) async -> Track {
        let asset = AVURLAsset(url: url)
        var title: String?
        var artist: String?
        var album: String?

        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                switch item.commonKey {
                case .commonKeyTitle?: title = try? await item.load(.stringValue)
                case .commonKeyArtist?: artist = try? await item.load(.stringValue)
                case .commonKeyAlbumName?: album = try? await item.load(.stringValue)
                default: break
                }
            }
        }
        let duration = try? await asset.load(.duration).seconds
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey])
        let added = values?.addedToDirectoryDate ?? values?.creationDate ?? values?.contentModificationDate

        return Track(
            id: id,
            url: url,
            title: title.nonEmpty ?? url.deletingPathExtension().lastPathComponent,
            artist: artist.nonEmpty,
            album: album.nonEmpty,
            duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            artworkURL: nil,
            date: added,
            isPodcast: isPodcast
        )
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
