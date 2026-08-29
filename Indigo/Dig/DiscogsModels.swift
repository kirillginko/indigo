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
    let labelArtists: [String]
    let styleArtists: [String]
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
}

nonisolated struct DiscogsReleaseDetail: Decodable, Sendable {
    let id: Int
    let title: String
    let year: Int?
    let artists: [DiscogsArtistReference]?
    let labels: [DiscogsLabelReference]?
    let genres: [String]?
    let styles: [String]?
    let images: [DiscogsImage]?
    let tracklist: [DiscogsTrackLine]?
    let notes: String?
    let uri: String?
}
