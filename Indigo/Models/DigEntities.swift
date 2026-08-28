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
