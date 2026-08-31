//
//  LotModels.swift
//  Indigo
//
//  Wire format for thelotradio.com plus the shapes the Lot pages render.
//  The Lot is a Contentful-backed Next.js site: entries arrive as `sys`/link
//  collections, and everything optional here is optional because the live
//  payload has been seen without it.
//

import Foundation

// MARK: - Wire types

nonisolated struct LotSys: Decodable, Sendable {
    let id: String?
}

/// Server actions answer with the asset inline. Server-rendered pages hoist
/// shared assets into the element tree and leave a path string behind — the
/// same field, a different JSON type — so both have to decode.
nonisolated struct LotAssetDTO: Decodable, Sendable {
    let url: String?
    let width: Int?
    let height: Int?
    let title: String?
    let description: String?

    private enum CodingKeys: String, CodingKey { case url, width, height, title, description }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), (try? single.decode(String.self)) != nil {
            url = nil; width = nil; height = nil; title = nil; description = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }
}

/// Contentful nulls out links it cannot resolve rather than omitting them, so
/// an unpublished genre arrives as a literal `null` inside `items` and would
/// otherwise take the whole page down with it.
nonisolated struct LotCollection<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]

    private enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), (try? single.decode(String.self)) != nil {
            items = []
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try container.decodeIfPresent([Item?].self, forKey: .items) ?? []).compactMap { $0 }
    }
}

nonisolated struct LotGenreDTO: Decodable, Sendable {
    let sys: LotSys?
    let name: String?
    let slug: String?
}

nonisolated struct LotArtistDTO: Decodable, Sendable {
    let sys: LotSys?
    let name: String?
    let slug: String?
    let aka: String?
    let thisIsAResident: Bool?
    let photo: LotAssetDTO?
    // Only the show and episode pages carry these; the archive listing omits
    // them, so an artist off the index simply has nowhere to go.
    let linkBandcamp: String?
    let linkMixcloud: String?
    let linkSoundCloud: String?
    let linkWebsite: String?
    let socialInstagram: String?
    let socialFacebook: String?
}

nonisolated struct LotShowDTO: Decodable, Sendable {
    let sys: LotSys?
    let name: String?
    let slug: String?
    let eventId: String?
    let photo: LotAssetDTO?
    let genres: LotCollection<LotGenreDTO>?
    let artists: LotCollection<LotArtistDTO>?
}

nonisolated struct LotTrackDTO: Decodable, Sendable {
    let title: String?
    let artist: String?
    /// Wall-clock time the track was logged, not an offset into the recording.
    let timestamp: String?
}

nonisolated struct LotTranscodedFileDTO: Decodable, Sendable {
    let hls: String?
    let mp4: [String]?
}

nonisolated struct LotEpisodeDTO: Decodable, Sendable {
    let sys: LotSys?
    let title: String?
    /// "2026-08-21-1800" — unique within a show, and the last path component
    /// of the episode's page.
    let slug: String?
    let eventId: String?
    /// When the slot was scheduled.
    let date: String?
    /// When the broadcast actually started and stopped. The recording is cut
    /// to these, so tracklist offsets are measured from `startTimestamp`.
    let startTimestamp: String?
    let endTimestamp: String?
    let transcodedFile: LotTranscodedFileDTO?
    let tracklist: [LotTrackDTO]?
    let image: LotAssetDTO?
    let thumbnailsCollection: LotCollection<LotAssetDTO>?
    let location: LotLocationDTO?
    let genres: LotCollection<LotGenreDTO>?
    let artists: LotCollection<LotArtistDTO>?
    let show: LotShowDTO?
}

nonisolated struct LotLocationDTO: Decodable, Sendable {
    let name: String?
}

/// Cursor-paged. `pages.next` is opaque and carries the sort and filters that
/// produced it, so it is passed back verbatim.
nonisolated struct LotEpisodePageDTO: Decodable, Sendable {
    let items: [LotEpisodeDTO]
    let total: Int?
    let pages: Pages?

    nonisolated struct Pages: Decodable, Sendable {
        let next: String?
        let prev: String?
    }
}

/// Offset-paged, unlike the episode archive.
nonisolated struct LotShowPageDTO: Decodable, Sendable {
    let items: [LotShowDTO]
    let total: Int?
    let limit: Int?
    let skip: Int?
}

/// One live channel. The Lot runs a main stream and occasionally a second
/// pop-up one, each with its own Livepeer playback id and calendar.
nonisolated struct LotLiveDTO: Decodable, Sendable {
    let id: String?
    let title: String?
    let live: String?
    let src: [Source]?
    let poster: Poster?
    let playbackInfo: PlaybackInfo?
    let schedule: [LotCalendarEntryDTO]?

    nonisolated struct Source: Decodable, Sendable {
        let type: String?
        let src: String?
        let mime: String?
    }

    nonisolated struct Poster: Decodable, Sendable {
        let src: String?
        let alt: String?
    }

    nonisolated struct PlaybackInfo: Decodable, Sendable {
        let type: String?
        let meta: Meta?
        nonisolated struct Meta: Decodable, Sendable { let live: Int? }
    }
}

/// The programming calendar, as published to the site's own player.
nonisolated struct LotCalendarEntryDTO: Decodable, Sendable {
    let id: String?
    let summary: String?
    /// Either the text itself or a "$22" reference into the flight stream.
    let description: String?
    let start: String?
    let end: String?
    let reccuring: Bool?
    let reccuringEventId: String?
}

/// Contentful rich text, as the show and episode pages ship it.
nonisolated struct LotRichTextDTO: Decodable, Sendable {
    let json: Node?

    nonisolated struct Node: Decodable, Sendable {
        let nodeType: String?
        let value: String?
        let content: [Node]?
    }

    /// Paragraphs joined by a blank line; everything else is flattened.
    var plainText: String? {
        guard let json else { return nil }
        var paragraphs: [String] = []
        func walk(_ node: Node) {
            if node.nodeType == "paragraph" {
                let text = Self.flatten(node).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { paragraphs.append(text) }
                return
            }
            for child in node.content ?? [] { walk(child) }
        }
        walk(json)
        if paragraphs.isEmpty {
            let flat = Self.flatten(json).trimmingCharacters(in: .whitespacesAndNewlines)
            return flat.isEmpty ? nil : flat
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func flatten(_ node: Node) -> String {
        var text = node.value ?? ""
        for child in node.content ?? [] { text += flatten(child) }
        return text
    }
}

// MARK: - Domain types

nonisolated struct LotGenre: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let slug: String
}

nonisolated struct LotArtist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let slug: String
    let aka: String?
    let isResident: Bool
    let photoURL: URL?
    /// Where else this artist can be heard, in the order the page lists them.
    let links: [MediaLink]
}


nonisolated struct LotShow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let slug: String
    let photoURL: URL?
    let genres: [LotGenre]
    let artists: [LotArtist]

    var genreLine: String? {
        genres.isEmpty ? nil : genres.map(\.name).joined(separator: " · ")
    }

    var artistLine: String? {
        artists.isEmpty ? nil : artists.map(\.name).joined(separator: ", ")
    }

    /// Detail pages occasionally publish a thinner copy of the same show
    /// than the directory card. Never let that response erase artwork or
    /// taxonomy the listener could already see before opening it.
    func fillingMissingFields(from fallback: LotShow?) -> LotShow {
        guard let fallback else { return self }
        return LotShow(
            id: id,
            name: name.isEmpty ? fallback.name : name,
            slug: slug.isEmpty ? fallback.slug : slug,
            photoURL: photoURL ?? fallback.photoURL,
            genres: genres.isEmpty ? fallback.genres : genres,
            artists: artists.isEmpty ? fallback.artists : artists
        )
    }
}

/// One logged track, with the offset into the recording where it starts. The
/// Lot logs wall-clock times, so the offset only exists once the broadcast's
/// own start is known.
nonisolated struct LotTrack: Identifiable, Hashable, Sendable {
    let index: Int
    let title: String
    let artist: String?
    let playedAt: Date?
    let offset: TimeInterval?

    var id: Int { index }

    var line: String {
        guard let artist, !artist.isEmpty else { return title }
        return "\(artist) — \(title)"
    }

    var offsetLabel: String? {
        guard let offset, offset >= 0 else { return nil }
        let total = Int(offset.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// Where an episode lives on the site, and the identity Indigo files it under.
/// Both slugs are needed: the archive is addressed as show/episode, and the
/// episode slug alone repeats across residencies.
nonisolated struct LotEpisodeRef: Hashable, Sendable {
    let show: String
    let episode: String

    var encoded: String { "\(show)/\(episode)" }
    var path: String { "shows/\(show)/\(episode)" }

    static func decode(_ value: String) -> LotEpisodeRef? {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return LotEpisodeRef(show: String(parts[0]), episode: String(parts[1]))
    }
}

nonisolated struct LotEpisode: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let slug: String
    let airedAt: Date?
    let startedAt: Date?
    let endedAt: Date?
    /// The archived recording. Absent while a broadcast is still being cut.
    let streamURL: URL?
    let tracklist: [LotTrack]
    let imageURL: URL?
    /// Frames grabbed from the broadcast, in order.
    let thumbnailURLs: [URL]
    let location: String?
    let genres: [LotGenre]
    let artists: [LotArtist]
    let show: LotShow?

    var ref: LotEpisodeRef? {
        guard let showSlug = show?.slug, !showSlug.isEmpty, !slug.isEmpty else { return nil }
        return LotEpisodeRef(show: showSlug, episode: slug)
    }

    /// The player's identity for this episode, stable across launches so the
    /// crate can point back at it.
    var mediaID: String {
        ref.map { "lot.episode.\($0.encoded)" } ?? "lot.episode.id.\(id)"
    }

    var isPlayable: Bool { streamURL != nil }

    var duration: TimeInterval? {
        guard let startedAt, let endedAt, endedAt > startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    var genreNames: [String] { genres.map(\.name) }

    var airedLabel: String? {
        guard let date = airedAt ?? startedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// "18:00–20:00" in the listener's local time.
    var slot: String? {
        guard let startedAt, let endedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: startedAt))–\(formatter.string(from: endedAt))"
    }

    var subtitle: String {
        [airedLabel, show?.name]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The best artwork the archive offers: the photographer's shot if there
    /// is one, otherwise a frame from the broadcast itself.
    var artworkURL: URL? { imageURL ?? thumbnailURLs.first }

    func mediaItem() -> MediaItem? {
        guard let streamURL else { return nil }
        return MediaItem(
            id: mediaID,
            sourceID: LotProvider.providerID,
            kind: .episode,
            title: title,
            subtitle: show?.name ?? airedLabel,
            detail: "The Lot Radio",
            genres: genreNames,
            remoteArtworkURL: artworkURL,
            playbackURL: streamURL,
            duration: duration
        )
    }
}

/// Everything the expanded page shows that the archive listing does not.
nonisolated struct LotEpisodeDetail: Sendable {
    let episode: LotEpisode
    /// The session note the station writes for the slot.
    let summary: String?
    let related: [LotEpisode]
}

nonisolated struct LotShowDetail: Sendable {
    let show: LotShow
    let summary: String?
    let episodes: [LotEpisode]
}

/// One slot on the published calendar. Live programming has no episode until
/// the recording has been cut, so this is all the station can say about what
/// is on air right now.
nonisolated struct LotScheduleEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String?
    /// Where the booking says the artist can be found. The station writes
    /// these into the calendar note as bare addresses.
    let links: [MediaLink]
    let startsAt: Date
    let endsAt: Date
    let isRecurring: Bool

    func contains(_ date: Date) -> Bool { startsAt <= date && date < endsAt }

    /// "18:00–20:00" in the listener's local time.
    var slot: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: startsAt))–\(formatter.string(from: endsAt))"
    }

    /// The Lot bills guest slots as "Residency with Guest"; the residency
    /// alone is what the shows directory is keyed by.
    var showName: String {
        for separator in [" with ", " w/ ", " invites ", " presents "] {
            if let range = title.range(of: separator, options: .caseInsensitive) {
                return String(title[title.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return title
    }

    func asRadioShow(artworkURL: URL? = nil) -> RadioShow {
        RadioShow(
            title: title,
            host: nil,
            summary: summary,
            location: "Brooklyn",
            genres: [],
            moods: [],
            artworkURL: artworkURL,
            startsAt: startsAt,
            endsAt: endsAt,
            detailID: nil
        )
    }
}

/// The live channel as the station page renders it.
nonisolated struct LotLiveChannel: Sendable {
    let id: String
    let title: String
    let streamURL: URL
    /// A still lifted from the broadcast a moment ago — the Lot points a
    /// camera at the booth, so this is the closest thing it has to artwork.
    let posterURL: URL?
    let isOnAir: Bool
    let schedule: [LotScheduleEntry]

    /// The poster only ever answers with its newest frame, and the URL never
    /// changes, so the image layer would hold the first one forever.
    func posterURL(at date: Date) -> URL? {
        guard let posterURL, var components = URLComponents(url: posterURL, resolvingAgainstBaseURL: false) else {
            return posterURL
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "t", value: String(Int(date.timeIntervalSince1970) / 60)))
        components.queryItems = items
        return components.url ?? posterURL
    }
}

// MARK: - Mapping

extension LotGenreDTO {
    func asGenre() -> LotGenre? {
        let name = HTMLText.decode(self.name ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return LotGenre(id: sys?.id ?? name.lowercased(), name: name, slug: slug ?? name.lowercased())
    }
}

extension LotArtistDTO {
    func asArtist() -> LotArtist? {
        let name = HTMLText.decode(self.name ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let links = [
            ("Bandcamp", linkBandcamp),
            ("SoundCloud", linkSoundCloud),
            ("Mixcloud", linkMixcloud),
            ("Instagram", socialInstagram),
            ("Facebook", socialFacebook),
            ("Website", linkWebsite)
        ].compactMap { label, value -> MediaLink? in
            guard let value, let url = URL(string: value), url.host != nil else { return nil }
            return MediaLink(label: label, url: url)
        }

        return LotArtist(
            id: sys?.id ?? name.lowercased(),
            name: name,
            slug: slug ?? name.lowercased(),
            aka: aka.map(HTMLText.decode),
            isResident: thisIsAResident ?? false,
            photoURL: LotImage.sized(photo?.url),
            links: links
        )
    }
}

extension LotShowDTO {
    func asShow() -> LotShow? {
        let name = HTMLText.decode(self.name ?? "").trimmingCharacters(in: .whitespaces)
        let identity = slug ?? sys?.id
        guard !name.isEmpty, let identity, !identity.isEmpty else { return nil }
        return LotShow(
            id: sys?.id ?? identity,
            name: name,
            slug: identity,
            photoURL: LotImage.sized(photo?.url),
            genres: (genres?.items ?? []).compactMap { $0.asGenre() },
            artists: (artists?.items ?? []).compactMap { $0.asArtist() }
        )
    }
}

extension LotEpisodeDTO {
    func asEpisode() -> LotEpisode? {
        guard let identity = sys?.id, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let started = LotTimestamp.parse(startTimestamp)
        let tracks = (tracklist ?? []).enumerated().compactMap { index, dto -> LotTrack? in
            let trackTitle = HTMLText.decode(dto.title ?? "").trimmingCharacters(in: .whitespaces)
            guard !trackTitle.isEmpty else { return nil }
            let playedAt = LotTimestamp.parse(dto.timestamp)
            let offset: TimeInterval? = {
                guard let playedAt, let started else { return nil }
                let seconds = playedAt.timeIntervalSince(started)
                return seconds >= 0 ? seconds : nil
            }()
            let artistName = HTMLText.decode(dto.artist ?? "").trimmingCharacters(in: .whitespaces)
            return LotTrack(
                index: index + 1,
                title: trackTitle,
                artist: artistName.isEmpty ? nil : artistName,
                playedAt: playedAt,
                offset: offset
            )
        }

        return LotEpisode(
            id: identity,
            title: name,
            slug: slug ?? "",
            airedAt: LotTimestamp.parse(date),
            startedAt: started,
            endedAt: LotTimestamp.parse(endTimestamp),
            streamURL: transcodedFile?.hls.flatMap { URL(string: $0) },
            tracklist: tracks,
            imageURL: LotImage.sized(image?.url),
            thumbnailURLs: (thumbnailsCollection?.items ?? []).compactMap { LotImage.sized($0.url) },
            location: location?.name.map(HTMLText.decode),
            genres: (genres?.items ?? []).compactMap { $0.asGenre() },
            artists: (artists?.items ?? []).compactMap { $0.asArtist() },
            show: show?.asShow()
        )
    }
}

extension LotCalendarEntryDTO {
    /// `flight` resolves descriptions that were hoisted into their own row.
    func asScheduleEntry(resolvedBy flight: LotFlight?) -> LotScheduleEntry? {
        guard let start = LotTimestamp.parse(start),
              let end = LotTimestamp.parse(end),
              end > start
        else { return nil }
        let name = HTMLText.decode(summary ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let raw = flight?.resolve(description) ?? description
        let note = raw.map(LotMarkup.parse) ?? (text: "", links: [])

        return LotScheduleEntry(
            id: id ?? "\(name)|\(start.timeIntervalSince1970)",
            title: name,
            summary: note.text.isEmpty ? nil : note.text,
            links: note.links,
            startsAt: start,
            endsAt: end,
            isRecurring: reccuring ?? false
        )
    }
}

extension LotLiveDTO {
    func asChannel(resolvedBy flight: LotFlight?) -> LotLiveChannel? {
        let hls = (src ?? []).first { $0.type == "hls" }?.src
            ?? (src ?? []).first { ($0.src ?? "").hasSuffix(".m3u8") }?.src
        guard let hls, let url = URL(string: hls) else { return nil }
        let name = HTMLText.decode(title ?? live ?? "The Lot Radio").trimmingCharacters(in: .whitespaces)

        return LotLiveChannel(
            id: id ?? name.lowercased(),
            title: name.isEmpty ? "The Lot Radio" : name,
            streamURL: url,
            posterURL: poster?.src.flatMap { URL(string: $0) },
            isOnAir: (playbackInfo?.meta?.live ?? 0) == 1,
            schedule: (schedule ?? [])
                .compactMap { $0.asScheduleEntry(resolvedBy: flight) }
                .sorted { $0.startsAt < $1.startsAt }
        )
    }
}

// MARK: - Helpers

/// Contentful stamps entries with fractional seconds and Zulu time; the
/// calendar comes through with a New York offset.
/// The Lot's pictures come from Contentful, which serves the untouched
/// original — regularly two or three megabytes — unless asked otherwise. Its
/// Images API takes a width on the query string, and a tile drawn at 300pt on
/// a retina display never needs more than six hundred pixels.
nonisolated enum LotImage {
    static func sized(_ address: String?, width: Int = 600) -> URL? {
        guard let address, var components = URLComponents(string: address) else { return nil }
        guard components.host?.contains("ctfassets.net") == true else {
            return URL(string: address)
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "w" || $0.name == "fm" || $0.name == "q" }
        items.append(URLQueryItem(name: "w", value: String(width)))
        // Contentful re-encodes on the fly; asking for a sensible quality
        // keeps a photograph from arriving as a lossless original.
        items.append(URLQueryItem(name: "q", value: "80"))
        components.queryItems = items
        return components.url ?? URL(string: address)
    }
}

nonisolated enum LotTimestamp {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return fractional.date(from: value) ?? plain.date(from: value)
    }
}

/// Calendar descriptions are hand-written HTML — line breaks, and links to
/// wherever the artist can be found. Indigo renders text, so this keeps the
/// breaks, drops the markup, and lifts the links out into their own list: a
/// bare address printed in the middle of a paragraph is not something anyone
/// reads.
nonisolated enum LotMarkup {
    static func plainText(_ html: String) -> String { parse(html).text }

    static func parse(_ html: String) -> (text: String, links: [MediaLink]) {
        var output = ""
        var anchorText = ""
        var href: String?
        var links: [MediaLink] = []
        var seen = Set<String>()
        var index = html.startIndex

        while index < html.endIndex {
            guard html[index] == "<" else {
                if href != nil { anchorText.append(html[index]) } else { output.append(html[index]) }
                index = html.index(after: index)
                continue
            }
            guard let close = html[index...].firstIndex(of: ">") else { break }
            let tag = String(html[html.index(after: index)..<close])
            let name = tag.lowercased()

            if name == "a" || name.hasPrefix("a ") {
                href = attribute("href", in: tag)
                anchorText = ""
            } else if name == "/a" {
                let text = HTMLText.decode(anchorText).trimmingCharacters(in: .whitespaces)
                if let address = href, let url = URL(string: address), url.host != nil {
                    if seen.insert(url.absoluteString).inserted {
                        links.append(MediaLink(label: MediaLink.label(for: url), url: url))
                    }
                    // Anchor text that is only the address again says nothing
                    // the chip does not already say.
                    if !text.isEmpty, text.caseInsensitiveCompare(address) != .orderedSame {
                        output += text
                    }
                } else {
                    output += text
                }
                href = nil
                anchorText = ""
            } else if name.hasPrefix("br") || name.hasPrefix("/p") || name.hasPrefix("/div") {
                if href != nil { anchorText += "\n" } else { output += "\n" }
            }
            index = html.index(after: close)
        }
        if href != nil { output += anchorText }

        // Hand-written breaks arrive in pairs; collapsing them keeps the note
        // reading as paragraphs rather than as a column of gaps.
        let text = HTMLText.decode(output)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, links)
    }

    /// `href="https://…"`, single or double quoted.
    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        var rest = tag[range.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else {
            return rest.prefix { !$0.isWhitespace }.isEmpty ? nil : String(rest.prefix { !$0.isWhitespace })
        }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: quote) else { return nil }
        let value = String(rest[rest.startIndex..<end]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : HTMLText.decode(value)
    }

}
