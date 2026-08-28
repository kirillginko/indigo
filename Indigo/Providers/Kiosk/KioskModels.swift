//
//  KioskModels.swift
//  Indigo
//
//  Wire format for kioskradio.com plus the shapes the Kiosk pages render.
//  Kiosk is a Contentful-backed Next.js site rather than a documented API, so
//  everything here comes from the endpoints its own front end calls.
//

import Foundation

// MARK: - Wire types

nonisolated struct KioskAsset: Decodable, Sendable {
    let url: String?
}

nonisolated struct KioskSys: Decodable, Sendable {
    let id: String?
}

nonisolated struct KioskGenreDTO: Decodable, Sendable {
    let name: String?
}

/// Contentful nulls out any link it can't resolve rather than omitting it, so
/// every collection can arrive with holes in it — an unpublished genre shows
/// up as a literal `null` inside `items`. Decoding those as the element type
/// throws and takes the whole page down with it.
nonisolated struct KioskCollection<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]

    private enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try container.decodeIfPresent([Item?].self, forKey: .items) ?? []).compactMap { $0 }
    }
}

nonisolated struct KioskEpisodeDTO: Decodable, Sendable {
    let sys: KioskSys?
    let title: String?
    let date: String?
    /// "/episode/2026-07-09/jo-g" — the only identifier present on every
    /// episode. Playlist entries arrive without `sys`.
    let slug: String?
    let linkSoundcloud: String?
    let linkMixcloud: String?
    let image: KioskAsset?
    let genresCollection: KioskCollection<KioskGenreDTO>?
}

nonisolated struct KioskShowDTO: Decodable, Sendable {
    let name: String?
    let photo: KioskAsset?
}

nonisolated struct KioskEpisodePageData: Decodable, Sendable {
    let props: Props
    struct Props: Decodable, Sendable { let pageProps: PageProps }
    struct PageProps: Decodable, Sendable { let episode: Episode }
    struct Episode: Decodable, Sendable {
        let title: String?
        let description: String?
        let date: String?
        let trackList: String?
        let linkSoundcloud: String?
        let linkMixcloud: String?
        let image: KioskAsset?
        let slug: String?
        let genresCollection: KioskCollection<KioskGenreDTO>?
        let show: ShowRef?
    }
    struct ShowRef: Decodable, Sendable {
        let name: String?
        let slug: String?
    }
}

nonisolated struct KioskShowPageData: Decodable, Sendable {
    let props: Props
    struct Props: Decodable, Sendable { let pageProps: PageProps }
    struct PageProps: Decodable, Sendable {
        let show: Show
        let episodes: [KioskEpisodeDTO]?
    }
    struct Show: Decodable, Sendable {
        let name: String?
        let excerpt: String?
        let when: String?
        let photo: KioskAsset?
        let genresCollection: KioskCollection<KioskGenreDTO>?
    }
}

/// `/api/search` answers with one collection per content type. An empty query
/// is legal and returns the most recent 100 episodes, which is what the
/// Library page browses.
nonisolated struct KioskSearchResponse: Decodable, Sendable {
    let episodeCollection: KioskCollection<KioskEpisodeDTO>?
    let showCollection: KioskCollection<KioskShowDTO>?
}

nonisolated struct KioskCalendarEntryDTO: Decodable, Sendable {
    let id: Int?
    let summary: String?
    let start: String?
    let end: String?
}

// MARK: - The Moods page payload

/// The playlists only exist inside the `/moods` page's `__NEXT_DATA__` blob —
/// there is no JSON endpoint for them. Sections are heterogeneous, so every
/// field here is optional and non-playlist sections simply decode to nil.
nonisolated struct KioskNextData: Decodable, Sendable {
    let props: Props

    nonisolated struct Props: Decodable, Sendable {
        let pageProps: PageProps
    }

    nonisolated struct PageProps: Decodable, Sendable {
        let page: Page
    }

    nonisolated struct Page: Decodable, Sendable {
        let sectionsCollection: KioskCollection<Section>?
    }

    nonisolated struct Section: Decodable, Sendable {
        let playlistsCollection: KioskCollection<KioskPlaylistDTO>?
    }

    /// Every playlist grid on the page, in document order.
    var playlists: [KioskPlaylistDTO] {
        (props.pageProps.page.sectionsCollection?.items ?? [])
            .flatMap { $0.playlistsCollection?.items ?? [] }
    }
}

nonisolated struct KioskPlaylistDTO: Decodable, Sendable {
    let sys: KioskSys?
    let title: String?
    let image: KioskAsset?
    let episodesCollection: KioskCollection<KioskEpisodeDTO>?
}

// MARK: - Domain types

/// Where an archived Kiosk show can actually be heard. Kiosk publishes to
/// SoundCloud and mirrors to Mixcloud; both have widgets Indigo can drive.
nonisolated struct KioskAudioSource: Hashable, Sendable {
    let provider: EmbedProvider
    let url: URL
}

nonisolated struct KioskEpisode: Identifiable, Hashable, Sendable {
    let slug: String
    let title: String
    let airedAt: Date?
    let artworkURL: URL?
    let genres: [String]
    let soundcloud: URL?
    let mixcloud: URL?

    var id: String { slug }

    /// The player's identity for this show. Kept separate from `mediaItem()`
    /// so a grid can ask "is this the loaded one?" without building one item
    /// per tile per render.
    var mediaID: String { "kiosk.episode.\(slug)" }

    /// SoundCloud first: it is what Kiosk publishes for nearly every show and
    /// its widget reports position and duration more reliably.
    var audio: KioskAudioSource? {
        if let soundcloud { return KioskAudioSource(provider: .soundcloud, url: soundcloud) }
        if let mixcloud { return KioskAudioSource(provider: .mixcloud, url: mixcloud) }
        return nil
    }

    var isPlayable: Bool { audio != nil }

    var airedLabel: String? {
        guard let airedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: airedAt)
    }

    var subtitle: String {
        [airedLabel, genres.prefix(2).joined(separator: " · ")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    func mediaItem() -> MediaItem? {
        guard let audio else { return nil }
        return MediaItem(
            id: mediaID,
            sourceID: KioskProvider.providerID,
            kind: .episode,
            title: title,
            subtitle: airedLabel,
            detail: "Kiosk Radio",
            genres: genres,
            remoteArtworkURL: artworkURL,
            playbackURL: audio.url,
            embedProvider: audio.provider
        )
    }
}

/// One of the hand-curated "Moods" playlists.
nonisolated struct KioskMood: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artworkURL: URL?
    let episodes: [KioskEpisode]

    var playableEpisodes: [KioskEpisode] { episodes.filter(\.isPlayable) }

    /// The queue this playlist becomes when you hit play.
    func mediaItems() -> [MediaItem] { episodes.compactMap { $0.mediaItem() } }
}

nonisolated struct KioskEpisodeDetail: Sendable {
    let episode: KioskEpisode
    let description: String?
    let tracklist: [String]
    let residencyName: String?
    let residencySummary: String?
    let residencySchedule: String?
    let related: [KioskEpisode]
}

extension KioskEpisodePageData.Episode {
    func asEpisode(fallbackSlug: String) -> KioskEpisode? {
        let identity = slug ?? fallbackSlug
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !identity.isEmpty, !name.isEmpty else { return nil }
        return KioskEpisode(
            slug: identity,
            title: name,
            airedAt: KioskTimestamp.parse(date),
            artworkURL: image?.url.flatMap(URL.init(string:)),
            genres: (genresCollection?.items ?? []).compactMap(\.name).map(HTMLText.decode),
            soundcloud: KioskLink.permalink(linkSoundcloud),
            mixcloud: KioskLink.permalink(linkMixcloud)
        )
    }
}

nonisolated struct KioskScheduleEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let startsAt: Date
    let endsAt: Date

    func contains(_ date: Date) -> Bool { startsAt <= date && date < endsAt }

    /// "18:00–20:00" in the listener's local time.
    var slot: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: startsAt))–\(formatter.string(from: endsAt))"
    }

    /// Kiosk bills guest slots as "Residency w/ Guest"; the residency alone is
    /// what the shows index is keyed by.
    var showName: String {
        guard let separator = title.range(of: " w/ ") else { return title }
        return String(title[title.startIndex..<separator.lowerBound])
            .trimmingCharacters(in: .whitespaces)
    }

    func asRadioShow(artworkURL: URL? = nil) -> RadioShow {
        RadioShow(
            title: title,
            host: nil,
            summary: nil,
            location: "Brussels",
            genres: [],
            moods: [],
            artworkURL: artworkURL,
            startsAt: startsAt,
            endsAt: endsAt,
            detailID: nil
        )
    }
}

// MARK: - Mapping

extension KioskEpisodeDTO {
    func asEpisode() -> KioskEpisode? {
        let identity = slug ?? sys?.id
        guard let identity, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        return KioskEpisode(
            slug: identity,
            title: name,
            airedAt: KioskTimestamp.parse(date),
            artworkURL: image?.url.flatMap { URL(string: $0) },
            genres: (genresCollection?.items ?? []).compactMap(\.name).map(HTMLText.decode),
            soundcloud: KioskLink.permalink(linkSoundcloud),
            mixcloud: KioskLink.permalink(linkMixcloud)
        )
    }
}

extension KioskPlaylistDTO {
    func asMood() -> KioskMood? {
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // A show can be filed into the same mood twice; identity is the slug.
        var seen = Set<String>()
        let episodes = (episodesCollection?.items ?? [])
            .compactMap { $0.asEpisode() }
            .filter { seen.insert($0.id).inserted }

        return KioskMood(
            id: sys?.id ?? name.lowercased(),
            title: name,
            artworkURL: image?.url.flatMap { URL(string: $0) },
            episodes: episodes
        )
    }
}

extension KioskCalendarEntryDTO {
    func asScheduleEntry() -> KioskScheduleEntry? {
        guard let start = KioskTimestamp.parse(start),
              let end = KioskTimestamp.parse(end),
              end > start
        else { return nil }
        let name = HTMLText.decode(summary ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return KioskScheduleEntry(
            id: "\(id ?? 0)|\(start.timeIntervalSince1970)",
            title: name,
            startsAt: start,
            endsAt: end
        )
    }
}

// MARK: - Helpers

/// Kiosk mixes two ISO 8601 flavours: Contentful stamps episodes with
/// fractional seconds and Zulu time, the calendar uses a Brussels offset.
nonisolated enum KioskTimestamp {
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

nonisolated enum KioskLink {
    /// Kiosk's links carry SoundCloud share tracking ("?utm_medium=api&…").
    /// The widget wants the bare permalink.
    static func permalink(_ value: String?) -> URL? {
        guard let value, !value.isEmpty,
              var components = URLComponents(string: value),
              components.host != nil
        else { return nil }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
