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

/// Whether listens are written down with where they started. Off in the App
/// Store build: a build from before attribution reads every tag as an
/// interest, and the attribution tags -- on every attributed row -- become
/// its strongest interest, scaling every real one down to a few hundredths
/// (`ListeningAttributionAudit`). Reading them is always safe; writing them
/// waits until the builds that read them as music are gone.
nonisolated enum ListeningAttributionFeature {
    #if DEBUG
    static let switchKey = "INDIGO_LISTENING_ATTRIBUTION"
    #endif
    nonisolated(unsafe) static var override: Bool?

    static var isEnabled: Bool {
        if let override { return override }
        #if DEBUG
        return UserDefaults.standard.bool(forKey: switchKey)
        #elseif INDIGO_INTERNAL
        return true
        #else
        return false
        #endif
    }
}

nonisolated struct ListeningSurface: Hashable, Sendable {
    /// Dotted, lower case: "foryou.mix", "dig.discover", "dig.artist.listen",
    /// "crate", "radio.live" …
    var screen: String
    /// What of the listener's it was reached through, for reading: a folded
    /// artist key ("played next to X" → x).
    var via: String?
    /// The same, as a verified identity when one is known --
    /// "discogs-artist:45", "discogs-release:1234" -- and nil otherwise. Never
    /// worked out from the name.
    var viaID: String?
    /// What kind of recommendation it was: "track", "artist", "record", or a
    /// station's id for radio.
    var route: String?
    /// The recommendation that led here, when the listen started on a page
    /// opened from one (For You → an artist → their track): carried only by
    /// that page, and dropped by anything else the listener does.
    var origin: Origin?

    nonisolated struct Origin: Hashable, Sendable {
        var screen: String
        var via: String?
        var viaID: String?
        var route: String?
    }

    init(screen: String, via: String? = nil, viaID: String? = nil, route: String? = nil, origin: Origin? = nil) {
        self.screen = screen
        self.via = via
        self.viaID = viaID
        self.route = route
        self.origin = origin
    }

    /// As the origin of what is opened from it.
    var asOrigin: Origin { Origin(screen: screen, via: via, viaID: viaID, route: route) }

    static func discogsArtist(_ id: Int?) -> String? { id.flatMap { $0 > 0 ? "discogs-artist:\($0)" : nil } }
    static func discogsRelease(_ id: Int?) -> String? { id.flatMap { $0 > 0 ? "discogs-release:\($0)" : nil } }

    static let screenPrefix = "surface:"
    static let viaPrefix = "via:"
    static let viaIDPrefix = "viaid:"
    static let routePrefix = "route:"
    static let originPrefix = "origin:"
    static let originViaPrefix = "originvia:"
    static let originViaIDPrefix = "originviaid:"
    static let originRoutePrefix = "originroute:"
    static let prefixes = [screenPrefix, viaPrefix, viaIDPrefix, routePrefix, originPrefix, originViaPrefix, originViaIDPrefix, originRoutePrefix]

    private static func clean(_ text: String) -> String {
        text.lowercased().map { $0 == "/" || $0 == "," ? " " : $0 }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// As tags, spelled so `ListeningLog.foldTags` keeps each whole: lower
    /// case, no slash or comma (which it splits on).
    var tags: [String] {
        var out = [Self.screenPrefix + Self.clean(screen)]
        func add(_ prefix: String, _ value: String?, key: Bool = false) {
            guard let value, case let cleaned = Self.clean(key ? RecordingKey.normalizeArtist(value) : value), !cleaned.isEmpty else { return }
            out.append(prefix + cleaned)
        }
        add(Self.viaPrefix, via, key: true)
        add(Self.viaIDPrefix, viaID)
        add(Self.routePrefix, route)
        if let origin {
            add(Self.originPrefix, origin.screen)
            add(Self.originViaPrefix, origin.via, key: true)
            add(Self.originViaIDPrefix, origin.viaID)
            add(Self.originRoutePrefix, origin.route)
        }
        return out
    }

    /// Read back from an event's tags; nil when it carries none (every event
    /// from before this existed).
    init?(tags: [String]) {
        func value(_ prefix: String) -> String? { tags.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } }
        guard let screen = value(Self.screenPrefix) else { return nil }
        self.screen = screen
        via = value(Self.viaPrefix)
        viaID = value(Self.viaIDPrefix)
        route = value(Self.routePrefix)
        origin = value(Self.originPrefix).map {
            Origin(screen: $0, via: value(Self.originViaPrefix), viaID: value(Self.originViaIDPrefix), route: value(Self.originRoutePrefix))
        }
    }

    static func isSurfaceTag(_ tag: String) -> Bool { prefixes.contains { tag.hasPrefix($0) } }

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
