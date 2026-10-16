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
    /// A starting point: one of the listener's artists, by Discogs entry.
    struct Seed: Equatable, Sendable {
        let discogsID: Int
        let name: String
        let weight: Double
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
            if knownArtists.contains(RecordingKey.normalizeArtist(appearance.artist)) { score *= 0.4 }
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
                year: appearance.year, reason: neighbour.reason,
                via: neighbour.seed.name, playable: .unknown, score: score))
        }
        candidates.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        // One track per artist, a few per starting point, a couple per show
        // or channel: a list, not one person's catalogue or one DJ's set.
        var chosen: [DiscoveredTrack] = []
        var artists = Set<Int>(), perVia: [String: Int] = [:], perPlace: [String: Int] = [:]
        for candidate in candidates where chosen.count < limit {
            let place = sourceKey(candidate.source)
            guard !artists.contains(candidate.artistDiscogsID), perVia[candidate.via, default: 0] < perSeed,
                  perPlace[place, default: 0] < perSource else { continue }
            artists.insert(candidate.artistDiscogsID)
            perVia[candidate.via, default: 0] += 1
            perPlace[place, default: 0] += 1
            chosen.append(candidate)
        }
        return chosen
    }

    private static func sourceKey(_ source: DiscoveredTrack.Source) -> String {
        switch source {
        case .recording(_, let channel): "yt|\(channel ?? "")"
        case .episode(let listen, _): "ep|\(listen.showTitle ?? listen.episode)"
        }
    }
}
