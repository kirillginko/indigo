//
//  MusicBrainzModels.swift
//  Indigo
//
//  Wire format for the MusicBrainz web service. MusicBrainz is a metadata
//  source, not an identity: what it tells us gets folded into a Recording that
//  already exists, and its IDs are claims stored alongside everyone else's.
//

import Foundation

// MARK: - Wire types

nonisolated struct MBArtistCredit: Decodable, Sendable {
    let name: String?
    let artist: MBArtistRef?
}

nonisolated struct MBArtistRef: Decodable, Sendable {
    let id: String?
    let name: String?
    let sortName: String?
    let disambiguation: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, disambiguation
        case sortName = "sort-name"
    }
}

nonisolated struct MBArea: Decodable, Sendable {
    let name: String?
}

nonisolated struct MBLifeSpan: Decodable, Sendable {
    let begin: String?
    let ended: Bool?
}

nonisolated struct MBTag: Decodable, Sendable {
    let name: String?
    let count: Int?
}

nonisolated struct MBReleaseGroup: Decodable, Sendable {
    let id: String?
    let title: String?
    let primaryType: String?
    let firstReleaseDate: String?

    private enum CodingKeys: String, CodingKey {
        case id, title
        case primaryType = "primary-type"
        case firstReleaseDate = "first-release-date"
    }
}

nonisolated struct MBLabelRef: Decodable, Sendable {
    let id: String?
    let name: String?
}

nonisolated struct MBLabelInfo: Decodable, Sendable {
    let catalogNumber: String?
    let label: MBLabelRef?

    private enum CodingKeys: String, CodingKey {
        case label
        case catalogNumber = "catalog-number"
    }
}

nonisolated struct MBRelease: Decodable, Sendable {
    let id: String?
    let title: String?
    let date: String?
    let country: String?
    let releaseGroup: MBReleaseGroup?
    let labelInfo: [MBLabelInfo]?
    let artistCredit: [MBArtistCredit]?

    private enum CodingKeys: String, CodingKey {
        case id, title, date, country
        case releaseGroup = "release-group"
        case labelInfo = "label-info"
        case artistCredit = "artist-credit"
    }
}

nonisolated struct MBRecording: Decodable, Sendable {
    let id: String?
    let title: String?
    /// Milliseconds.
    let length: Int?
    let score: Int?
    let isrcs: [String]?
    let artistCredit: [MBArtistCredit]?
    let releases: [MBRelease]?
    let firstReleaseDate: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, length, score, isrcs, releases
        case artistCredit = "artist-credit"
        case firstReleaseDate = "first-release-date"
    }

    var durationSeconds: Double? {
        guard let length, length > 0 else { return nil }
        return Double(length) / 1000
    }

    var primaryArtist: MBArtistRef? { artistCredit?.first?.artist }

    /// Releases oldest first: a track's first home matters more than the
    /// fifteenth compilation it was licensed to. Deduplicated, because the
    /// same album shows up once per pressing.
    var releaseCandidates: [MBRelease] {
        var seen = Set<String>()
        return (releases ?? [])
            .sorted { ($0.date ?? "9999") < ($1.date ?? "9999") }
            .filter { seen.insert($0.id ?? UUID().uuidString).inserted }
    }

    var primaryRelease: MBRelease? { releaseCandidates.first }
}

nonisolated struct MBRecordingSearch: Decodable, Sendable {
    let count: Int?
    let recordings: [MBRecording]?
}

nonisolated struct MBArtist: Decodable, Sendable {
    let id: String?
    let name: String?
    let sortName: String?
    let disambiguation: String?
    let type: String?
    let country: String?
    let area: MBArea?
    let beginArea: MBArea?
    let lifeSpan: MBLifeSpan?
    let releaseGroups: [MBReleaseGroup]?
    let tags: [MBTag]?

    private enum CodingKeys: String, CodingKey {
        case id, name, disambiguation, type, country, area, tags
        case sortName = "sort-name"
        case beginArea = "begin-area"
        case lifeSpan = "life-span"
        case releaseGroups = "release-groups"
    }

    /// "Munich / Germany" — where the music is from, which is half of why a
    /// label matters.
    var origin: String? {
        let parts = [beginArea?.name, area?.name].compactMap { $0 }
        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: " / ")
    }
}

nonisolated struct MBLabel: Decodable, Sendable {
    let id: String?
    let name: String?
    let type: String?
    let country: String?
    let area: MBArea?
    let lifeSpan: MBLifeSpan?

    private enum CodingKeys: String, CodingKey {
        case id, name, type, country, area
        case lifeSpan = "life-span"
    }

    var origin: String? {
        [area?.name, country].compactMap { $0 }.first
    }
}

nonisolated struct MBArtistSearchResult: Decodable, Sendable {
    let id: String?
    let name: String?
    let score: Int?
    let disambiguation: String?
    let type: String?
    let country: String?
    let area: MBArea?
    let beginArea: MBArea?
    let tags: [MBTag]?

    private enum CodingKeys: String, CodingKey {
        case id, name, score, disambiguation, type, country, area, tags
        case beginArea = "begin-area"
    }

    var origin: String? {
        let parts = [beginArea?.name, area?.name, country].compactMap { $0 }
        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.prefix(2).joined(separator: " / ")
    }
}

nonisolated struct MBArtistSearch: Decodable, Sendable {
    let count: Int?
    let artists: [MBArtistSearchResult]?
}

nonisolated struct MBReleaseGroupBrowse: Decodable, Sendable {
    let releaseGroupCount: Int?
    let releaseGroups: [MBReleaseGroup]?

    private enum CodingKeys: String, CodingKey {
        case releaseGroupCount = "release-group-count"
        case releaseGroups = "release-groups"
    }
}

nonisolated struct MBReleaseBrowse: Decodable, Sendable {
    let releaseCount: Int?
    let releases: [MBRelease]?

    private enum CodingKeys: String, CodingKey {
        case releases
        case releaseCount = "release-count"
    }
}
