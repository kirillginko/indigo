//
//  ForYouMix.swift
//  Indigo
//
//  For You as one list: the artists and shows For You already ranks
//  (`ExploreRanker`), the tracks DIG Discover found and checked to play, and
//  the records that resemble the crate's (`SimilarRecords`), woven together
//  rather than shown as four blocks that repeat one another.
//
//  Each source keeps its ranked order within a rotating window. It
//  takes the next of each kind in a fixed pattern (a track, an artist, a
//  record, a track, an artist, a show, a record...), so the list opens on
//  something to hear and keeps a mix of things to hear, people to follow and
//  records to look at. One artist appears once whatever the kind: a track
//  that plays is the best way to meet somebody, then a record of theirs, then
//  their page. Pure: the same inputs, the same list.
//
//  Development and internal builds only (`ForYouMixFeature`).
//

import Foundation

nonisolated enum ForYouMixFeature {
    #if DEBUG
    static let switchKey = "INDIGO_FORYOU_MIX"
    #endif
    nonisolated(unsafe) static var override: Bool?

    static var isEnabled: Bool {
        if let override { return override }
        #if DEBUG
        return UserDefaults.standard.bool(forKey: switchKey)
        #elseif INDIGO_INTERNAL
        // An internal TestFlight archive: on, with no switch to turn.
        return true
        #else
        return false
        #endif
    }
}

/// One thing on the mixed For You.
nonisolated struct ForYouItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable { case track, artist, record, show }
    enum Payload: Sendable {
        case track(DiscoveredTrack)
        case suggestion(ExploreSuggestion)
        case record(SimilarRecord)
    }

    let kind: Kind
    let payload: Payload
    /// Folded names of who made it, for one-artist-once.
    let artistKeys: Set<String>
    let title: String
    let subtitle: String
    /// Why it is here, in the source's own words.
    let reason: String
    /// What of theirs it came from.
    let via: String
    /// Its verified identity, when the source knows one (a seed's Discogs
    /// id, a record's); nil for a For You route, which names its origin only.
    var viaID: String? = nil
    /// Tags it can be placed by on the compass, folded.
    var tags: [String] = []
    /// What the listening log calls the recommendation when it is played:
    /// the kind, unless the item says otherwise ("cluster-seed").
    var route: String? = nil

    var id: String {
        switch payload {
        case .track(let track): "track:\(track.id)"
        case .suggestion(let suggestion): "node:\(suggestion.id)"
        case .record(let record): "record:\(record.id)"
        }
    }

    static func == (left: ForYouItem, right: ForYouItem) -> Bool { left.id == right.id && left.tags == right.tags }
}

/// A stable selection for six hours, then another part of the ranked pool.
/// This changes what is offered without changing the listener's taste scores.
nonisolated enum RecommendationRotation {
    static let interval: TimeInterval = 6 * 60 * 60

    static func period(at date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / interval))
    }

    static func delayUntilNextPeriod(from date: Date) -> TimeInterval {
        max(1, Double(period(at: date) + 1) * interval - date.timeIntervalSince1970)
    }

    static func rotate<T>(_ ranked: [T], turn: Int) -> [T] {
        guard ranked.count > 1 else { return ranked }
        var step = min(6, max(1, ranked.count / 3))
        // Visit every starting position rather than cycling through four
        // windows that would put the same tracks back every morning.
        func gcd(_ a: Int, _ b: Int) -> Int {
            var a = a, b = b
            while b != 0 { (a, b) = (b, a % b) }
            return a
        }
        while gcd(step, ranked.count) != 1 { step += 1 }
        let offset = ((turn % ranked.count + ranked.count) % ranked.count * step) % ranked.count
        return Array(ranked.dropFirst(offset)) + Array(ranked.prefix(offset))
    }
}

nonisolated enum ForYouMix {
    /// The order kinds are taken in, repeated.
    static let pattern: [ForYouItem.Kind] = [.track, .artist, .record, .track, .artist, .show, .record]

    static func items(offers: ExploreOffers, tracks: [DiscoveredTrack], records: [SimilarRecord],
                      artistTags: [String: [String]] = [:]) -> (tracks: [ForYouItem], artists: [ForYouItem],
                                                               records: [ForYouItem], shows: [ForYouItem]) {
        // Only a track checked to play is offered; an unanswered check is
        // not "plays" (`TrackDiscoverySource` hands over only these, and the
        // mix does not rely on it).
        let trackItems = tracks.filter { $0.playable == .yes }.map { track in
            ForYouItem(kind: .track, payload: .track(track), artistKeys: [RecordingKey.normalizeArtist(track.artist)],
                       title: track.title, subtitle: track.artist, reason: track.reason, via: track.via,
                       viaID: ListeningSurface.discogsArtist(track.viaDiscogsID),
                       tags: track.tags ?? artistTags[RecordingKey.normalizeArtist(track.artist)] ?? [])
        }
        var seen = Set<String>()
        let suggestions = (offers.next + offers.artists + offers.shows).filter { seen.insert($0.id).inserted }
        // People only: a record or a label reached from a starting point is
        // not an artist, and records have a queue of their own.
        let artistItems: [ForYouItem] = suggestions.filter { $0.node.kind == .artist }.map { suggestion in
            let isArtist = suggestion.node.kind == .artist
            let key = RecordingKey.normalizeArtist(suggestion.node.title)
            return ForYouItem(kind: .artist, payload: .suggestion(suggestion), artistKeys: isArtist ? [key] : [],
                              title: suggestion.node.title, subtitle: Self.label(suggestion.node.kind),
                              // What it was reached through, said: "Credited together · via Hype Williams".
                              reason: suggestion.connection, via: suggestion.via,
                              tags: isArtist ? artistTags[key] ?? [] : [])
        }
        let showItems = suggestions.filter { $0.node.kind == .broadcast }.map { suggestion in
            ForYouItem(kind: .show, payload: .suggestion(suggestion), artistKeys: [], title: suggestion.node.title,
                       subtitle: "Radio show", reason: suggestion.connection, via: suggestion.via)
        }
        let recordItems = records.map { found in
            ForYouItem(kind: .record, payload: .record(found), artistKeys: found.record.artistKeys,
                       title: found.record.title,
                       subtitle: [found.record.artistLine, found.record.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                       // Which of theirs it resembles, then how: "Like Stratosphere · Slowcore · both on Numero Group".
                       reason: "Like \(found.via.title) · \(found.reason)", via: found.via.title, viaID: ListeningSurface.discogsRelease(found.via.id),
                       tags: found.record.styles + found.record.genres)
        }
        return (trackItems, artistItems, recordItems, showItems)
    }

    private static func label(_ kind: MusicNodeKind) -> String {
        switch kind {
        case .artist: "Artist"
        case .label: "Label"
        case .release: "Record"
        case .recording: "Track"
        default: "Somewhere to go"
        }
    }

    /// The woven list: the pattern above, one artist once (tracks first,
    /// then records, then pages), each source in its rotating window.
    /// At most this many items reached from any one starting point, across
    /// kinds: a list, not one artist's neighbourhood.
    static let perOrigin = 2

    static func mix(offers: ExploreOffers, tracks: [DiscoveredTrack], records: [SimilarRecord],
                    artistTags: [String: [String]] = [:], limit: Int = 18, turn: Int = 0) -> [ForYouItem] {
        let made = items(offers: offers, tracks: tracks, records: records, artistTags: artistTags)
        // Who is spoken for, by priority: a playable track, then a record.
        var claimed = Set<String>()
        func claim(_ list: [ForYouItem]) -> [ForYouItem] {
            list.filter { item in
                guard item.artistKeys.isDisjoint(with: claimed) else { return false }
                claimed.formUnion(item.artistKeys)
                return true
            }
        }
        var queues: [ForYouItem.Kind: [ForYouItem]] = [
            .track: claim(RecommendationRotation.rotate(made.tracks, turn: turn)),
            .record: claim(RecommendationRotation.rotate(made.records, turn: turn)),
            .artist: claim(RecommendationRotation.rotate(made.artists, turn: turn)),
            .show: RecommendationRotation.rotate(made.shows, turn: turn),
        ]
        var out: [ForYouItem] = []
        var fromOrigin: [String: Int] = [:]
        // An item's starting point, as one artist: a track's and an artist
        // card's are named, a record's is the record of theirs it is like.
        func origin(_ item: ForYouItem) -> String? {
            switch item.payload {
            case .track(let track): RecordingKey.normalizeArtist(track.via)
            case .record(let found): found.via.artistKeys.sorted().first
            case .suggestion(let suggestion): suggestion.via == "what you listen to" ? nil : RecordingKey.normalizeArtist(suggestion.via)
            }
        }
        var step = 0
        // Round the pattern until every queue is empty or the list is full;
        // a kind with nothing left is skipped, not waited for, and a
        // starting point that has had its share gives way to the next item.
        while out.count < limit, queues.values.contains(where: { !$0.isEmpty }) {
            let kind = pattern[step % pattern.count]
            step += 1
            guard var queue = queues[kind], !queue.isEmpty else { continue }
            if let index = queue.firstIndex(where: { item in origin(item).map { fromOrigin[$0, default: 0] < perOrigin } ?? true }) {
                let item = queue.remove(at: index)
                if let key = origin(item) { fromOrigin[key, default: 0] += 1 }
                out.append(item)
            } else {
                queue.removeAll()
            }
            queues[kind] = queue
        }
        return out
    }
}
