//
//  PodcastFeed.swift
//  Indigo
//
//  RSS with the iTunes podcast extensions — the format a station reaches for
//  when it wants its archive to work in every podcatcher rather than only in
//  its own player.
//
//  Radio Panik publishes one for the station and one per show, and both carry
//  a direct address for the recording. That matters: an episode read from here
//  plays through the same engine a local file does — seekable, with a real
//  duration — instead of going through somebody's widget.
//
//  Kept next to `AirtimeLiveInfo` and `MixcloudArchive` rather than inside a
//  provider, because nothing about it is Panik's.
//

import Foundation

nonisolated struct PodcastFeed: Sendable {
    var title: String?
    var summary: String?
    var imageURL: URL?
    var items: [PodcastFeedItem]
}

nonisolated struct PodcastFeedItem: Sendable {
    var title: String?
    /// The episode's page on the station's own site.
    var link: String?
    var guid: String?
    /// Rendered HTML. Stations put the episode's picture in here as well as
    /// its note, so it is kept whole and stripped where it is shown.
    var summaryHTML: String?
    var publishedAt: Date?
    /// The recording itself.
    var enclosureURL: URL?
    var enclosureBytes: Int?
    var imageURL: URL?
    var duration: TimeInterval?
}

nonisolated enum PodcastFeedParser {
    /// Returns nil only when the document is not parseable XML at all — a feed
    /// with odd or missing fields still comes back, with holes.
    static func parse(_ data: Data) -> PodcastFeed? {
        let delegate = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return PodcastFeed(
            title: delegate.channelTitle?.cleaned,
            summary: delegate.channelSummary?.cleaned,
            imageURL: delegate.channelImage.flatMap { URL(string: $0) },
            items: delegate.items
        )
    }

    /// "01:05:58", "5:58" or a plain count of seconds — iTunes permits all
    /// three and stations use all three.
    static func duration(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if !value.contains(":") {
            guard let seconds = Double(value), seconds > 0 else { return nil }
            return seconds
        }
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        let total = parts.reduce(0) { $0 * 60 + $1 }
        return total > 0 ? total : nil
    }

    /// RFC 822, which is what RSS dates are. Some feeds write the zone as a
    /// name rather than an offset, so both are tried.
    static func date(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm Z"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

/// XMLParser is event-driven, so the shape is rebuilt as the document goes
/// past. The delegate never escapes `parse(_:)`.
private final class Collector: NSObject, XMLParserDelegate {
    var channelTitle: String?
    var channelSummary: String?
    var channelImage: String?
    var items: [PodcastFeedItem] = []

    private var insideItem = false
    private var current = PodcastFeedItem()
    private var text = ""
    /// Nested `<image><url>…</url></image>` means a bare `url` element has to
    /// know which parent it belongs to.
    private var elements: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        elements.append(elementName)
        text = ""

        switch elementName {
        case "item":
            insideItem = true
            current = PodcastFeedItem()
        case "enclosure":
            guard insideItem else { break }
            current.enclosureURL = attributes["url"].flatMap { URL(string: $0) }
            current.enclosureBytes = attributes["length"].flatMap { Int($0) }
        case "itunes:image":
            // An attribute on the itunes element, a child element on the
            // plain RSS one — hence the two paths.
            guard let href = attributes["href"] else { break }
            if insideItem { current.imageURL = URL(string: href) } else { channelImage = href }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        defer {
            if elements.last == elementName { elements.removeLast() }
            text = ""
        }
        let value = text.cleaned

        if insideItem {
            switch elementName {
            case "item":
                items.append(current)
                insideItem = false
            case "title": current.title = value
            case "link": current.link = value
            case "guid": current.guid = value
            case "description", "itunes:summary":
                // `description` is the fuller of the two when both are present.
                if elementName == "description" || current.summaryHTML == nil {
                    current.summaryHTML = text.isEmpty ? nil : text
                }
            case "pubDate": current.publishedAt = PodcastFeedParser.date(value)
            case "itunes:duration": current.duration = PodcastFeedParser.duration(value)
            case "url" where elements.dropLast().last == "image":
                if current.imageURL == nil, let value { current.imageURL = URL(string: value) }
            default: break
            }
            return
        }

        switch elementName {
        case "title" where channelTitle == nil: channelTitle = value
        case "description" where channelSummary == nil: channelSummary = value
        case "url" where elements.dropLast().last == "image":
            if channelImage == nil { channelImage = value }
        default: break
        }
    }
}

private extension String {
    /// Trimmed, or nil when there was nothing but whitespace in it.
    var cleaned: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
