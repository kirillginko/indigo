//
//  IdaModels.swift
//  Indigo
//
//  Wire format for idaidaida.net plus the shapes the IDA pages render.
//
//  IDA runs on Strapi, and unusually it leaves the REST API open — no key, no
//  introspection to work around, and the records come back flattened rather
//  than wrapped in Strapi's `attributes` envelope. Two things follow from the
//  station rather than from the transport: IDA broadcasts on two channels,
//  Tallinn and Helsinki, so nearly everything here carries a channel; and it
//  writes in three languages, so a description is a choice between them.
//

import Foundation

// MARK: - Envelopes

nonisolated struct IdaListResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    let data: [Item]
    let meta: Meta?

    nonisolated struct Meta: Decodable, Sendable {
        let pagination: Pagination?
        nonisolated struct Pagination: Decodable, Sendable {
            let total: Int?
        }
    }

    var total: Int? { meta?.pagination?.total }
}

nonisolated struct IdaSingleResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    let data: Item?
}

// MARK: - Wire types

/// Strapi's media record. The station uploads at full camera resolution, so
/// the derived `formats` matter: a grid that used `url` would be pulling down
/// 3000px JPEGs for 200pt tiles.
nonisolated struct IdaAssetDTO: Decodable, Sendable {
    let url: String?
    let formats: [String: Format]?

    nonisolated struct Format: Decodable, Sendable {
        let url: String?
        let width: Int?
    }

    /// The original upload.
    var fullURL: URL? { url.flatMap { URL(string: $0) } }

    /// The smallest derivative at least `width` across, falling back to the
    /// original when Strapi generated no formats for this upload.
    func url(atLeast width: Int) -> URL? {
        let candidates = (formats ?? [:]).values
            .compactMap { format -> (Int, URL)? in
                guard let address = format.url, let url = URL(string: address) else { return nil }
                return (format.width ?? .max, url)
            }
            .sorted { $0.0 < $1.0 }
        return candidates.first { $0.0 >= width }?.1 ?? fullURL
    }
}

nonisolated struct IdaGenreDTO: Decodable, Sendable {
    let id: Int?
    let title: String?
    let slug: String?
}

nonisolated struct IdaChannelDTO: Decodable, Sendable {
    let id: Int?
    let title: String?
    let slug: String?
}

nonisolated struct IdaShowDTO: Decodable, Sendable {
    let id: Int?
    let title: String?
    let slug: String?
    let artist: String?
    let alternativeTitle: String?
    let alternativeArtistName: String?
    /// IDA writes in Estonian, English and Finnish, and fills in whichever it
    /// has. Any of the three can be the only one present.
    let contentEst: String?
    let contentEng: String?
    let contentFin: String?
    /// Set once a show has stopped running. IDA marks rather than deletes.
    let archived: Bool?
    let genres: [IdaGenreDTO]?
    let channel: IdaChannelDTO?
    let featuredImage: IdaAssetDTO?
}

nonisolated struct IdaEpisodeDTO: Decodable, Sendable {
    let id: Int?
    let title: String?
    let slug: String?
    let subtitle: String?
    let isRepeat: Bool?
    let start: String?
    let end: String?
    /// A bare Mixcloud path — "IDA_RAADIO/usva-020926/" — not an address.
    let mixcloud: String?
    /// A bare SoundCloud path — "ida_radio/usva-02-09-26".
    let soundcloud: String?
    /// One track a paragraph, most written "Artist - Title [Label Year]".
    let tracklist: String?
    let show: IdaShowDTO?
    let genres: [IdaGenreDTO]?
    let channel: IdaChannelDTO?
    let featuredImage: IdaAssetDTO?
}

/// `/api/live` answers with one object rather than a list: what is on each of
/// the two channels, and what follows on each.
nonisolated struct IdaLiveDTO: Decodable, Sendable {
    let tallinn: Slot?
    let helsinki: Slot?
    let nextTallinn: Upcoming?
    let nextHelsinki: Upcoming?

    /// The live slot carries the stream address alongside the episode, which
    /// is the only place IDA publishes it.
    nonisolated struct Slot: Decodable, Sendable {
        let id: Int?
        let title: String?
        let slug: String?
        let subtitle: String?
        let start: String?
        let end: String?
        let isRepeat: Bool?
        let streamSrc: String?
        let genres: [IdaGenreDTO]?
        let channel: IdaChannelDTO?
        let show: IdaShowDTO?
        let featuredImage: IdaAssetDTO?
    }

    nonisolated struct Upcoming: Decodable, Sendable {
        let id: Int?
        let start: String?
        let show: IdaShowDTO?
    }
}

// MARK: - Domain types

nonisolated struct IdaGenre: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// One of IDA's two channels, as the app talks about it.
nonisolated enum IdaChannel: String, CaseIterable, Identifiable, Sendable {
    case tallinn
    case helsinki

    var id: String { rawValue }

    /// The station id the player and sidebar key off.
    var stationID: String { "ida.\(rawValue)" }

    var name: String {
        switch self {
        case .tallinn: "IDA Tallinn"
        case .helsinki: "IDA Helsinki"
        }
    }

    var shortName: String {
        switch self {
        case .tallinn: "TLN"
        case .helsinki: "HEL"
        }
    }

    var city: String {
        switch self {
        case .tallinn: "Tallinn"
        case .helsinki: "Helsinki"
        }
    }

    /// IDA is an Estonian station, but its second studio is not in Estonia —
    /// so the country belongs to the channel rather than to the station.
    var country: String {
        switch self {
        case .tallinn: "Estonia"
        case .helsinki: "Finland"
        }
    }

    /// "Helsinki, Finland"
    var location: String { "\(city), \(country)" }

    /// Published inside `/api/live`, but a station has to be listenable before
    /// the first poll lands — and still be listenable if the endpoint goes
    /// quiet. The address from `live` wins once it arrives.
    var fallbackStream: URL {
        switch self {
        case .tallinn: URL(string: "https://broadcast.idaidaida.net:8000/stream")!
        case .helsinki: URL(string: "https://broadcast.idaidaida.net:8030/stream")!
        }
    }

    static func named(_ slug: String?) -> IdaChannel? {
        guard let slug else { return nil }
        return IdaChannel(rawValue: slug.lowercased())
    }
}

nonisolated struct IdaShow: Identifiable, Hashable, Sendable {
    let slug: String
    let title: String
    let artist: String?
    let summary: String?
    let genres: [String]
    let imageURL: URL?
    let thumbnailURL: URL?
    let isArchived: Bool
    let channel: IdaChannel?

    var id: String { slug }

    var subtitle: String {
        [artist, channel?.city].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

nonisolated struct IdaEpisode: Identifiable, Hashable, Sendable {
    let slug: String
    let title: String
    let subtitle: String?
    let broadcastAt: Date?
    let endsAt: Date?
    /// IDA hosts no audio of its own; every recording lives on one of these.
    let mixcloudURL: URL?
    let soundcloudURL: URL?
    let imageURL: URL?
    let thumbnailURL: URL?
    let tracks: [String]
    let genres: [String]
    let showSlug: String?
    let showTitle: String?
    let showArtist: String?
    let channel: IdaChannel?
    /// IDA reruns a good deal, and says so.
    let isRepeat: Bool

    var id: String { slug }
    var mediaID: String { "ida.episode.\(slug)" }
    var isPlayable: Bool { soundcloudURL != nil || mixcloudURL != nil }

    /// The slot's own length. IDA schedules to the hour, so this is honest
    /// enough to show — and it is the only duration the station publishes.
    var duration: TimeInterval? {
        guard let broadcastAt, let endsAt, endsAt > broadcastAt else { return nil }
        return endsAt.timeIntervalSince(broadcastAt)
    }

    var broadcastLabel: String? {
        guard let broadcastAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: broadcastAt)
    }

    /// The episode title already ends in its own date — "USVA 02-09-2026" —
    /// so repeating the date under it would say the same thing twice.
    var listSubtitle: String {
        [subtitle, showArtist, channel?.city]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    func mediaItem() -> MediaItem? {
        // SoundCloud first: IDA publishes it for nearly every episode and its
        // widget seeks, where Mixcloud's will not. Whichever it also published
        // rides along, so an episode pulled from SoundCloud does not simply
        // fail.
        if let soundcloudURL {
            return item(
                url: soundcloudURL,
                embed: .soundcloud,
                alternate: mixcloudURL.map { ($0, EmbedProvider.mixcloud) }
            )
        }
        if let mixcloudURL {
            return item(url: mixcloudURL, embed: .mixcloud, alternate: nil)
        }
        return nil
    }

    private func item(
        url: URL,
        embed: EmbedProvider,
        alternate: (url: URL, embed: EmbedProvider)?
    ) -> MediaItem {
        MediaItem(
            id: mediaID,
            sourceID: IdaProvider.providerID,
            kind: .episode,
            title: title,
            subtitle: subtitle ?? showArtist ?? showTitle ?? broadcastLabel,
            detail: "IDA Radio",
            genres: genres,
            remoteArtworkURL: imageURL,
            playbackURL: url,
            duration: duration,
            embedProvider: embed,
            alternatePlaybackURL: alternate?.url,
            alternateEmbedProvider: alternate?.embed
        )
    }
}

/// A slot on the calendar. IDA's schedule is simply its episodes with their
/// broadcast times, so this is an episode plus the channel it goes out on.
nonisolated struct IdaScheduleEntry: Identifiable, Hashable, Sendable {
    let episode: IdaEpisode
    let startsAt: Date
    let endsAt: Date

    var id: String { episode.slug }
    var channel: IdaChannel? { episode.channel }

    func contains(_ date: Date) -> Bool { startsAt <= date && date < endsAt }

    /// "18:00–20:00" in the listener's local time.
    var slot: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: startsAt))–\(formatter.string(from: endsAt))"
    }
}

/// What is on one channel right now, and what follows it.
nonisolated struct IdaChannelState: Hashable, Sendable {
    var episode: IdaEpisode?
    var streamURL: URL?
    var nextTitle: String?
    var nextStartsAt: Date?

    static let idle = IdaChannelState()

    var isOnAir: Bool { episode != nil }

    func asRadioShow(city: String) -> RadioShow? {
        guard let episode else { return nil }
        return RadioShow(
            title: episode.title,
            host: episode.showArtist,
            summary: nil,
            location: city,
            genres: episode.genres,
            moods: [],
            artworkURL: episode.imageURL,
            startsAt: episode.broadcastAt,
            endsAt: episode.endsAt,
            detailID: episode.slug
        )
    }
}

nonisolated struct IdaLive: Sendable {
    var channels: [IdaChannel: IdaChannelState] = [:]
}

// MARK: - Mapping

extension IdaGenreDTO {
    func asGenre() -> IdaGenre? {
        let label = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return IdaGenre(id: slug ?? "\(id ?? 0)", name: label)
    }
}

extension IdaShowDTO {
    func asShow() -> IdaShow? {
        guard let identity = slug, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        return IdaShow(
            slug: identity,
            title: name,
            artist: IdaText.first(artist, alternativeArtistName),
            summary: IdaText.description(english: contentEng, estonian: contentEst, finnish: contentFin),
            genres: (genres ?? []).compactMap { $0.asGenre()?.name },
            imageURL: featuredImage?.fullURL,
            thumbnailURL: featuredImage?.url(atLeast: 400),
            isArchived: archived ?? false,
            channel: IdaChannel.named(channel?.slug)
        )
    }
}

extension IdaEpisodeDTO {
    func asEpisode() -> IdaEpisode? {
        guard let identity = slug, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // An episode inherits its show's picture when it has none of its own,
        // which is most of them — IDA art-directs the show, not the week.
        let art = featuredImage ?? show?.featuredImage

        return IdaEpisode(
            slug: identity,
            title: name,
            subtitle: IdaText.first(subtitle),
            broadcastAt: IdaTimestamp.parse(start),
            endsAt: IdaTimestamp.parse(end),
            mixcloudURL: IdaLink.mixcloud(mixcloud),
            soundcloudURL: IdaLink.soundcloud(soundcloud),
            imageURL: art?.fullURL,
            thumbnailURL: art?.url(atLeast: 400),
            tracks: IdaTracklist.parse(tracklist),
            genres: (genres ?? []).compactMap { $0.asGenre()?.name },
            showSlug: show?.slug,
            showTitle: show?.title.map(HTMLText.decode),
            showArtist: IdaText.first(show?.artist, show?.alternativeArtistName),
            channel: IdaChannel.named(channel?.slug),
            isRepeat: isRepeat ?? false
        )
    }

    func asScheduleEntry() -> IdaScheduleEntry? {
        guard let episode = asEpisode(),
              let from = episode.broadcastAt,
              let to = episode.endsAt,
              to > from
        else { return nil }
        return IdaScheduleEntry(episode: episode, startsAt: from, endsAt: to)
    }
}

extension IdaLiveDTO.Slot {
    /// The live slot is an episode wearing a different shape — same fields,
    /// minus the tracklist, plus the stream.
    func asEpisode() -> IdaEpisode? {
        IdaEpisodeDTO(
            id: id,
            title: title,
            slug: slug,
            subtitle: subtitle,
            isRepeat: isRepeat,
            start: start,
            end: end,
            mixcloud: nil,
            soundcloud: nil,
            tracklist: nil,
            show: show,
            genres: genres,
            channel: channel,
            featuredImage: featuredImage
        ).asEpisode()
    }

    var stream: URL? { streamSrc.flatMap { URL(string: $0) } }
}

extension IdaLiveDTO {
    func asLive() -> IdaLive {
        var live = IdaLive()
        live.channels[.tallinn] = Self.state(slot: tallinn, next: nextTallinn)
        live.channels[.helsinki] = Self.state(slot: helsinki, next: nextHelsinki)
        return live
    }

    private static func state(slot: Slot?, next: Upcoming?) -> IdaChannelState {
        IdaChannelState(
            episode: slot?.asEpisode(),
            streamURL: slot?.stream,
            nextTitle: next?.show?.title.map(HTMLText.decode)
                .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
            nextStartsAt: IdaTimestamp.parse(next?.start)
        )
    }
}

// MARK: - Helpers

nonisolated enum IdaTimestamp {
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

    /// What Strapi wants back in a date filter.
    static func format(_ date: Date) -> String {
        fractional.string(from: date)
    }
}

nonisolated enum IdaText {
    /// The first of these the station actually filled in.
    static func first(_ values: String?...) -> String? {
        for value in values {
            guard let value else { continue }
            let clean = HTMLText.decode(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        return nil
    }

    /// IDA writes a show up in Estonian, English and Finnish and fills in
    /// whichever it has. English reads for the most listeners, but a show with
    /// only an Estonian note has something to say and should say it rather
    /// than showing an empty panel.
    static func description(english: String?, estonian: String?, finnish: String?) -> String? {
        for value in [english, estonian, finnish] {
            guard let value else { continue }
            let clean = HTMLText.plainText(value)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let clean, !clean.isEmpty { return clean }
        }
        return nil
    }
}

nonisolated enum IdaTracklist {
    /// One track a paragraph, most written "Artist - Title [Label Year]".
    /// The separator is not consistent enough to split a line on, so each is
    /// kept as it was written.
    static func parse(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value
            .components(separatedBy: .newlines)
            .map { line -> String in
                var text = HTMLText.decode(line).trimmingCharacters(in: .whitespaces)
                while text.hasPrefix("-") || text.hasPrefix("•") || text.hasPrefix("–") {
                    text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                return text
            }
            .filter { !$0.isEmpty }
    }
}

nonisolated enum IdaLink {
    /// IDA stores a bare path rather than an address — "IDA_RAADIO/usva-020926/"
    /// — and a good many of them carry Estonian letters, which `URL(string:)`
    /// refuses outright. So the path is percent-encoded before it becomes one.
    static func mixcloud(_ path: String?) -> URL? {
        url(base: "https://www.mixcloud.com/", path: path)
    }

    static func soundcloud(_ path: String?) -> URL? {
        url(base: "https://soundcloud.com/", path: path)
    }

    private static func url(base: String, path: String?) -> URL? {
        guard let path else { return nil }
        var clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        // A handful of records were entered as full addresses.
        if clean.lowercased().hasPrefix("http") {
            return URL(string: clean) ?? URL(string: encode(clean))
        }
        while clean.hasPrefix("/") { clean = String(clean.dropFirst()) }
        guard !clean.isEmpty else { return nil }
        return URL(string: base + encode(clean))
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
