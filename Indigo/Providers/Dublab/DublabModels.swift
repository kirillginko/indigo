//
//  DublabModels.swift
//  Indigo
//
//  Wire format for dublab.com plus the shapes the dublab pages render.
//
//  dublab is a WordPress site behind a Vue front end, and its "lazystate" API
//  answers every route with one flat map of path → entry: the page you asked
//  for, plus every entry that page links to. So one request is a page and its
//  contents, and the same `Entry` shape covers a broadcast, a DJ, a show and a
//  calendar slot — which is why nearly every field here is optional.
//

import Foundation

// MARK: - Wire types

/// WordPress hands back `[]` for an empty map as readily as `{}`, so both the
/// keyed and the empty-array form have to decode or a page with no images
/// takes the whole response down with it.
nonisolated struct DublabMap<Value: Decodable & Sendable>: Decodable, Sendable {
    let values: [String: Value]

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let empty = try? container.decode([String].self), empty.isEmpty {
            values = [:]
            return
        }
        values = (try? decoder.singleValueContainer().decode([String: Value].self)) ?? [:]
    }

    subscript(_ key: String) -> Value? { values[key] }
}

/// WordPress writes `false` where a field has no value, so "this broadcast
/// has no parent show" and "this broadcast has one" arrive as different JSON
/// types in the same field. Anything that isn't the shape asked for decodes
/// as nothing rather than taking the page down.
nonisolated struct DublabFalsy<Wrapped: Decodable & Sendable>: Decodable, Sendable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.singleValueContainer() else {
            value = nil
            return
        }
        value = try? container.decode(Wrapped.self)
    }
}

nonisolated struct DublabFileDTO: Decodable, Sendable {
    let ID: Int?
    let url: String?
    let width: Int?
    let height: Int?
    let sizes: [String: String]?

    /// Large enough for a detail hero, small enough not to pull a 2560px scan
    /// into a grid tile.
    var bestURL: String? {
        sizes?["large"] ?? sizes?["medium_large"] ?? url
    }
}

/// A raw WordPress post, as the API embeds it for a broadcast's show and DJ.
nonisolated struct DublabPostDTO: Decodable, Sendable {
    let ID: Int?
    let post_title: String?
    let post_name: String?
    let post_content: String?
    let post_excerpt: String?
}

nonisolated struct DublabTagDTO: Decodable, Sendable {
    let name: String?
    let slug: String?
}

/// A `{title, url}` pair — how the API links a DJ to their shows and back.
nonisolated struct DublabLinkDTO: Decodable, Sendable {
    let title: String?
    let url: String?
}

nonisolated struct DublabAudioDTO: Decodable, Sendable {
    let title: String?
    let url: String?

    /// Some entries carry `false` here rather than omitting the key.
    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), (try? container.decode(Bool.self)) != nil {
            title = nil
            url = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        url = try container.decodeIfPresent(String.self, forKey: .url)
    }

    private enum CodingKeys: String, CodingKey { case title, url }
}

nonisolated struct DublabMetaDTO: Decodable, Sendable {
    let description: String?
    let image: String?
}

/// One entry in the lazystate map. Which fields are populated depends on
/// `template` — "broadcast", "dj", "show", "event" — and on whether the entry
/// was the page requested or merely linked from it.
nonisolated struct DublabEntryDTO: Decodable, Sendable {
    let url: String?
    let title: String?
    let slug: String?
    let template: String?
    let content: String?
    let meta: DublabMetaDTO?
    let files: DublabMap<DublabFileDTO>?
    let thumbnail: DublabFalsy<Int>?
    let tags: DublabFalsy<[DublabTagDTO]>?

    // Listing pages
    let pages: [String]?
    let page: Int?
    let numpages: Int?
    let total: Int?

    // Broadcasts
    let audio: DublabAudioDTO?
    let broadcast_date: String?
    let artists: DublabFalsy<[String]>?
    let artist_slugs: DublabFalsy<[String]>?
    let show: DublabFalsy<DublabPostDTO>?
    let show_performer: DublabFalsy<[DublabPostDTO]>?
    let guest_session: Bool?
    let links: DublabFalsy<[DublabLinkDTO]>?

    // DJs and shows
    let is_active: Bool?
    let shows: DublabFalsy<[DublabLinkDTO]>?
    let djs: DublabFalsy<[DublabLinkDTO]>?
    /// "4th Wednesdays<br />6 - 8 pm" — hand-written, so it arrives as markup.
    let schedule: String?

    // Calendar slots
    let event_start_date: String?
    let event_start_time: String?
    let event_end_date: String?
    let event_end_time: String?

    var artworkURL: URL? {
        if let thumbnail = thumbnail?.value, let file = files?["\(thumbnail)"], let best = file.bestURL {
            return URL(string: best)
        }
        if let first = files?.values.values.first?.bestURL { return URL(string: first) }
        return meta?.image.flatMap { URL(string: $0) }
    }
}

// MARK: - Airtime

// MARK: - Domain types

nonisolated struct DublabGenre: Identifiable, Hashable, Sendable {
    let name: String
    let slug: String
    var id: String { slug }
}

nonisolated struct DublabBroadcast: Identifiable, Hashable, Sendable {
    /// "gay-felony-connector-08-19-26" — the last path component of its page.
    let slug: String
    let title: String
    let airedAt: Date?
    let artworkURL: URL?
    /// A direct MP3, so a broadcast plays and seeks like a file.
    let audioURL: URL?
    let genres: [DublabGenre]
    let artists: [String]
    let artistSlugs: [String]
    /// The recurring programme this was an episode of.
    let showName: String?
    let showSlug: String?
    let showSummary: String?
    /// Who was behind the desk, and what dublab says about them.
    let performer: String?
    let performerSummary: String?
    let isGuestSession: Bool
    let links: [MediaLink]

    var id: String { slug }
    var mediaID: String { "dublab.broadcast.\(slug)" }
    var isPlayable: Bool { audioURL != nil }
    var genreNames: [String] { genres.map(\.name) }

    var airedLabel: String? {
        guard let airedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: airedAt)
    }

    var subtitle: String {
        [airedLabel, showName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    func mediaItem() -> MediaItem? {
        guard let audioURL else { return nil }
        return MediaItem(
            id: mediaID,
            sourceID: DublabProvider.providerID,
            kind: .episode,
            title: title,
            subtitle: showName ?? airedLabel,
            detail: "dublab",
            genres: genreNames,
            remoteArtworkURL: artworkURL,
            playbackURL: audioURL
        )
    }
}

nonisolated struct DublabDJ: Identifiable, Hashable, Sendable {
    let slug: String
    let name: String
    let artworkURL: URL?
    let isActive: Bool
    /// Only present once the DJ's own page has been read.
    let biography: String?
    let shows: [DublabShowRef]

    var id: String { slug }
}

nonisolated struct DublabShowRef: Identifiable, Hashable, Sendable {
    let title: String
    /// "safe-in-sound", from the `/shows/…` link.
    let slug: String
    var id: String { slug }
}

/// One slot on dublab's published programme calendar.
nonisolated struct DublabScheduleEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String?
    let artworkURL: URL?
    let startsAt: Date
    let endsAt: Date

    func contains(_ date: Date) -> Bool { startsAt <= date && date < endsAt }

    /// "18:00–20:00" in the listener's local time.
    var slot: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: startsAt))–\(formatter.string(from: endsAt))"
    }
}

/// What Airtime says is on the air this moment.
nonisolated struct DublabOnAir: Sendable {
    let showName: String?
    let showStartsAt: Date?
    let showEndsAt: Date?
    /// The file playing inside the show — usually the broadcast itself.
    let trackTitle: String?
    let trackArtist: String?
    let upNext: [DublabScheduleEntry]

    var elapsedFraction: Double? {
        guard let showStartsAt, let showEndsAt, showEndsAt > showStartsAt else { return nil }
        let total = showEndsAt.timeIntervalSince(showStartsAt)
        let done = Date.now.timeIntervalSince(showStartsAt)
        return min(1, max(0, done / total))
    }

    /// "18:00–20:00" in the listener's local time.
    var slot: String? {
        guard let showStartsAt, let showEndsAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: showStartsAt))–\(formatter.string(from: showEndsAt))"
    }

    func asRadioShow(artworkURL: URL? = nil) -> RadioShow {
        RadioShow(
            title: showName ?? trackTitle ?? "dublab",
            host: trackArtist,
            summary: nil,
            location: "Los Angeles",
            genres: [],
            moods: [],
            artworkURL: artworkURL,
            startsAt: showStartsAt,
            endsAt: showEndsAt,
            detailID: nil
        )
    }
}

// MARK: - Mapping

extension DublabEntryDTO {
    func asBroadcast() -> DublabBroadcast? {
        let identity = slug ?? url.map { String($0.split(separator: "/").last ?? "") }
        guard let identity, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let performer = show_performer?.value?.first
        return DublabBroadcast(
            slug: identity,
            title: name,
            airedAt: DublabTimestamp.parseBroadcastDate(broadcast_date),
            artworkURL: artworkURL,
            audioURL: audio?.url.flatMap { URL(string: $0) },
            genres: (tags?.value ?? []).compactMap { tag in
                let label = HTMLText.decode(tag.name ?? "").trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty else { return nil }
                return DublabGenre(name: label, slug: tag.slug ?? label.lowercased())
            },
            artists: (artists?.value ?? []).map(HTMLText.decode),
            artistSlugs: artist_slugs?.value ?? [],
            showName: show?.value?.post_title.map(HTMLText.decode),
            showSlug: show?.value?.post_name,
            showSummary: show?.value?.post_content.flatMap(HTMLText.plainText),
            performer: performer?.post_title.map(HTMLText.decode),
            performerSummary: performer?.post_content.flatMap(HTMLText.plainText),
            isGuestSession: guest_session ?? false,
            links: (links?.value ?? []).compactMap { link in
                guard let address = link.url, let resolved = URL(string: address), resolved.host != nil
                else { return nil }
                let label = HTMLText.decode(link.title ?? "").trimmingCharacters(in: .whitespaces)
                return MediaLink(label: label.isEmpty ? (resolved.host ?? "Link") : label, url: resolved)
            }
        )
    }

    func asDJ() -> DublabDJ? {
        let identity = slug ?? url.map { String($0.split(separator: "/").last ?? "") }
        guard let identity, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        return DublabDJ(
            slug: identity,
            name: name,
            artworkURL: artworkURL,
            isActive: is_active ?? true,
            biography: content.flatMap(HTMLText.plainText),
            shows: (shows?.value ?? []).compactMap { link in
                let label = HTMLText.decode(link.title ?? "").trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty, let path = link.url else { return nil }
                return DublabShowRef(title: label, slug: String(path.split(separator: "/").last ?? ""))
            }
        )
    }

    /// A calendar slot. dublab writes these in its own wall clock, so the zone
    /// has to be supplied from the station rather than assumed to be ours.
    func asScheduleEntry(zone: TimeZone) -> DublabScheduleEntry? {
        guard let start = DublabTimestamp.parse(date: event_start_date, time: event_start_time, zone: zone),
              let end = DublabTimestamp.parse(date: event_end_date, time: event_end_time, zone: zone),
              end > start
        else { return nil }
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        return DublabScheduleEntry(
            id: url ?? "\(name)|\(start.timeIntervalSince1970)",
            title: name,
            summary: content.flatMap(HTMLText.plainText),
            artworkURL: artworkURL,
            startsAt: start,
            endsAt: end
        )
    }
}

// MARK: - Helpers

nonisolated enum DublabTimestamp {
    /// The calendar writes its times the same way Airtime does.
    static func parse(_ value: String?, zone: TimeZone) -> Date? {
        AirtimeTimestamp.parse(value, zone: zone)
    }

    static func parse(date: String?, time: String?, zone: TimeZone) -> Date? {
        guard let date, !date.isEmpty else { return nil }
        return parse("\(date) \(time ?? "00:00:00")", zone: zone)
    }

    /// Broadcasts are stamped "20260819" — a date, no time and no zone.
    static func parseBroadcastDate(_ value: String?) -> Date? {
        guard let value, value.count == 8 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: value)
    }
}
