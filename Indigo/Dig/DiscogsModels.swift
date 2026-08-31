//
//  DiscogsModels.swift
//  Indigo
//

import Foundation

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

    private enum CodingKeys: String, CodingKey {
        case id, title, year, role, type, label, artist
        case mainRelease = "main_release"
    }
}

nonisolated struct DiscogsArtistReleases: Decodable, Sendable {
    let releases: [DiscogsArtistRelease]?
}

nonisolated struct DiscogsArtistBundle: Sendable {
    let detail: DiscogsArtistDetail
    let releases: DiscogsArtistReleases
    let searchImageURL: String?
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

    var artistName: String? {
        let names = (artists ?? []).compactMap(\.name).filter { !$0.isEmpty }
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

nonisolated struct DiscogsReleaseDetail: Decodable, Sendable {
    let id: Int
    let title: String
    let year: Int?
    let artists: [DiscogsArtistReference]?
    let labels: [DiscogsLabelReference]?
    let videos: [DiscogsVideo]?
    let genres: [String]?
    let styles: [String]?
    let images: [DiscogsImage]?
    let tracklist: [DiscogsTrackLine]?
    let notes: String?
    let uri: String?
}
