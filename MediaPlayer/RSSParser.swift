import Foundation

struct ParsedFeed {
    var title = ""
    var author: String?
    var summary: String?
    var imageURL: URL?
    var episodes: [Episode] = []
}

enum RSSError: LocalizedError {
    case invalidFeed
    case noEpisodes

    var errorDescription: String? {
        switch self {
        case .invalidFeed: "This doesn't look like a valid podcast RSS feed."
        case .noEpisodes: "The feed doesn't contain any audio episodes."
        }
    }
}

/// Minimal RSS 2.0 + iTunes podcast namespace parser.
final class RSSParser: NSObject, XMLParserDelegate {
    private var feed = ParsedFeed()
    private var text = ""
    private var path: [String] = []

    private var inItem = false
    private var itemTitle = ""
    private var itemGUID: String?
    private var itemDate: Date?
    private var itemDuration: TimeInterval?
    private var itemAudio: URL?
    private var itemImage: URL?

    static func parse(_ data: Data) throws -> ParsedFeed {
        let delegate = RSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.feed.title.isEmpty || !delegate.feed.episodes.isEmpty else {
            throw RSSError.invalidFeed
        }
        guard !delegate.feed.episodes.isEmpty else { throw RSSError.noEpisodes }
        return delegate.feed
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(name)
        text = ""
        switch name {
        case "item":
            inItem = true
            itemTitle = ""; itemGUID = nil; itemDate = nil; itemDuration = nil
            itemAudio = nil; itemImage = nil
        case "enclosure" where inItem:
            let type = attributes["type"] ?? "audio"
            if let href = attributes["url"], type.hasPrefix("audio") || type.isEmpty || href.lowercased().contains(".mp3") {
                itemAudio = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case "itunes:image":
            if let href = attributes["href"], let url = URL(string: href) {
                // The channel-level itunes:image wins over the plain RSS <image><url>.
                if inItem { itemImage = url } else { feed.imageURL = url }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = path.dropLast().last
        defer { path.removeLast(); text = "" }

        if inItem {
            switch name {
            case "title" where parent == "item": itemTitle = value
            case "guid": itemGUID = value.isEmpty ? nil : value
            case "pubDate": itemDate = Self.parseDate(value)
            case "itunes:duration": itemDuration = Self.parseDuration(value)
            case "item":
                inItem = false
                if let audio = itemAudio {
                    feed.episodes.append(Episode(
                        id: itemGUID ?? audio.absoluteString,
                        title: itemTitle.isEmpty ? "Untitled Episode" : itemTitle,
                        pubDate: itemDate,
                        duration: itemDuration,
                        audioURL: audio,
                        imageURL: itemImage
                    ))
                }
            default: break
            }
            return
        }

        switch name {
        case "title" where parent == "channel": feed.title = value
        case "itunes:author" where parent == "channel": feed.author = value
        case "description" where parent == "channel", "itunes:summary" where parent == "channel":
            if feed.summary == nil { feed.summary = value.strippingHTML }
        case "url" where parent == "image":
            if feed.imageURL == nil { feed.imageURL = URL(string: value) }
        default: break
        }
    }

    private static let dateFormatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm Z",
        "dd MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssZ",
    ].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }

    static func parseDate(_ string: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    static func parseDuration(_ string: String) -> TimeInterval? {
        let parts = string.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

extension String {
    var strippingHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
