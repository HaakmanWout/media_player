import Foundation

/// Downloads RSS episodes into the podcasts folder, next to the user's own MP3s. A small index remembers
/// which file belongs to which episode, so downloaded files keep the episode's identity (progress,
/// played state, artwork) when the folder is scanned. Transfers run in a background session, so they carry
/// on when the app is suspended or iOS terminates it.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    struct Record: Codable, Identifiable, Hashable {
        let id: String
        let feedID: UUID
        let remoteURL: URL
        var fileName: String
        var title: String
        var podcast: String
        var artworkURL: URL?
        var duration: TimeInterval?
    }

    enum State: Equatable {
        case none
        case downloading(progress: Double?)
        case downloaded
    }

    @Published private(set) var records: [String: Record] = [:]
    @Published private(set) var progress: [String: Double?] = [:]
    @Published var errorMessage: String?

    /// The podcasts library whose folder downloads are saved into.
    weak var library: LocalLibrary?

    private let indexFile: URL
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var pending: [Int: Record] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.wouthaakman.MediaPlayer.downloads")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    /// Handed over by iOS when it wakes the app for finished downloads; called once they're all processed.
    static var backgroundCompletion: (() -> Void)?

    override init() {
        let support = URL.applicationSupportDirectory
        indexFile = support.appending(path: "downloads.json")
        super.init()
        // Earlier versions kept downloads privately in Application Support.
        try? FileManager.default.removeItem(at: support.appending(path: "Downloads", directoryHint: .isDirectory))

        if let data = try? Data(contentsOf: indexFile),
           let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = saved
        }
        reconnectTasks()
    }

    /// Picks up transfers that kept running while the app wasn't.
    private func reconnectTasks() {
        Task {
            for case let task as URLSessionDownloadTask in await session.allTasks where task.state == .running {
                guard let record = pendingRecord(for: task) else { continue }
                let total = task.countOfBytesExpectedToReceive
                progress[record.id] = .some(total > 0 ? Double(task.countOfBytesReceived) / Double(total) : nil)
            }
        }
    }

    /// The record for a task. It's stored on the task too, because a task can outlive the app's memory.
    private func pendingRecord(for task: URLSessionTask) -> Record? {
        if let record = pending[task.taskIdentifier] { return record }
        guard let data = task.taskDescription?.data(using: .utf8),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }
        pending[task.taskIdentifier] = record
        tasks[record.id] = task as? URLSessionDownloadTask
        return record
    }

    func state(for trackID: String) -> State {
        if records[trackID] != nil { return .downloaded }
        if let value = progress[trackID] { return .downloading(progress: value) }
        return .none
    }

    func localURL(for trackID: String) -> URL? {
        guard let record = records[trackID], let folder = library?.folderURL else { return nil }
        let url = folder.appending(path: record.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ episode: Episode, in feed: PodcastFeed) {
        let track = feed.track(for: episode)
        guard state(for: track.id) == .none else { return }

        let record = Record(
            id: track.id,
            feedID: feed.id,
            remoteURL: episode.audioURL,
            fileName: "",
            title: track.title,
            podcast: feed.title,
            artworkURL: track.artworkURL,
            duration: track.duration
        )
        let task = session.downloadTask(with: episode.audioURL)
        task.taskDescription = (try? JSONEncoder().encode(record)).map { String(decoding: $0, as: UTF8.self) }
        tasks[track.id] = task
        pending[task.taskIdentifier] = record
        progress[track.id] = .some(nil)
        task.resume()
    }

    func cancel(_ trackID: String) {
        tasks[trackID]?.cancel()
    }

    /// Deletes the downloaded file and forgets the episode link.
    func delete(_ trackID: String) {
        if let url = localURL(for: trackID) {
            try? FileManager.default.removeItem(at: url)
        }
        forget(trackID)
        library?.removeTrack(id: trackID)
    }

    /// Forgets the episode link without touching the file (e.g. the file was deleted elsewhere).
    func forget(_ trackID: String) {
        guard records.removeValue(forKey: trackID) != nil else { return }
        save()
    }

    /// Called by the library after scanning: gives downloaded files their episode identity and drops
    /// records whose file no longer exists.
    func resolve(_ items: [(relativePath: String, track: Track)]) -> [Track] {
        let byFile = Dictionary(records.values.map { ($0.fileName, $0) }, uniquingKeysWith: { first, _ in first })
        var found = Set<String>()
        let tracks = items.map { relativePath, track -> Track in
            guard let record = byFile[relativePath] else { return track }
            found.insert(record.id)
            var resolved = Track(
                id: record.id,
                url: track.url,
                title: record.title,
                artist: record.podcast,
                album: record.podcast,
                duration: track.duration ?? record.duration,
                artworkURL: record.artworkURL,
                date: track.date,
                isPodcast: true
            )
            resolved.folder = track.folder
            return resolved
        }
        let missing = records.keys.filter { !found.contains($0) }
        if !missing.isEmpty {
            missing.forEach { records[$0] = nil }
            save()
        }
        return tracks
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: indexFile, options: .atomic)
        }
    }

    private static func fileExtension(for task: URLSessionDownloadTask, record: Record) -> String {
        let candidates = [
            (task.response?.suggestedFilename as NSString?)?.pathExtension,
            record.remoteURL.pathExtension,
        ]
        return candidates.compactMap { $0?.lowercased() }.first { ["mp3", "m4a"].contains($0) } ?? "mp3"
    }

    private static func uniqueURL(in folder: URL, podcast: String, title: String, ext: String) -> URL {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        var base = "\(podcast) - \(title)"
            .components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        base = String(base.prefix(150))
        if base.isEmpty { base = "Episode" }

        var url = folder.appending(path: "\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return url
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            guard let record = pendingRecord(for: downloadTask) else { return }
            let fraction = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
            progress[record.id] = .some(fraction)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard var record = pendingRecord(for: downloadTask) else { return }
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                errorMessage = "“\(record.title)” couldn't be downloaded (HTTP \(http.statusCode))."
                return
            }
            guard let library else { return }
            // The temporary file is deleted when this method returns, so move it now.
            let destination = Self.uniqueURL(
                in: library.folderURL, podcast: record.podcast, title: record.title,
                ext: Self.fileExtension(for: downloadTask, record: record))
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                record.fileName = destination.lastPathComponent
                records[record.id] = record
                save()
                Task { await library.reload() }
            } catch {
                errorMessage = "“\(record.title)” couldn't be saved: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let record = pendingRecord(for: task) else { return }
            pending[task.taskIdentifier] = nil
            if let error, (error as? URLError)?.code != .cancelled {
                errorMessage = "“\(record.title)” couldn't be downloaded: \(error.localizedDescription)"
            }
            tasks[record.id] = nil
            progress[record.id] = nil
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            Self.backgroundCompletion?()
            Self.backgroundCompletion = nil
        }
    }
}
