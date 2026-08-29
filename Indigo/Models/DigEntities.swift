//
//  DigEntities.swift
//  Indigo
//
//  The cached side of the DIG graph. MusicBrainz is rate-limited to one
//  request a second, so anything looked up once is kept — DIG has to stay
//  navigable on a train, and a graph you can only walk online isn't a graph.
//

import Foundation
import SwiftData

@Model
nonisolated final class Artist {
    /// MusicBrainz artist ID. The one identifier worth treating as stable.
    @Attribute(.unique) var mbid: String
    var name: String
    var sortName: String?
    var disambiguation: String?
    var type: String?
    /// "Munich / Germany".
    var origin: String?
    /// Discography titles, newest first, cached as a flat list because DIG
    /// only ever renders them.
    var releaseTitles: [String]
    var releaseDates: [String]
    var genreTags: [String] = []
    var fetchedAt: Date

    init(
        mbid: String,
        name: String,
        sortName: String? = nil,
        disambiguation: String? = nil,
        type: String? = nil,
        origin: String? = nil,
        releaseTitles: [String] = [],
        releaseDates: [String] = [],
        genreTags: [String] = []
    ) {
        self.mbid = mbid
        self.name = name
        self.sortName = sortName
        self.disambiguation = disambiguation
        self.type = type
        self.origin = origin
        self.releaseTitles = releaseTitles
        self.releaseDates = releaseDates
        self.genreTags = genreTags
        self.fetchedAt = Date()
    }

    /// Titles paired with their years, for the releases column.
    var releases: [(title: String, year: String?)] {
        releaseTitles.enumerated().map { index, title in
            let date = index < releaseDates.count ? releaseDates[index] : ""
            return (title, date.isEmpty ? nil : String(date.prefix(4)))
        }
    }
}

/// Named `MusicLabel` rather than `Label` — SwiftUI already owns that name,
/// and a model that shadows a view type makes every call site ambiguous.
@Model
nonisolated final class MusicLabel {
    @Attribute(.unique) var mbid: String
    var name: String
    var type: String?
    var origin: String?
    var foundedYear: String?
    /// Roster, cached from the label's releases. Ordered by how much of the
    /// catalogue each artist accounts for.
    var artistNames: [String]
    var artistMBIDs: [String]
    var releaseTitles: [String]
    var catalogueSize: Int
    var fetchedAt: Date

    init(
        mbid: String,
        name: String,
        type: String? = nil,
        origin: String? = nil,
        foundedYear: String? = nil,
        artistNames: [String] = [],
        artistMBIDs: [String] = [],
        releaseTitles: [String] = [],
        catalogueSize: Int = 0
    ) {
        self.mbid = mbid
        self.name = name
        self.type = type
        self.origin = origin
        self.foundedYear = foundedYear
        self.artistNames = artistNames
        self.artistMBIDs = artistMBIDs
        self.releaseTitles = releaseTitles
        self.catalogueSize = catalogueSize
        self.fetchedAt = Date()
    }

    var roster: [(name: String, mbid: String?)] {
        artistNames.enumerated().map { index, name in
            (name, index < artistMBIDs.count && !artistMBIDs[index].isEmpty ? artistMBIDs[index] : nil)
        }
    }
}

/// What a recording turned out to belong to. Kept on the recording's own row
/// rather than as a relationship graph, because DIG reads it far more often
/// than it writes it.
@Model
nonisolated final class RecordingMetadata {
    @Attribute(.unique) var recordingID: UUID

    var artistMBID: String?
    var artistName: String?
    var releaseMBID: String?
    var releaseTitle: String?
    var releaseDate: String?
    var releaseType: String?
    var labelMBID: String?
    var labelName: String?
    var catalogNumber: String?
    var fetchedAt: Date
    /// Set when a lookup ran and found nothing, so it isn't retried forever.
    var lookupFailed: Bool

    init(recordingID: UUID) {
        self.recordingID = recordingID
        self.fetchedAt = Date()
        self.lookupFailed = false
    }
}

/// Discogs data is kept separate because its identifiers and refresh policy
/// are different from MusicBrainz. DIG composes both caches at read time.
@Model
nonisolated final class DiscogsArtist {
    @Attribute(.unique) var nameKey: String
    var discogsID: Int
    var name: String
    var realName: String?
    var biography: String?
    var imageURLString: String?
    var profileURLString: String?
    var aliasNames: [String]
    var memberNames: [String]
    var groupNames: [String]
    var releaseTitles: [String]
    var releaseYears: [String]
    var releaseDiscogsIDs: [Int]
    var releaseImageURLStrings: [String]
    var releaseThumbnailURLStrings: [String] = []
    var releaseLabels: [String]
    var collaboratorNames: [String] = []
    var labelNeighbourNames: [String] = []
    var styleNeighbourNames: [String] = []
    var recommendationsFetchedAt: Date?
    var labelNames: [String]
    var genres: [String]
    var styles: [String]
    var fetchedAt: Date
    var cacheVersion: Int = 0

    init(nameKey: String, discogsID: Int, name: String) {
        self.nameKey = nameKey
        self.discogsID = discogsID
        self.name = name
        aliasNames = []
        memberNames = []
        groupNames = []
        releaseTitles = []
        releaseYears = []
        releaseDiscogsIDs = []
        releaseImageURLStrings = []
        releaseThumbnailURLStrings = []
        releaseLabels = []
        collaboratorNames = []
        labelNeighbourNames = []
        styleNeighbourNames = []
        labelNames = []
        genres = []
        styles = []
        fetchedAt = Date()
    }

    var imageURL: URL? { imageURLString.flatMap(URL.init(string:)) }

    var profileURL: URL? {
        guard let profileURLString, !profileURLString.isEmpty else { return nil }
        if let absolute = URL(string: profileURLString), absolute.scheme != nil { return absolute }
        return URL(string: "https://www.discogs.com\(profileURLString)")
    }

    var isFresh: Bool { Date().timeIntervalSince(fetchedAt) < 24 * 60 * 60 }
}

@Model
nonisolated final class DiscogsReleaseRecord {
    @Attribute(.unique) var discogsID: Int
    var title: String
    var year: Int?
    var artistNames: [String]
    var labelNames: [String]
    var catalogNumbers: [String]
    var genres: [String]
    var styles: [String]
    var imageURLString: String?
    var trackPositions: [String]
    var trackTitles: [String]
    var trackDurations: [String]
    var notes: String?
    var profileURLString: String?
    var fetchedAt: Date

    init(discogsID: Int, title: String) {
        self.discogsID = discogsID
        self.title = title
        artistNames = []
        labelNames = []
        catalogNumbers = []
        genres = []
        styles = []
        trackPositions = []
        trackTitles = []
        trackDurations = []
        fetchedAt = Date()
    }

    var imageURL: URL? { imageURLString.flatMap(URL.init(string:)) }
    var profileURL: URL? {
        guard let profileURLString else { return nil }
        if let url = URL(string: profileURLString), url.scheme != nil { return url }
        return URL(string: "https://www.discogs.com\(profileURLString)")
    }
    var isFresh: Bool { Date().timeIntervalSince(fetchedAt) < 24 * 60 * 60 }
}
