//
//  TrackDiscovery.swift
//  Indigo
//
//  DIG Discover: tracks to hear, not artists to read about.
//
//  Starting from what the listener keeps and plays (the long-term half and a
//  bounded "now", as `MusicianFirstRanker` chooses them), the candidates are
//  artists the record connects to those starting points -- played next to
//  them in real radio tracklists, or credited with them on a record -- and
//  what is offered is one of *their tracks*, as it can actually be heard:
//
//  - **A recording**: a YouTube upload of that very track, from the channels
//    Indigo follows as radio (`media_url` on the appearance).
//  - **In an episode**: an NTS or Lot Radio episode whose tracklist has the
//    track at a known moment, played from that moment.
//
//  Anything else -- a track known only by name -- is never in the queue.
//  Playback is checked through the integration that would play it before a
//  track is offered; a check that cannot be answered is "unknown", never
//  "does not play". Every artist is a verified Discogs entry.
//
//  Development builds only (`TrackDiscoveryFeature`).
//

import Foundation

nonisolated enum TrackDiscoveryFeature {
    #if DEBUG
    static let switchKey = "INDIGO_DIG_TRACKS"
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

/// For You's "Tracks to hear": DIG Discover's own list, shown on For You
/// (`ForYouTracksSection`). The same engine, cache and playback checks --
/// nothing is worked out twice. Development builds only, by launch argument
/// (`-INDIGO_FORYOU_TRACKS YES`) or in a test; never in an internal archive
/// or a release build.
nonisolated enum ForYouTracksFeature {
    #if DEBUG
    static let switchKey = "INDIGO_FORYOU_TRACKS"
    #endif
    nonisolated(unsafe) static var override: Bool?

    static var isEnabled: Bool {
        if let override { return override }
        #if DEBUG
        return UserDefaults.standard.bool(forKey: switchKey)
        #else
        return false
        #endif
    }
}

/// A track to hear, and why.
nonisolated struct DiscoveredTrack: Identifiable, Equatable, Sendable, Codable {
    enum Source: Equatable, Sendable, Codable {
        /// An upload of the track itself.
        case recording(URL, channel: String?)
        /// An episode with the track at a moment.
        case episode(RadioListen, at: Int)
    }

    /// How sure Indigo is that it plays: checked and plays, checked and does
    /// not, or not yet known.
    enum Playable: Equatable, Sendable, Codable { case yes, no, unknown }

    let artist: String
    let artistDiscogsID: Int
    let title: String
    let source: Source
    var artworkURL: URL?
    /// The release it is on and its year, when a release document says so.
    var release: String? = nil
    var year: Int? = nil
    /// That release's Discogs entry, when the document it came from is one.
    var releaseDiscogsID: Int? = nil
    /// Which half of the listener's taste the starting point came from: what
    /// they are into now, or what they have kept and played over time.
    var signal: TrackDiscovery.Signal? = nil
    /// Whether the artist is one the listener already keeps or has played:
    /// offered rarely, never first. Nil on a list held from before.
    var knownArtist: Bool? = nil
    /// What the show or release it came from says it sounds like, folded.
    var tags: [String]? = nil
    /// The fact behind it, in a line: "Played next to Huerco S. in 4 episodes".
    let reason: String
    /// The listener's starting point it came from.
    let via: String
    var playable: Playable
    var score: Double

    var id: String { "\(artistDiscogsID)|\(TrackDiscovery.trackKey(title))" }

    /// A recording of the track itself, as opposed to the moment it was
    /// played in a radio show: a different thing to put on, and said so.
    var isRecording: Bool { if case .recording = source { true } else { false } }

    /// The reason in a few words, for under a tile: "Next to Aphex Twin on
    /// radio", "With Black Dog Productions", "By Burial".
    var shortReason: String {
        if reason.hasPrefix("Played next to ") { return "Next to \(via) on radio" }
        if reason.hasPrefix("With ") { return "With \(via)" }
        return reason
    }

    /// The play action, in words that say which.
    var playLabel: String { isRecording ? "Play track" : "Hear in radio show" }

    /// A YouTube thumbnail, for a recording that has one.
    static func thumbnail(for url: URL) -> URL? {
        guard let id = YouTubeLink.videoID(from: url) else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }
}

nonisolated enum TrackDiscovery {
    /// Which half of the listener's taste a starting point stands for
    /// (`MusicianFirstRanker.Half`), as a track carries it.
    enum Signal: String, Equatable, Sendable, Codable { case recent, longTerm }

    /// A starting point: one of the listener's artists, by Discogs entry.
    struct Seed: Equatable, Sendable {
        let discogsID: Int
        let name: String
        let weight: Double
        /// Nil for an artist page, which is not the listener's taste.
        var signal: Signal? = nil
    }

    /// An artist the record connects to a seed.
    struct Neighbour: Equatable, Sendable {
        let discogsID: Int
        let name: String
        let seed: Seed
        /// "Played next to X in 4 episodes", "Made a record with X".
        let reason: String
        let strength: Double
    }

    /// One track of a neighbour's, as the radio record has it.
    struct Appearance: Equatable, Sendable {
        let artistDiscogsID: Int
        let artist: String
        let title: String
        let source: DiscoveredTrack.Source
        let artworkURL: URL?
        let genres: [String]
        var release: String? = nil
        var year: Int? = nil
        var releaseDiscogsID: Int? = nil
    }

    static func trackKey(_ title: String) -> String { RecordingKey.normalize(title) }

    /// Words that mark an upload as something other than the track.
    private static let notATrack = ["footage", "interview", "documentary", "trailer", "teaser", "unboxing",
                                    "review", "reaction", "tutorial", "behind the scenes", "making of", "podcast"]

    /// Whether an upload's title reads as a track by this artist: not footage
    /// or talk, and not led by another name in capitals ("BILLY COBHAM - GINO
    /// VANNELLI…" filed under Chaka Khan).
    static func isTrackUpload(title: String, artist: String) -> Bool {
        let folded = title.lowercased()
        guard !notATrack.contains(where: { folded.contains($0) }) else { return false }
        let parts = title.components(separatedBy: " - ")
        if parts.count >= 3, let lead = parts.first?.trimmingCharacters(in: .whitespaces),
           lead.count > 3, lead == lead.uppercased(), lead.contains(where: \.isLetter),
           !RecordingKey.normalizeArtist(lead).contains(RecordingKey.normalizeArtist(artist)) {
            return false
        }
        return true
    }
    static func knownTrackKey(_ artist: String, _ title: String) -> String {
        "\(RecordingKey.normalizeArtist(artist))|\(trackKey(title))"
    }

    /// The ranked discoveries. Pure: the same arguments, the same answer.
    ///
    /// - knownArtists: folded names of artists the listener keeps or has
    ///   played -- offered rarely, never first; `knownTracks` ("artist|track",
    ///   folded, `knownTrackKey`) never.
    static func rank(
        neighbours: [Neighbour], appearances: [Appearance], taste: TasteProfile,
        knownArtists: Set<String>, knownTracks: Set<String>, limit: Int = 12, perSeed: Int = 3, perSource: Int = 2
    ) -> [DiscoveredTrack] {
        // What the listener is into now leads, but at most half the list:
        // recent activity steers it without crowding out the collection.
        let recentShare = (limit + 1) / 2
        var best: [Int: Neighbour] = [:]
        for neighbour in neighbours where best[neighbour.discogsID].map({ $0.strength * $0.seed.weight < neighbour.strength * neighbour.seed.weight }) ?? true {
            best[neighbour.discogsID] = neighbour
        }
        var candidates: [DiscoveredTrack] = []
        var seenTracks = Set<String>()
        for appearance in appearances.sorted(by: { ($0.artistDiscogsID, $0.title) < ($1.artistDiscogsID, $1.title) }) {
            guard let neighbour = best[appearance.artistDiscogsID] else { continue }
            let key = "\(appearance.artistDiscogsID)|\(trackKey(appearance.title))"
            guard !trackKey(appearance.title).isEmpty, !knownTracks.contains(knownTrackKey(appearance.artist, appearance.title)),
                  seenTracks.insert(key).inserted else { continue }
            var score = neighbour.seed.weight * neighbour.strength
            let known = knownArtists.contains(RecordingKey.normalizeArtist(appearance.artist))
            if known { score *= 0.4 }
            if !taste.isEmpty, !appearance.genres.isEmpty { score *= 0.8 + 0.4 * taste.affinity(for: appearance.genres) }
            if case .episode(_, let at) = appearance.source {
                // A recording of the track is the better thing to put on
                // than its moment in a long show, when the music is as close;
                // and 0:00 is the opener or a position nobody wrote down.
                score *= at > 0 ? 0.75 : 0.6
            }
            candidates.append(DiscoveredTrack(
                artist: appearance.artist, artistDiscogsID: appearance.artistDiscogsID, title: appearance.title,
                source: appearance.source, artworkURL: appearance.artworkURL, release: appearance.release,
                year: appearance.year, releaseDiscogsID: appearance.releaseDiscogsID,
                signal: neighbour.seed.signal, knownArtist: known,
                tags: appearance.genres.isEmpty ? nil : appearance.genres, reason: neighbour.reason,
                via: neighbour.seed.name, playable: .unknown, score: score))
        }
        candidates.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        // One track per artist and per record, a few per starting point, a
        // couple per show or channel: a list, not one person's catalogue, one
        // compilation or one DJ's set.
        var chosen: [DiscoveredTrack] = []
        var artists = Set<Int>(), releases = Set<String>(), perVia: [String: Int] = [:], perPlace: [String: Int] = [:]
        var recent = 0
        for candidate in candidates where chosen.count < limit {
            let place = sourceKey(candidate.source)
            let record = releaseKey(candidate)
            guard !artists.contains(candidate.artistDiscogsID), perVia[candidate.via, default: 0] < perSeed,
                  perPlace[place, default: 0] < perSource, record.map({ !releases.contains($0) }) ?? true,
                  candidate.signal != .recent || recent < recentShare else { continue }
            artists.insert(candidate.artistDiscogsID)
            if let record { releases.insert(record) }
            if candidate.signal == .recent { recent += 1 }
            perVia[candidate.via, default: 0] += 1
            perPlace[place, default: 0] += 1
            chosen.append(candidate)
        }
        return chosen
    }

    /// The record a track is on, by entry or by folded title; nil when
    /// nothing says.
    private static func releaseKey(_ track: DiscoveredTrack) -> String? {
        if let id = track.releaseDiscogsID { return "id|\(id)" }
        guard let title = track.release.map(RecordingKey.normalize), !title.isEmpty else { return nil }
        return "title|\(title)"
    }

    private static func sourceKey(_ source: DiscoveredTrack.Source) -> String {
        switch source {
        case .recording(_, let channel): "yt|\(channel ?? "")"
        case .episode(let listen, _): "ep|\(listen.showTitle ?? listen.episode)"
        }
    }
}
