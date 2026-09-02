//
//  RovrModels.swift
//  Indigo
//
//  Wire format for rovr.live plus the shapes the ROVR pages render.
//
//  ROVR runs on Strapi, open to read. The thing that shapes this provider is
//  what the station calls itself: the same programming goes out on twenty-one
//  streams at once, one per hour of UTC offset, so that a show scheduled for
//  the evening is the evening wherever you are. The listener's own offset
//  picks the stream, and the schedule is asked for in their own wall clock
//  rather than in the station's — because the station does not have one.
//
//  Alongside those run four mood channels, which are continuous rather than
//  scheduled and are the other half of what ROVR publishes.
//

import Foundation

// MARK: - Wire types

/// Strapi's media record. ROVR uploads large and derives the rest, so the
/// formats matter: a grid that used `url` would pull the original every time.
nonisolated struct RovrAssetDTO: Decodable, Sendable {
    let url: String?
    let formats: [String: Format]?

    nonisolated struct Format: Decodable, Sendable {
        let url: String?
        let width: Int?
    }

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

nonisolated struct RovrListResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    let data: [Item]
    let meta: Meta?

    nonisolated struct Meta: Decodable, Sendable {
        let pagination: Pagination?
        nonisolated struct Pagination: Decodable, Sendable {
            let page: Int?
            let pageSize: Int?
            let pageCount: Int?
            let total: Int?
        }
    }

    var total: Int? { meta?.pagination?.total }
    var pageCount: Int? { meta?.pagination?.pageCount }
}

nonisolated struct RovrSingleResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    let data: Item?
}

/// One of the timezone streams. `offset` is the hours from UTC it is shifted
/// to; the mood channels ride the same shape with no offset at all.
nonisolated struct RovrStreamDTO: Decodable, Sendable {
    let id: Int?
    let documentId: String?
    let name: String?
    let offset: Int?
    let hlsUrl: String?
    let icecastUrl: String?
}

nonisolated struct RovrMoodStreamDTO: Decodable, Sendable {
    let id: Int?
    let name: String?
    let hlsUrl: String?
    let icecastUrl: String?
    let mood: Mood?

    nonisolated struct Mood: Decodable, Sendable {
        let title: String?
        let squareImage: String?
        let order: String?
    }
}

nonisolated struct RovrTagDTO: Decodable, Sendable {
    let id: Int?
    let documentId: String?
    /// "FUZZ" — what the listener sees.
    let label: String?
    /// "grease" — what the archive endpoint filters on. They are not the same
    /// word, and filtering by the label returns nothing.
    let type: String?
    let description: String?
    let displayOrder: Int?
    let visible: Bool?
}

nonisolated struct RovrCuratorDTO: Decodable, Sendable {
    let id: Int?
    let documentId: String?
    let name: String?
    let about: String?
    let countryCode: String?
    let urlSlug: String?
    let visible: Bool?
    let isSubcurator: Bool?
    let photo: RovrAssetDTO?
    let appLargeImage: RovrAssetDTO?
    let webCuratorCatalog: RovrAssetDTO?
    let shareCover: RovrAssetDTO?
    let links: [Link]?
    let shows: [RovrShowDTO]?

    nonisolated struct Link: Decodable, Sendable {
        let id: Int?
        let link: String?
    }
}

nonisolated struct RovrShowDTO: Decodable, Sendable {
    let id: Int?
    let documentId: String?
    let title: String?
    let description: String?
    /// "monthly", "weekly" — how often it returns.
    let frequency: String?
    let active: Bool?
    let communityRadio: Bool?
    let radioImage: RovrAssetDTO?
    let appArchives: RovrAssetDTO?
    let shareCover: RovrAssetDTO?
    let curators: [RovrCuratorDTO]?
}

/// One archived broadcast.
nonisolated struct RovrBroadcastDTO: Decodable, Sendable {
    let id: Int?
    let documentId: String?
    let title: String?
    /// The public page, which is what the widget plays. It carries the secret
    /// token in its path, so the path must survive intact.
    let soundcloudPermalinkUrl: String?
    let soundcloudEmbedUrl: String?
    let scheduleDate: String?
    let releaseDate: String?
    let overwriteShowName: String?
    let overwriteShowDescription: String?
    let aiDescription: String?
    let showEpisodeNumber: Int?
    /// Seconds.
    let playlistProcessedAudioDuration: Double?
    let overwriteShowRadioImage: RovrAssetDTO?
    let overwriteShowScheduleImage: RovrAssetDTO?
    let playlistTags: [RovrTagDTO]?
    let show: RovrShowDTO?
    let curator: RovrCuratorDTO?
}

/// `/api/schedules/radio/public` — the slot covering a moment.
nonisolated struct RovrScheduleDTO: Decodable, Sendable {
    let id: Int?
    let documentId: String?
    /// "2026-09-02 10:00:00", in the wall clock the request asked in.
    let startTime: String?
    let endTime: String?
    let show: RovrShowDTO?
    let playlist: RovrBroadcastDTO?
}

// MARK: - Domain types

/// A channel the listener can tune to.
///
/// ROVR publishes two kinds and they behave differently: the scheduled radio,
/// which is one programme shifted across twenty-one timezone streams, and the
/// mood channels, which run continuously and have no schedule at all.
nonisolated enum RovrChannelKind: Hashable, Sendable {
    case radio
    case mood
}

nonisolated struct RovrChannel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let shortName: String
    let strapline: String
    let streamURL: URL
    let kind: RovrChannelKind
    let imageURL: URL?
    /// Hours from UTC, on the scheduled radio only.
    let offset: Int?

    /// The one station id the scheduled radio always answers to, whichever
    /// timezone stream is behind it. The crate and the player store this, and
    /// it must not change when the listener travels.
    static let radioID = "rovr.live"

    static func moodID(_ name: String) -> String { "rovr.mood.\(name.lowercased())" }
}

nonisolated struct RovrTag: Identifiable, Hashable, Sendable {
    /// The value the archive filters on.
    let type: String
    /// The word the listener sees.
    let label: String
    let summary: String?
    let order: Int

    var id: String { type }
}

nonisolated struct RovrCurator: Identifiable, Hashable, Sendable {
    let documentID: String
    let name: String
    let about: String?
    let countryCode: String?
    let slug: String?
    let imageURL: URL?
    let thumbnailURL: URL?
    let links: [MediaLink]
    let showTitles: [String]

    var id: String { documentID }

    /// "FRA" as a flag, which is the one thing a roster of two hundred and
    /// seventy-six names can say at a glance.
    var flag: String? {
        guard let code = countryCode, code.count == 3 else { return nil }
        return RovrCountry.flag(alpha3: code)
    }

    var subtitle: String {
        [flag, showTitles.first].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: "  ")
    }
}

nonisolated struct RovrShow: Identifiable, Hashable, Sendable {
    let documentID: String
    let title: String
    let summary: String?
    let frequency: String?
    let imageURL: URL?
    let thumbnailURL: URL?
    let curators: [String]
    let isCommunityRadio: Bool

    var id: String { documentID }

    var subtitle: String {
        [frequency?.capitalized, curators.first].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

nonisolated struct RovrBroadcast: Identifiable, Hashable, Sendable {
    let documentID: String
    let title: String
    let summary: String?
    let broadcastAt: Date?
    let duration: TimeInterval?
    let episodeNumber: Int?
    let permalink: URL?
    /// The widget target supplied by ROVR, including private-track access tokens.
    let embedURL: URL?
    let imageURL: URL?
    let thumbnailURL: URL?
    let tags: [String]
    let showID: String?
    let showTitle: String?
    let curatorID: String?
    let curatorName: String?

    var id: String { documentID }
    var mediaID: String { "rovr.broadcast.\(documentID)" }
    var isPlayable: Bool { playbackURL != nil }
    var playbackURL: URL? { embedURL ?? permalink }

    var broadcastLabel: String? {
        guard let broadcastAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: broadcastAt)
    }

    var listSubtitle: String {
        [curatorName ?? showTitle, broadcastLabel]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    func mediaItem() -> MediaItem? {
        guard let playbackURL else { return nil }
        return MediaItem(
            id: mediaID,
            sourceID: RovrProvider.providerID,
            kind: .episode,
            title: title,
            subtitle: curatorName ?? showTitle ?? broadcastLabel,
            detail: "ROVR",
            genres: tags,
            remoteArtworkURL: imageURL,
            playbackURL: playbackURL,
            duration: duration,
            embedProvider: .soundcloud
        )
    }
}

/// What the schedule says is on the air.
nonisolated struct RovrOnAir: Hashable, Sendable {
    var title: String?
    var summary: String?
    var startsAt: Date?
    var endsAt: Date?
    var showID: String?
    var curatorName: String?
    var imageURL: URL?
    /// The broadcast behind the slot, once it is archived — which is what
    /// makes "open this episode" possible from the live page.
    var broadcastID: String?

    static let idle = RovrOnAir()

    var isOnAir: Bool { title != nil }

    func asRadioShow() -> RadioShow? {
        guard let title else { return nil }
        return RadioShow(
            title: title,
            host: curatorName,
            summary: summary,
            location: nil,
            genres: [],
            moods: [],
            artworkURL: imageURL,
            startsAt: startsAt,
            endsAt: endsAt,
            detailID: broadcastID
        )
    }
}

// MARK: - Mapping

extension RovrTagDTO {
    func asTag() -> RovrTag? {
        guard visible ?? true else { return nil }
        let name = HTMLText.decode(label ?? "").trimmingCharacters(in: .whitespaces)
        let value = type?.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let value, !value.isEmpty else { return nil }
        return RovrTag(
            type: value,
            label: name,
            summary: description.flatMap(HTMLText.plainText)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            order: displayOrder ?? .max
        )
    }
}

extension RovrCuratorDTO {
    func asCurator() -> RovrCurator? {
        guard let identity = documentId, !identity.isEmpty else { return nil }
        let label = HTMLText.decode(name ?? "").trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }

        let art = photo ?? appLargeImage ?? webCuratorCatalog ?? shareCover

        // Some curators write their whole biography as a run of addresses.
        // Those are links, not prose, and belong in the chips rather than in
        // a paragraph that reads as a wall of URLs.
        let prose = about.flatMap(HTMLText.plainText)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fromLinks = RovrLink.addresses(in: about ?? "")

        var seen = Set<String>()
        let chips = ((links ?? []).compactMap(\.link) + fromLinks)
            .compactMap { address -> MediaLink? in
                guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
                      let host = url.host?.lowercased()
                else { return nil }
                guard seen.insert(host.replacingOccurrences(of: "www.", with: "")).inserted
                else { return nil }
                return MediaLink(label: MediaLink.label(for: url), url: url)
            }

        return RovrCurator(
            documentID: identity,
            name: label,
            about: RovrLink.strippingAddresses(prose)?.nilIfEmpty,
            countryCode: countryCode?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            slug: urlSlug?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            imageURL: art?.fullURL,
            thumbnailURL: art?.url(atLeast: 400),
            links: chips,
            showTitles: (shows ?? []).compactMap {
                $0.title.map(HTMLText.decode)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            }
        )
    }
}

extension RovrShowDTO {
    func asShow() -> RovrShow? {
        guard let identity = documentId, !identity.isEmpty else { return nil }
        let label = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }

        let art = radioImage ?? appArchives ?? shareCover

        return RovrShow(
            documentID: identity,
            title: label,
            summary: description.flatMap(HTMLText.plainText)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            frequency: frequency?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            imageURL: art?.fullURL,
            thumbnailURL: art?.url(atLeast: 400),
            curators: (curators ?? []).compactMap {
                $0.name.map(HTMLText.decode)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            },
            isCommunityRadio: communityRadio ?? false
        )
    }
}

extension RovrBroadcastDTO {
    func asBroadcast() -> RovrBroadcast? {
        guard let identity = documentId, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(
            overwriteShowName?.nilIfEmpty ?? title ?? ""
        ).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // The broadcast's own picture when it was given one, and the show's
        // otherwise — which is the usual case.
        let art = overwriteShowRadioImage
            ?? overwriteShowScheduleImage
            ?? show?.radioImage
            ?? show?.appArchives

        let prose = [overwriteShowDescription, aiDescription, show?.description]
            .compactMap { $0?.nilIfEmpty }
            .first

        return RovrBroadcast(
            documentID: identity,
            title: name,
            summary: prose.flatMap(HTMLText.plainText)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            broadcastAt: RovrTimestamp.parseISO(releaseDate ?? scheduleDate),
            duration: playlistProcessedAudioDuration.flatMap { $0 > 0 ? $0 : nil },
            episodeNumber: showEpisodeNumber,
            permalink: RovrLink.soundcloud(soundcloudPermalinkUrl),
            embedURL: RovrLink.soundcloud(soundcloudEmbedUrl),
            imageURL: art?.fullURL,
            thumbnailURL: art?.url(atLeast: 400),
            tags: (playlistTags ?? []).compactMap { $0.asTag()?.label },
            showID: show?.documentId,
            showTitle: show?.title.map(HTMLText.decode)?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty,
            curatorID: curator?.documentId,
            curatorName: curator?.name.map(HTMLText.decode)?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty
        )
    }
}

extension RovrScheduleDTO {
    /// The slot as the live page shows it. Times come back in the same wall
    /// clock the request asked in, which is the listener's own.
    func asOnAir() -> RovrOnAir {
        let broadcast = playlist?.asBroadcast()
        let showTitle = show?.title.map(HTMLText.decode)?
            .trimmingCharacters(in: .whitespaces).nilIfEmpty

        return RovrOnAir(
            title: showTitle ?? broadcast?.title,
            summary: show?.description.flatMap(HTMLText.plainText)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? broadcast?.summary,
            startsAt: RovrTimestamp.parseWallClock(startTime),
            endsAt: RovrTimestamp.parseWallClock(endTime),
            showID: show?.documentId ?? broadcast?.showID,
            curatorName: broadcast?.curatorName,
            imageURL: broadcast?.imageURL
                ?? (show?.radioImage ?? show?.appArchives)?.fullURL,
            broadcastID: broadcast?.documentID
        )
    }
}

// MARK: - Helpers

nonisolated enum RovrTimestamp {
    static func parseISO(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? plain.date(from: value)
    }

    /// "2026-09-02 10:00:00" with no zone on it, because there is not one to
    /// put there: the schedule is expressed in whatever wall clock it was
    /// asked in, and here that is the listener's.
    static func parseWallClock(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    /// The same shape, going out.
    static func wallClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

nonisolated enum RovrLink {
    /// Remove share tracking while preserving private-track tokens in either
    /// the permalink path or the embed URL’s secret_token query parameter.
    static func soundcloud(_ value: String?) -> URL? {
        guard let value, !value.isEmpty,
              var components = URLComponents(string: value.trimmingCharacters(in: .whitespaces)),
              components.host != nil
        else { return nil }
        components.queryItems = components.queryItems?.filter {
            !$0.name.lowercased().hasPrefix("utm_")
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        components.fragment = nil
        return components.url
    }

    private static let detector = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"]+"#, options: []
    )

    /// Addresses written into a paragraph of prose.
    static func addresses(in text: String) -> [String] {
        guard let detector else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let found = Range(match.range, in: text) else { return nil }
            return String(text[found]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);"))
        }
    }

    /// The same prose with those addresses taken out, so a biography that is
    /// nothing but links becomes an empty summary rather than a wall of them.
    static func strippingAddresses(_ text: String?) -> String? {
        guard let text else { return nil }
        guard let detector else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let stripped = detector.stringByReplacingMatches(
            in: text, range: range, withTemplate: ""
        )
        return stripped
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum RovrCountry {
    /// ROVR files a curator's country as ISO alpha-3; a flag needs alpha-2.
    /// Only the codes that actually appear on the roster are worth carrying,
    /// and anything unmapped simply shows no flag rather than a wrong one.
    private static let alpha2: [String: String] = [
        "ARG": "AR", "AUS": "AU", "AUT": "AT", "BEL": "BE", "BRA": "BR", "CAN": "CA",
        "CHE": "CH", "CHL": "CL", "CHN": "CN", "COL": "CO", "CZE": "CZ", "DEU": "DE",
        "DNK": "DK", "ESP": "ES", "EST": "EE", "FIN": "FI", "FRA": "FR", "GBR": "GB",
        "GRC": "GR", "HKG": "HK", "HRV": "HR", "HUN": "HU", "IDN": "ID", "IND": "IN",
        "IRL": "IE", "ISL": "IS", "ISR": "IL", "ITA": "IT", "JPN": "JP", "KEN": "KE",
        "KOR": "KR", "LTU": "LT", "LUX": "LU", "LVA": "LV", "MAR": "MA", "MEX": "MX",
        "NGA": "NG", "NLD": "NL", "NOR": "NO", "NZL": "NZ", "PER": "PE", "POL": "PL",
        "PRT": "PT", "ROU": "RO", "RUS": "RU", "SRB": "RS", "SVK": "SK", "SVN": "SI",
        "SWE": "SE", "THA": "TH", "TUR": "TR", "TWN": "TW", "UKR": "UA", "URY": "UY",
        "USA": "US", "VNM": "VN", "ZAF": "ZA"
    ]

    static func flag(alpha3: String) -> String? {
        guard let code = alpha2[alpha3.uppercased()] else { return nil }
        let base: UInt32 = 127_397
        var flag = ""
        for scalar in code.unicodeScalars {
            guard let composed = Unicode.Scalar(base + scalar.value) else { return nil }
            flag.unicodeScalars.append(composed)
        }
        return flag
    }
}
