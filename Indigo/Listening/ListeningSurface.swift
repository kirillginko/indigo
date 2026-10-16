//
//  ListeningSurface.swift
//  Indigo
//
//  Where a listen started: the screen, and the recommendation on it.
//
//  Without it the history can say what was heard but not what found it --
//  whether a discovery came from For You, DIG's Discover, an artist page, a
//  station or the crate -- so no replay can credit a surface with anything.
//
//  Kept in the event's `tags`, under reserved prefixes, rather than in a new
//  column: a column is a schema version and a CloudKit change, and tags
//  already sync. Readers of taste take `ListeningEvent.musicTags`, which
//  leaves these out. (A build from before this reads them as unknown tags;
//  they match no style, so they place nothing.)
//

import Foundation

nonisolated struct ListeningSurface: Hashable, Sendable {
    /// Dotted, lower case: "foryou.mix", "dig.discover", "dig.artist.listen",
    /// "crate", "radio.live" …
    var screen: String
    /// What of the listener's it was reached through, as a folded artist key
    /// ("played next to X" → x).
    var via: String?
    /// What kind of recommendation it was: "track", "artist", "record", or a
    /// station's id for radio.
    var route: String?

    init(screen: String, via: String? = nil, route: String? = nil) {
        self.screen = screen
        self.via = via
        self.route = route
    }

    static let screenPrefix = "surface:"
    static let viaPrefix = "via:"
    static let routePrefix = "route:"

    /// As tags, spelled so `ListeningLog.foldTags` keeps each whole: lower
    /// case, no slash or comma (which it splits on).
    var tags: [String] {
        func clean(_ text: String) -> String {
            text.lowercased().map { $0 == "/" || $0 == "," ? " " : $0 }
                .reduce(into: "") { $0.append($1) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = [Self.screenPrefix + clean(screen)]
        if let via, !clean(via).isEmpty { out.append(Self.viaPrefix + clean(RecordingKey.normalizeArtist(via))) }
        if let route, !clean(route).isEmpty { out.append(Self.routePrefix + clean(route)) }
        return out
    }

    /// Read back from an event's tags; nil when it carries none (every event
    /// from before this existed).
    init?(tags: [String]) {
        guard let screen = tags.first(where: { $0.hasPrefix(Self.screenPrefix) }) else { return nil }
        self.screen = String(screen.dropFirst(Self.screenPrefix.count))
        via = tags.first { $0.hasPrefix(Self.viaPrefix) }.map { String($0.dropFirst(Self.viaPrefix.count)) }
        route = tags.first { $0.hasPrefix(Self.routePrefix) }.map { String($0.dropFirst(Self.routePrefix.count)) }
    }

    static func isSurfaceTag(_ tag: String) -> Bool {
        tag.hasPrefix(screenPrefix) || tag.hasPrefix(viaPrefix) || tag.hasPrefix(routePrefix)
    }

    /// The tags that describe the music.
    static func musicTags(_ tags: [String]) -> [String] { tags.filter { !isSurfaceTag($0) } }

    /// When the screen that started it said nothing: what the item itself
    /// says. A station or an archive is radio wherever it was pressed.
    static func inferred(for item: MediaItem) -> ListeningSurface {
        switch item.kind {
        case .radioStation, .radioShow: ListeningSurface(screen: "radio.live", route: item.sourceID)
        case .episode: ListeningSurface(screen: "radio.archive", route: item.sourceID)
        case .track: ListeningSurface(screen: item.sourceID == Track.sourceID ? "library" : "unattributed", route: item.sourceID)
        }
    }
}

nonisolated extension ListeningEvent {
    /// Where the listen started, when it was recorded.
    var surface: ListeningSurface? { ListeningSurface(tags: tags) }
    /// `tags` without the surface: what taste reads.
    var musicTags: [String] { ListeningSurface.musicTags(tags) }
}
