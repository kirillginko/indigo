//
//  DiscogsModels.swift
//  Indigo
//

import Foundation

/// How a record was issued, and the one question anything here asks of it.
///
/// Stated once because two kinds of row need the same answer and they arrive
/// by different routes: an entry in an artist's releases carries a format
/// string, and a release read in its own right carries a list of format
/// objects. Both are asking whether this is a film rather than a record —
/// which is what tells a video director from a group when Discogs files both
/// under one name, and why a film distributor was appearing among an artist's
/// labels.
nonisolated enum ReleaseFormat {
    private static let video = [
        "dvd", "vhs", "blu-ray", "bluray", "laserdisc", "video", "betamax", "vcd", "umd"
    ]

    static func isVideo(_ text: String?) -> Bool {
        guard let text else { return false }
        let value = text.lowercased()
        return video.contains { value.contains($0) }
    }

    static func isVideo(anyOf values: [String]) -> Bool {
        values.contains { isVideo($0) }
    }
}

/// One of a release's formats: "Vinyl", "DVD", "Cassette", with whatever
/// Discogs adds about it — "NTSC", "Promo", "Album".
nonisolated struct DiscogsFormat: Decodable, Sendable {
    let name: String?
    let descriptions: [String]?

    /// The format as one string, for storing and for asking about.
    var written: String {
        ([name] + (descriptions ?? []).map { Optional($0) })
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

nonisolated struct DiscogsSearchResponse: Decodable, Sendable {
    let results: [DiscogsSearchResult]?
}

nonisolated struct DiscogsSearchResult: Decodable, Sendable {
    let id: Int?
    let title: String
    let coverImage: String?
    let thumbnail: String?
    let genre: [String]?
    let style: [String]?
    let label: [String]?
    let year: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, genre, style, label, year
        case thumbnail = "thumb"
        case coverImage = "cover_image"
    }
}

nonisolated struct DiscogsRecommendationBundle: Sendable {
    let labelArtists: [DiscogsNeighbour]
    let styleArtists: [DiscogsNeighbour]
}

/// An artist reached through a shared label or style, and a picture of one of
/// their records.
///
/// The picture costs nothing: it arrives in the same search response the name
/// does, and was being discarded. It is a sleeve rather than a portrait —
/// which for a row that exists because you both put records out on the same
/// imprint is arguably the more useful image anyway.
nonisolated struct DiscogsNeighbour: Sendable, Hashable {
    let name: String
    let thumbnailURL: String?
}

nonisolated struct DiscogsArtistReference: Decodable, Sendable {
    let id: Int?
    let name: String?
}

nonisolated struct DiscogsLabelReference: Decodable, Sendable {
    let id: Int?
    let name: String?
    let catno: String?
}

nonisolated struct DiscogsImage: Decodable, Sendable {
    let type: String?
    let uri: String?
    let uri150: String?

    private enum CodingKeys: String, CodingKey {
        case type, uri
        case uri150 = "uri150"
    }
}

nonisolated struct DiscogsArtistDetail: Decodable, Sendable {
    let id: Int
    let name: String
    let realname: String?
    let profile: String?
    let uri: String?
    let images: [DiscogsImage]?
    let urls: [String]?
    let aliases: [DiscogsArtistReference]?
    let members: [DiscogsArtistReference]?
    let groups: [DiscogsArtistReference]?
}

nonisolated struct DiscogsArtistRelease: Decodable, Sendable {
    let id: Int?
    let title: String?
    let year: Int?
    let role: String?
    let type: String?
    let label: String?
    let artist: String?
    let mainRelease: Int?
    /// How it was issued: "12\", 33 ⅓ RPM, EP", "DVD, Album", "Cassette".
    let format: String?
    /// The sleeve, which this endpoint carries and nothing was reading.
    ///
    /// Sleeves used to come from the name search instead, and that search
    /// returns twenty-five hits for a name rather than an artist's catalogue —
    /// so once the discography stopped coming from it, most records had no
    /// picture at all. They are on the record's own row here.
    let thumbnail: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, year, role, type, label, artist, format
        case mainRelease = "main_release"
        case thumbnail = "thumb"
    }

    /// Whether this is a film rather than a record.
    ///
    /// The distinction earns its place twice over. It is what tells a video
    /// director from a group when Discogs files both under one name — his
    /// releases are videos and he is the main credit on them, so "has
    /// releases of their own" could not separate them. And it is why a page
    /// for Hype Williams listed Palm Pictures among his labels: a film
    /// distributor is not an imprint an artist releases on, it is who put out
    /// the DVD.
    ///
    /// A concert film by a musician is caught by this too, and that is the
    /// intended trade: this is an application about records.
    var isVideo: Bool { ReleaseFormat.isVideo(format) }

    /// The id that opens a page.
    ///
    /// A master's own id is not a release id, and asking `releases/{id}` for
    /// one answers about the wrong thing or not at all. Discogs names the
    /// pressing a master stands for in `main_release`, which is the one to
    /// follow.
    var catalogueID: Int? {
        type == "master" ? (mainRelease ?? id) : id
    }
}

nonisolated struct DiscogsArtistReleases: Decodable, Sendable {
    let releases: [DiscogsArtistRelease]?
}

/// One record in a label's own catalogue.
///
/// From `labels/{id}/releases`, which answers about a label by identity
/// rather than by name — the distinction the whole of `labelDiscogsIDs`
/// exists for. Shaped like an artist's releases and not like a search hit:
/// the artist is a field of its own here rather than glued to the front of
/// the title, and the catalogue number is given.
nonisolated struct DiscogsLabelRelease: Decodable, Sendable {
    let id: Int?
    let title: String?
    let artist: String?
    let year: Int?
    let catno: String?
    let format: String?
    let thumbnail: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, year, catno, format
        case thumbnail = "thumb"
    }
}

nonisolated struct DiscogsLabelReleases: Decodable, Sendable {
    let releases: [DiscogsLabelRelease]?
}

nonisolated struct DiscogsArtistBundle: Sendable {
    let detail: DiscogsArtistDetail
    let releases: DiscogsArtistReleases
    let searchImageURL: String?
    let searchThumbnailURL: String?
    let catalogue: [DiscogsSearchResult]
}

nonisolated struct DiscogsTrackLine: Decodable, Sendable {
    let position: String?
    let title: String?
    let duration: String?
    /// Set on compilations, where the release is credited to "Various" and
    /// each track names who is actually on it. That is the whole point of a
    /// compilation and was being thrown away.
    let artists: [DiscogsArtistReference]?

    /// Who is on this track, when the record itself is credited to nobody.
    ///
    /// Disambiguators removed for the same reason they are removed everywhere
    /// else a Discogs name reaches the app: "Hype Williams (2)" is Discogs'
    /// filing, and a track line naming it sends somebody to a page for a
    /// person who does not exist.
    var artistName: String? {
        let names = (artists ?? [])
            .compactMap(\.name)
            .map(DiscogsClient.withoutDisambiguator)
            .filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.joined(separator: " & ")
    }
}

/// A video Discogs' editors have attached to a release.
///
/// Curated rather than searched for: somebody who was cataloguing this exact
/// pressing linked this exact recording. That is a far better match than
/// asking a search engine for the track's name and hoping.
nonisolated struct DiscogsVideo: Decodable, Sendable {
    let uri: String?
    let title: String?
    let duration: Int?
}

/// Somebody credited on a record who is not one of its headline artists —
/// the producer, the engineer, whoever played the bass. Discogs writes the job
/// into `role`, several at a time and in its own casing; see `CreditRole`.
nonisolated struct DiscogsCredit: Decodable, Sendable {
    let id: Int?
    let name: String?
    /// The spelling this particular record used, when it differs. Discogs
    /// calls it "artist name variation".
    let anv: String?
    let role: String?
    /// Which tracks, when the credit is not for the whole record. Free text —
    /// "A1", "A1 to A4", "B2, B3" — and shown rather than parsed.
    let tracks: String?

    /// The name as this record spelled it, falling back to the canonical one.
    var credited: String? {
        let variation = anv?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let variation, !variation.isEmpty { return variation }
        return name
    }
}

nonisolated struct DiscogsReleaseDetail: Decodable, Sendable {
    let id: Int
    let title: String
    let year: Int?
    let artists: [DiscogsArtistReference]?
    let extraartists: [DiscogsCredit]?
    let labels: [DiscogsLabelReference]?
    /// How it was issued. Nothing read this, so a release read in full could
    /// not say whether it was a record or a film — see `ReleaseFormat`.
    let formats: [DiscogsFormat]?
    let videos: [DiscogsVideo]?
    let genres: [String]?
    let styles: [String]?
    let images: [DiscogsImage]?
    let tracklist: [DiscogsTrackLine]?
    let notes: String?
    let uri: String?
}

/// The three things a dig can start from, as Discogs names them in a
/// `database/search` `type` parameter.
nonisolated enum DiscogsSearchKind: String, Sendable, CaseIterable {
    case artist
    case release
    case label
}
