//
//  BandcampModels.swift
//  Indigo
//
//  Bandcamp has no public API, and its robots.txt is explicit about it:
//  `/api/` and `/search` are disallowed to everybody. So Indigo does not
//  search Bandcamp and does not touch its internal endpoints.
//
//  What it does instead is read the schema.org JSON-LD that Bandcamp itself
//  publishes on release pages — the same structured description it puts there
//  for search engines, on pages its robots.txt invites crawlers to and lists
//  in its own sitemap. And it only ever reads a page whose address came from
//  somewhere sanctioned: the artist's own Discogs or MusicBrainz entry, or a
//  link the listener followed.
//
//  This matters beyond politeness. A great deal of underground music is on
//  Bandcamp and nowhere else — no MusicBrainz release, no Discogs pressing —
//  which is precisely the music this app exists to follow. Being Bandcamp-only
//  is itself one of the deepness signals.
//

import Foundation
import SwiftData

// MARK: - What Bandcamp publishes

/// The subset of schema.org `MusicAlbum` that Bandcamp fills in.
nonisolated struct BandcampAlbumLD: Decodable, Sendable {
    let name: String?
    let datePublished: String?
    let image: FlexibleImage?
    let byArtist: NamedEntity?
    let publisher: NamedEntity?
    let keywords: [String]?
    let track: TrackList?
    let numTracks: Int?

    nonisolated struct NamedEntity: Decodable, Sendable {
        let name: String?
    }

    nonisolated struct TrackList: Decodable, Sendable {
        let itemListElement: [Element]?

        nonisolated struct Element: Decodable, Sendable {
            let position: Int?
            let item: Item?

            nonisolated struct Item: Decodable, Sendable {
                let name: String?
                let duration: String?
            }
        }
    }

    /// `image` is a string on most pages and an array on some.
    nonisolated enum FlexibleImage: Decodable, Sendable {
        case one(String)
        case many([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) { self = .one(single); return }
            self = .many((try? container.decode([String].self)) ?? [])
        }

        var first: String? {
            switch self {
            case .one(let value): value
            case .many(let values): values.first
            }
        }
    }

    func asRelease(url: URL) -> BandcampReleaseInfo? {
        guard let name, !name.isEmpty else { return nil }
        let titles = (track?.itemListElement ?? [])
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
            .compactMap { $0.item?.name }
            .filter { !$0.isEmpty }
        return BandcampReleaseInfo(
            url: url,
            title: name,
            artistName: byArtist?.name ?? "",
            labelName: publisher?.name,
            year: BandcampDate.year(datePublished),
            imageURL: image?.first.flatMap { URL(string: $0) },
            trackTitles: titles,
            keywords: (keywords ?? []).filter { !$0.isEmpty }
        )
    }
}

nonisolated struct BandcampReleaseInfo: Sendable {
    let url: URL
    let title: String
    let artistName: String
    let labelName: String?
    let year: String?
    let imageURL: URL?
    let trackTitles: [String]
    /// Bandcamp's own tags. Genre and city sit in the same list — "Electronic",
    /// "Manchester" — which is most of what SCENE needs.
    let keywords: [String]
}

nonisolated enum BandcampDate {
    /// "27 Aug 2021 00:00:00 GMT" → "2021".
    static func year(_ value: String?) -> String? {
        guard let value else { return nil }
        let digits = value.split(separator: " ").first { $0.count == 4 && $0.allSatisfy(\.isNumber) }
        return digits.map { String($0) }
    }
}

// MARK: - Cache

/// A Bandcamp release, kept so the same page is never asked for twice and so
/// DIG stays navigable offline.
@Model
nonisolated final class BandcampRelease {
    @Attribute(.unique) var urlString: String
    var title: String
    var artistName: String
    /// Normalised, so a release can be found from a credit spelled differently.
    var artistKey: String
    /// Everyone named in the credit. A collaboration belongs on both artists'
    /// pages, not only the one whose name came first.
    var artistKeys: [String] = []
    var labelName: String?
    var year: String?
    var imageURLString: String?
    var embedURLString: String?
    var trackTitles: [String]
    /// Normalised track titles, so "MLN ft. Tony Njoku" can be matched against
    /// what a radio station wrote down.
    var trackKeys: [String]
    var keywords: [String]
    var fetchedAt: Date

    init(
        urlString: String,
        title: String,
        artistName: String,
        labelName: String? = nil,
        year: String? = nil,
        imageURLString: String? = nil,
        embedURLString: String? = nil,
        trackTitles: [String] = [],
        keywords: [String] = []
    ) {
        self.urlString = urlString
        self.title = title
        self.artistName = artistName
        self.artistKey = RecordingKey.normalizeArtist(artistName)
        self.artistKeys = RecordingKey.creditedArtists(artistName)
        self.labelName = labelName
        self.year = year
        self.imageURLString = imageURLString
        self.embedURLString = embedURLString
        self.trackTitles = trackTitles
        self.trackKeys = trackTitles.map(RecordingKey.normalizeTitle)
        self.keywords = keywords
        self.fetchedAt = Date()
    }

    var url: URL? { URL(string: urlString) }
    var imageURL: URL? { imageURLString.flatMap(URL.init(string:)) }

    /// Bandcamp's own player for this record, if the page advertised one.
    var embedURL: URL? {
        guard let embedURLString, !embedURLString.isEmpty else { return nil }
        return URL(string: embedURLString)
    }

    /// Whether this release contains a track a station named. Matched on the
    /// normalised title, then on the title with the featured-artist tail off,
    /// because stations and Bandcamp disagree about that constantly.
    func contains(track title: String) -> Bool {
        let exact = RecordingKey.normalizeTitle(title)
        guard !exact.isEmpty else { return false }
        if trackKeys.contains(exact) { return true }
        let trimmed = RecordingKey.normalizeTitle(TrackCredit.searchTitle(title))
        guard !trimmed.isEmpty else { return false }
        return trackKeys.contains { $0 == trimmed || $0.hasPrefix(trimmed + " ") }
    }
}

/// What Indigo knows about an artist's Bandcamp, so the index page is fetched
/// once rather than on every lookup.
@Model
nonisolated final class BandcampArtistIndex {
    @Attribute(.unique) var artistKey: String
    var name: String
    var pageURLString: String
    var releaseURLStrings: [String]
    var fetchedAt: Date

    init(artistKey: String, name: String, pageURLString: String, releaseURLStrings: [String] = []) {
        self.artistKey = artistKey
        self.name = name
        self.pageURLString = pageURLString
        self.releaseURLStrings = releaseURLStrings
        self.fetchedAt = Date()
    }

    var isFresh: Bool { Date().timeIntervalSince(fetchedAt) < 7 * 24 * 60 * 60 }
}

/// Bandcamp serves the same artwork at several sizes, chosen by a number in
/// the filename.
///
/// The page advertises the largest — 1200 pixels, well over half a megabyte —
/// and that is what gets stored. Rendering it into a 148-point tile downloads
/// roughly twenty-seven times more than the tile can show, which is most of
/// why a grid of sleeves was slow to fill.
nonisolated enum BandcampImage {
    /// 210 pixels, about 23KB. Loads immediately and stands in while the
    /// proper one arrives.
    static let thumbnail = 9
    /// 700 pixels, about 160KB. Enough for any tile in the app.
    static let cover = 16

    static func sized(_ url: URL?, _ size: Int) -> URL? {
        guard let url, url.host()?.hasSuffix("bcbits.com") == true else { return url }
        let name = url.lastPathComponent
        guard let underscore = name.lastIndex(of: "_"),
              let dot = name.lastIndex(of: "."),
              underscore < dot,
              Int(name[name.index(after: underscore)..<dot]) != nil
        else { return url }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let stem = name[name.startIndex..<underscore]
        let ext = name[dot...]
        components?.path = url.deletingLastPathComponent().path() + "\(stem)_\(size)\(ext)"
        return components?.url ?? url
    }
}
