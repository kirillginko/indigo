//
//  NoodsModels.swift
//  Indigo
//
//  Wire format for Noods Radio. Their Kirby CMS serves a content
//  representation for every page — append `.json` to any route — so unlike
//  Kiosk there is no page to scrape, just a lot of small public endpoints.
//

import Foundation

// MARK: - Wire types

nonisolated struct NoodsPagination: Decodable, Sendable {
    let hasNextPage: Bool?
    let paginationUrl: String?

    var next: URL? {
        guard hasNextPage == true, let paginationUrl else { return nil }
        return URL(string: paginationUrl)
    }
}

/// The card shape, shared by every list on the site.
nonisolated struct NoodsShowDTO: Decodable, Sendable {
    /// "shows/skin-two-w-silver-25th-august-26".
    let id: String?
    let title: String?
    let artisttag: NoodsArtistTag?
    let date: String?
    let genretags: NoodsGenreList?
    let genretag: NoodsGenreList?
    let mixcloud: String?
    let soundcloud: String?
    let residentid: String?
    let artworkSm: String?
    let artworkMd: String?
    let srcset: String?
}

/// Genre lists arrive as a JSON array on some shows and as an object keyed
/// "1", "2", "3" on others — PHP serialises a non-sequential array that way,
/// and roughly half of Noods' catalogue is affected. Decoding one shape only
/// threw away every page that contained the other.
nonisolated struct NoodsGenreList: Decodable, Sendable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let array = try? container.decode([String].self) {
            values = array
        } else if let keyed = try? container.decode([String: String].self) {
            // Numeric keys carry the order, so they sort as numbers.
            values = keyed
                .sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
                .map(\.value)
        } else {
            values = []
        }
    }
}

/// `artisttag` is a string on a card and an array on a show page.
nonisolated struct NoodsArtistTag: Decodable, Sendable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            value = single.isEmpty ? nil : single
        } else if let many = try? container.decode([String].self) {
            let joined = many.filter { !$0.isEmpty }.joined(separator: ", ")
            value = joined.isEmpty ? nil : joined
        } else {
            value = nil
        }
    }
}

/// A rich-text field arrives as `{"html": "…"}` when it has content and as a
/// bare `""` when it doesn't. Expecting only the object shape threw away every
/// show with an empty description.
nonisolated struct NoodsHTML: Decodable, Sendable {
    let html: String?

    private enum CodingKeys: String, CodingKey { case html }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let value = try? container.decodeIfPresent(String.self, forKey: .html) {
            html = value
            return
        }
        let single = try? decoder.singleValueContainer()
        let bare = try? single?.decode(String.self)
        html = (bare?.isEmpty ?? true) ? nil : bare
    }
}

nonisolated struct NoodsFeedDTO: Decodable, Sendable {
    let title: String?
    let posts: [NoodsShowDTO]?
    let pagination: NoodsPagination?
}

/// `/shows.json` — the Discover landing page, which is two lists rather than
/// a feed.
nonisolated struct NoodsDiscoverDTO: Decodable, Sendable {
    let title: String?
    let featured: [NoodsShowDTO]?
    let latest: [NoodsShowDTO]?
}

nonisolated struct NoodsFilterDTO: Decodable, Sendable {
    let genres: [String]?
    let page: Int?
    let pages: Int?
    let totalShows: Int?
    let shows: [NoodsShowDTO]?

    private enum CodingKeys: String, CodingKey {
        case genres, page, pages, totalShows, shows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        genres = try? container.decode([String].self, forKey: .genres)
        page = try? container.decode(Int.self, forKey: .page)
        pages = try? container.decode(Int.self, forKey: .pages)
        // `page` and `pages` come back as numbers but `totalShows` as a
        // string, so this reads whichever the server felt like sending.
        if let number = try? container.decode(Int.self, forKey: .totalShows) {
            totalShows = number
        } else if let text = try? container.decode(String.self, forKey: .totalShows) {
            totalShows = Int(text)
        } else {
            totalShows = nil
        }
        // With no genre selected the endpoint answers with an array of ints
        // rather than cards, so this must not throw the whole page away.
        shows = (try? container.decode([NoodsShowDTO].self, forKey: .shows)) ?? []
    }
}

nonisolated struct NoodsGenreDTO: Decodable, Sendable {
    let parent: String?
    let name: String?
}

nonisolated struct NoodsResidentRefDTO: Decodable, Sendable {
    let id: String?
    let title: String?
    let image: String?
    let srcset: String?
    /// The A–Z bucket this resident sorts under.
    let needle: String?
}

nonisolated struct NoodsResidentsDTO: Decodable, Sendable {
    let promotedResidents: [NoodsResidentRefDTO]?
    /// Grouped A–Z; each group is a flat array.
    let children: [[NoodsResidentRefDTO]]?
    let unsorted: [NoodsResidentRefDTO]?
}

nonisolated struct NoodsResidentDTO: Decodable, Sendable {
    let id: String?
    let title: String?
    let scheduleString: String?
    let residenttime: String?
    let location: String?
    let ogimage: String?
    let ogdescription: String?
    let image: String?
    let posts: [NoodsShowDTO]?
    let pagination: NoodsPagination?
    let similarresidents: [NoodsResidentRefDTO]?
}

nonisolated struct NoodsCollectionDTO: Decodable, Sendable {
    let id: String?
    let title: String?
    let date: String?
    let featured: Bool?
    let excerpt: String?
    let collectionType: String?
    let artworkSm: String?
    let location: String?
    let shows: [NoodsShowDTO]?
}

nonisolated struct NoodsCollectionsDTO: Decodable, Sendable {
    /// Keyed by "collections/<slug>", so order comes from the values.
    let collections: [String: NoodsCollectionDTO]?
}

nonisolated struct NoodsShowDetailDTO: Decodable, Sendable {
    let id: String?
    let title: String?
    let date: String?
    let artisttag: NoodsArtistTag?
    let description: NoodsHTML?
    let genretags: NoodsGenreList?
    let tracklist: NoodsHTML?
    let guestmix: Bool?
    let mixcloud: String?
    let soundcloud: String?
    let artworkMd: String?
    let ogimage: String?
    let residentId: String?
    let similarshows: [NoodsShowDTO]?
}

// MARK: - Domain types

nonisolated struct NoodsShow: Identifiable, Hashable, Sendable {
    /// "shows/<slug>".
    let path: String
    let title: String
    let artist: String?
    let airedAt: Date?
    let rawDate: String?
    let genres: [String]
    let artworkURL: URL?
    let soundcloud: URL?
    let mixcloud: URL?
    let residentPath: String?

    var id: String { path }
    var slug: String { NoodsPath.slug(path) }

    var audio: KioskAudioSource? {
        if let soundcloud { return KioskAudioSource(provider: .soundcloud, url: soundcloud) }
        if let mixcloud { return KioskAudioSource(provider: .mixcloud, url: mixcloud) }
        return nil
    }

    var isPlayable: Bool { audio != nil }

    var airedLabel: String? {
        guard let airedAt else { return rawDate }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: airedAt)
    }

    var subtitle: String {
        [artist, airedLabel, genres.prefix(2).joined(separator: " · ")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var mediaID: String { "noods.show.\(slug)" }

    func mediaItem() -> MediaItem? {
        guard let audio else { return nil }
        return MediaItem(
            id: mediaID,
            sourceID: NoodsProvider.providerID,
            kind: .episode,
            title: title,
            subtitle: artist ?? airedLabel,
            detail: "Noods Radio",
            genres: genres,
            remoteArtworkURL: artworkURL,
            playbackURL: audio.url,
            embedProvider: audio.provider
        )
    }
}

nonisolated struct NoodsShowDetail: Sendable {
    let show: NoodsShow
    let summary: String?
    let tracklist: [String]
    let isGuestMix: Bool
    let similar: [NoodsShow]
}

nonisolated struct NoodsResidentRef: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let artworkURL: URL?
    let needle: String?
    var id: String { path }
}

nonisolated struct NoodsResident: Sendable {
    let path: String
    let name: String
    let schedule: String?
    let location: String?
    let about: String?
    let artworkURL: URL?
    let shows: [NoodsShow]
    let nextPage: URL?
    let similar: [NoodsResidentRef]
}

nonisolated struct NoodsCollection: Identifiable, Hashable, Sendable {
    let path: String
    let title: String
    let excerpt: String?
    let kind: String?
    let location: String?
    let airedAt: Date?
    let rawDate: String?
    let artworkURL: URL?
    let isFeatured: Bool
    let shows: [NoodsShow]

    var id: String { path }
    var slug: String { NoodsPath.slug(path) }
}

/// The filter vocabulary, grouped the way Noods groups it.
nonisolated struct NoodsGenreGroup: Identifiable, Hashable, Sendable {
    let name: String
    let genres: [String]
    var id: String { name }
}

// MARK: - Mapping

extension NoodsShowDTO {
    func asShow() -> NoodsShow? {
        guard let id, !id.isEmpty else { return nil }
        let name = HTMLText.decode(title ?? NoodsPath.slug(id)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        return NoodsShow(
            path: id,
            title: name,
            artist: artisttag?.value.map(HTMLText.decode),
            airedAt: NoodsDate.parse(date),
            rawDate: date,
            genres: NoodsGenres.clean((genretags ?? genretag)?.values),
            // Collections and older archive endpoints can omit artworkMd and
            // put the usable image in srcset. artworkSm may be only 25px.
            artworkURL: NoodsPath.url(artworkMd) ?? NoodsPath.largestSrcsetURL(srcset)
                ?? NoodsPath.url(artworkSm),
            soundcloud: KioskLink.permalink(soundcloud),
            mixcloud: KioskLink.permalink(mixcloud),
            residentPath: (residentid?.isEmpty == false) ? residentid : nil
        )
    }
}

extension NoodsResidentRefDTO {
    func asRef() -> NoodsResidentRef? {
        guard let id, !id.isEmpty else { return nil }
        let name = HTMLText.decode(title ?? NoodsPath.slug(id)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return NoodsResidentRef(
            path: id,
            name: name,
            artworkURL: NoodsPath.url(image) ?? NoodsPath.largestSrcsetURL(srcset),
            needle: needle
        )
    }
}

extension NoodsResidentDTO {
    func asResident(path: String) -> NoodsResident {
        NoodsResident(
            path: id ?? path,
            name: HTMLText.decode(title ?? NoodsPath.slug(path)),
            schedule: (scheduleString?.isEmpty == false ? scheduleString : residenttime).map(HTMLText.decode),
            location: location.flatMap { $0.isEmpty ? nil : HTMLText.decode($0) },
            about: ogdescription.flatMap { $0.isEmpty ? nil : HTMLText.decode($0) },
            artworkURL: NoodsPath.url(image ?? ogimage),
            shows: (posts ?? []).compactMap { $0.asShow() },
            nextPage: pagination?.next,
            similar: (similarresidents ?? []).compactMap { $0.asRef() }
        )
    }
}

extension NoodsCollectionDTO {
    func asCollection(path: String? = nil) -> NoodsCollection? {
        let identity = id ?? path
        guard let identity, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(title ?? NoodsPath.slug(identity)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        return NoodsCollection(
            path: identity,
            title: name,
            excerpt: excerpt.flatMap { $0.isEmpty ? nil : HTMLText.decode($0) },
            kind: collectionType.flatMap { $0.isEmpty ? nil : $0.capitalized },
            location: location.flatMap { $0.isEmpty ? nil : $0 },
            airedAt: NoodsDate.parse(date),
            rawDate: date,
            artworkURL: NoodsPath.collectionArtworkURL(artworkSm),
            isFeatured: featured ?? false,
            shows: (shows ?? []).compactMap { $0.asShow() }
        )
    }
}

extension NoodsShowDetailDTO {
    func asDetail(path: String) -> NoodsShowDetail? {
        let card = NoodsShowDTO(
            id: id ?? path, title: title, artisttag: artisttag, date: date,
            genretags: genretags, genretag: nil, mixcloud: mixcloud, soundcloud: soundcloud,
            residentid: residentId, artworkSm: nil, artworkMd: artworkMd ?? ogimage,
            srcset: nil
        )
        guard let show = card.asShow() else { return nil }
        return NoodsShowDetail(
            show: show,
            summary: NoodsMarkup.text(description?.html),
            tracklist: NoodsMarkup.lines(tracklist?.html),
            isGuestMix: guestmix ?? false,
            similar: (similarshows ?? []).compactMap { $0.asShow() }
        )
    }
}

// MARK: - Helpers

nonisolated enum NoodsPath {
    /// "shows/foo-bar" → "foo-bar".
    static func slug(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func url(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        return URL(string: value)
    }

    /// The collections JSON only advertises its 100px square thumbnail, while
    /// the public collection page serves a 900px rendition from the same
    /// Kirby media directory (for example `cover-100x100.jpg` alongside
    /// `cover-900x.jpg`). Use that page-sized rendition for Indigo's tiles.
    static func collectionArtworkURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        let upgraded = value.replacingOccurrences(
            of: #"-100x100(?=\.[^./?]+(?:\?|$))"#,
            with: "-900x",
            options: .regularExpression
        )
        return URL(string: upgraded)
    }

    /// Pick the largest advertised candidate. The first is often only 41px
    /// and is visibly blurred in a Retina artwork tile.
    static func largestSrcsetURL(_ srcset: String?) -> URL? {
        guard let srcset else { return nil }
        return srcset.split(separator: ",")
            .compactMap { candidate -> (URL, Int)? in
                let parts = candidate.split(whereSeparator: { $0.isWhitespace })
                guard let first = parts.first, let url = URL(string: String(first)) else { return nil }
                let descriptor = parts.dropFirst().first.map(String.init) ?? ""
                let width = Int(descriptor.trimmingCharacters(in: CharacterSet(charactersIn: "w"))) ?? 0
                return (url, width)
            }
            .max { $0.1 < $1.1 }?.0
    }
}

nonisolated enum NoodsGenres {
    /// Noods repeats tags — one show carried "Ambient" four times — and the
    /// order is meaningful, so this dedupes without sorting.
    static func clean(_ values: [String]?) -> [String] {
        var seen = Set<String>()
        return (values ?? [])
            .map { HTMLText.decode($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

nonisolated enum NoodsMarkup {
    /// Strips tags, keeping the text. Noods sends small fragments, so a real
    /// parser would be more machinery than the job needs.
    static func text(_ html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        let stripped = lines(html).joined(separator: "\n")
        return stripped.isEmpty ? nil : stripped
    }

    /// Splits a fragment into its visible lines. Tracklists arrive as one
    /// paragraph with `<br>` between entries.
    static func lines(_ html: String?) -> [String] {
        guard let html, !html.isEmpty else { return [] }
        var working = html
        for separator in ["<br />", "<br/>", "<br>", "</p>", "</li>", "</div>"] {
            working = working.replacingOccurrences(of: separator, with: "\n")
        }
        var output = ""
        var insideTag = false
        for character in working {
            if character == "<" { insideTag = true; continue }
            if character == ">" { insideTag = false; continue }
            if !insideTag { output.append(character) }
        }
        return HTMLText.decode(output)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Noods writes dates as three two-digit parts, and not always in the same
/// order: shows are day-first ("25.08.26"), collections month-first
/// ("04.30.26"). Whichever reading is a real date wins, day-first preferred.
nonisolated enum NoodsDate {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }

        let year = 2000 + parts[2]
        for (day, month) in [(parts[0], parts[1]), (parts[1], parts[0])] {
            guard (1...12).contains(month), (1...31).contains(day) else { continue }
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            if let date = Calendar(identifier: .gregorian).date(from: components) { return date }
        }
        return nil
    }
}
