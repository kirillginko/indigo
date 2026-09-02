//
//  PanikModels.swift
//  Indigo
//
//  The shapes the Radio Panik pages render.
//
//  Panik is the first station Indigo reads that publishes no JSON catalogue at
//  all: its archive is podcast RSS, its directory and schedule are HTML, and
//  the one JSON endpoint it has says only what is on the air. The parsing that
//  follows from that lives in `PanikHTML`; this file is what comes out of it.
//
//  The good news is the archive: every episode carries a direct address for
//  its recording, so a broadcast plays through the same engine a local file
//  does — seekable, with a real duration — rather than through a widget.
//

import Foundation

// MARK: - Domain types

/// Panik files every show under one of six headings. They are the station's
/// own words, in French, and they double as the genre filter.
nonisolated struct PanikCategory: Identifiable, Hashable, Sendable {
    let name: String
    var id: String { name }
}

nonisolated struct PanikShow: Identifiable, Hashable, Sendable {
    let slug: String
    let title: String
    let summary: String?
    let imageURL: URL?
    let categories: [String]
    let links: [MediaLink]
    /// "Mardi 22:00" — when the show goes out, as the station writes it.
    let slot: String?

    var id: String { slug }

    var subtitle: String {
        [slot, categories.first].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

nonisolated struct PanikEpisode: Identifiable, Hashable, Sendable {
    /// "daydream-nation/mixtape-session-22" — the show and the episode, which
    /// is exactly the path the station files it under and all that is needed
    /// to find it again.
    let id: String
    let title: String
    let showSlug: String?
    let showTitle: String?
    let publishedAt: Date?
    let duration: TimeInterval?
    /// Panik hosts its own recordings, which is why an episode seeks properly
    /// instead of going through somebody's widget.
    let audioURL: URL?
    let imageURL: URL?
    let summary: String?
    /// The episode's page on the station's site.
    let pageURL: URL?

    var mediaID: String { "panik.episode.\(id)" }
    var isPlayable: Bool { audioURL != nil }

    var broadcastLabel: String? {
        guard let publishedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: publishedAt)
    }

    var listSubtitle: String {
        [showTitle, broadcastLabel].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The day this went out, which is how Panik files its tracklists.
    var playlistDate: DateComponents? {
        guard let publishedAt else { return nil }
        return Calendar.current.dateComponents([.year, .month, .day], from: publishedAt)
    }

    func mediaItem() -> MediaItem? {
        guard let audioURL else { return nil }
        return MediaItem(
            id: mediaID,
            sourceID: PanikProvider.providerID,
            kind: .episode,
            title: title,
            subtitle: showTitle ?? broadcastLabel,
            detail: "Radio Panik",
            remoteArtworkURL: imageURL,
            playbackURL: audioURL,
            duration: duration
        )
    }
}

/// A slot on the published week.
nonisolated struct PanikScheduleEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let showSlug: String?
    let categories: [String]
    let startsAt: Date
    /// Panik logs what it played on the continuous-music shows, filed by the
    /// day it went out.
    let playlistPath: String?

    /// Panik publishes a start time per slot and no end, so a slot runs until
    /// the next one begins. The schedule fills this in once it has the row
    /// below; the last slot of the week has nothing to end against.
    var endsAt: Date?

    func contains(_ date: Date) -> Bool {
        guard let endsAt else { return false }
        return startsAt <= date && date < endsAt
    }

    /// "18:00–20:00", or just the start when nothing follows it yet.
    var slot: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        guard let endsAt else { return formatter.string(from: startsAt) }
        return "\(formatter.string(from: startsAt))–\(formatter.string(from: endsAt))"
    }

    func asRadioShow() -> RadioShow {
        RadioShow(
            title: title,
            host: nil,
            summary: nil,
            location: "Brussels",
            genres: categories,
            moods: [],
            artworkURL: nil,
            startsAt: startsAt,
            endsAt: endsAt,
            detailID: showSlug
        )
    }
}

/// One line of a continuous-music show's log. Panik records the artist and the
/// title separately and stamps each with the minute it played, which is more
/// than most stations keep — and exactly what the crate wants.
nonisolated struct PanikTrack: Identifiable, Hashable, Sendable {
    let index: Int
    let time: String?
    let artist: String?
    let title: String

    var id: Int { index }

    var display: String {
        guard let artist, !artist.isEmpty else { return title }
        return "\(artist) — \(title)"
    }
}

/// What the station says is on the air, from the one endpoint that answers in
/// JSON rather than HTML.
///
/// Panik broadcasts two different kinds of thing and says so differently. A
/// programme is an `emission` with a name and a strapline. The hours between
/// them are `nonstop` — continuous music — and there the station names the
/// record playing this minute as well as the slot, which is the better thing
/// to put on screen.
nonisolated struct PanikOnAir: Hashable, Sendable {
    var title: String?
    var subtitle: String?
    var showSlug: String?
    /// Set only during the continuous-music hours.
    var trackTitle: String?
    var trackArtist: String?
    /// The day's log, which the station links straight from here.
    var playlistPath: String?
    var isNonstop = false

    static let idle = PanikOnAir()

    var isOnAir: Bool { title != nil }

    /// "Gangsta Pat — Deadly Verses", when the station is naming records.
    var nowPlaying: String? {
        guard let trackTitle, !trackTitle.isEmpty else { return nil }
        guard let trackArtist, !trackArtist.isEmpty else { return trackTitle }
        return "\(trackArtist) — \(trackTitle)"
    }
}

// MARK: - Wire types

/// `/onair.json` — the whole document, in either of the two shapes it takes.
nonisolated struct PanikOnAirDTO: Decodable, Sendable {
    let data: Payload?

    nonisolated struct Payload: Decodable, Sendable {
        /// A programme.
        let emission: Slot?
        /// The continuous-music hours between programmes.
        let nonstop: Slot?
        /// Named only alongside `nonstop`.
        let track_title: String?
        let track_artist: String?
    }

    nonisolated struct Slot: Decodable, Sendable {
        let title: String?
        let subtitle: String?
        let slug: String?
        let url: String?
        let playlist_url: String?
    }

    func asOnAir() -> PanikOnAir {
        // A programme is the more specific answer, so it wins when both are
        // somehow present.
        let isNonstop = data?.emission == nil && data?.nonstop != nil
        guard let slot = data?.emission ?? data?.nonstop else { return .idle }

        return PanikOnAir(
            title: slot.title.map(HTMLText.decode)?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty,
            subtitle: slot.subtitle.map(HTMLText.decode)?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty,
            showSlug: slot.slug?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            trackTitle: data?.track_title.map(HTMLText.decode)?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty,
            trackArtist: data?.track_artist.map(HTMLText.decode)?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty,
            playlistPath: slot.playlist_url?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            isNonstop: isNonstop
        )
    }
}

// MARK: - Episode identity

/// Panik files an episode under its show — "/emissions/<show>/<episode>/" —
/// so the path is both the identity and the way back to it. The crate keeps
/// only this string, and it is enough to rebuild the request from cold.
nonisolated enum PanikEpisodeID {
    /// Pulls "show/episode" out of a link, whichever form the feed wrote it in.
    static func fromLink(_ link: String?) -> String? {
        guard let link, !link.isEmpty else { return nil }
        let path: String
        if let components = URLComponents(string: link), components.host != nil {
            path = components.path
        } else {
            path = link
        }
        let parts = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let index = parts.firstIndex(of: "emissions"), parts.count > index + 2 else {
            return nil
        }
        return "\(parts[index + 1])/\(parts[index + 2])"
    }

    static func showSlug(of id: String) -> String? {
        id.split(separator: "/").first.map(String.init)
    }

    /// The page it came from, which is also where the recording is linked.
    static func pagePath(_ id: String) -> String? {
        let parts = id.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        return "/emissions/\(parts[0])/\(parts[1])/"
    }
}

// MARK: - Mapping

extension PodcastFeedItem {
    /// One feed item as a Panik broadcast.
    ///
    /// The station-wide feed writes titles as "[Show] Episode" and the
    /// per-show feed writes the episode alone, so the show is taken from the
    /// link — which is an identifier — and the bracket is only stripped off
    /// the title for display.
    func asPanikEpisode(showSlug: String? = nil, showTitle: String? = nil) -> PanikEpisode? {
        guard let identity = PanikEpisodeID.fromLink(link) else { return nil }
        let raw = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }

        let (stripped, bracketed) = PanikTitle.split(raw)

        return PanikEpisode(
            id: identity,
            title: stripped,
            showSlug: showSlug ?? PanikEpisodeID.showSlug(of: identity),
            showTitle: showTitle ?? bracketed,
            publishedAt: publishedAt,
            duration: duration,
            audioURL: enclosureURL,
            imageURL: imageURL,
            summary: summaryHTML.flatMap(HTMLText.plainText)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            pageURL: link.flatMap { URL(string: $0) }
        )
    }
}

// MARK: - Helpers

nonisolated enum PanikTitle {
    /// "[Daydream Nation] Mixtape session #22" → the title without the
    /// bracket, and the show name that was in it.
    static func split(_ title: String) -> (title: String, show: String?) {
        guard title.hasPrefix("["), let close = title.firstIndex(of: "]") else {
            return (title, nil)
        }
        let show = String(title[title.index(after: title.startIndex)..<close])
            .trimmingCharacters(in: .whitespaces)
        let rest = String(title[title.index(after: close)...])
            .trimmingCharacters(in: .whitespaces)
        // A bracket with nothing after it was the whole title, not a prefix.
        guard !rest.isEmpty else { return (title, nil) }
        return (rest, show.isEmpty ? nil : show)
    }
}
