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
    /// The release sleeve. It lives here, beside the release facts that
    /// justify it, rather than on the crate row that happens to show it —
    /// music heard in a broadcast has a cover whether or not anybody kept it,
    /// and a tracklist should be able to draw one without being crated first.
    var artworkURLString: String?
    var fetchedAt: Date
    /// Set when a lookup ran and found nothing, so it isn't retried forever.
    var lookupFailed: Bool

    init(recordingID: UUID) {
        self.recordingID = recordingID
        self.fetchedAt = Date()
        self.lookupFailed = false
    }

    var artworkURL: URL? {
        guard let artworkURLString, !artworkURLString.isEmpty else { return nil }
        return URL(string: artworkURLString)
    }

    /// "Untrue · Hyperdub · 2007" — the line a tracklist row shows once the
    /// catalogue has answered, and nothing at all before then.
    var releaseLine: String? {
        let parts = [releaseTitle, labelName, releaseDate.map { String($0.prefix(4)) }]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
    /// A small picture for each neighbour, positionally paired with the names
    /// above. Free — it arrives with the search that found them.
    var labelNeighbourImageURLStrings: [String] = []
    var styleNeighbourImageURLStrings: [String] = []
    /// The artist's own links as their catalogue entry lists them —
    /// Bandcamp, SoundCloud, a homepage. Kept because it is how Indigo learns
    /// a Bandcamp address without ever searching Bandcamp, which its
    /// robots.txt forbids.
    var externalURLStrings: [String] = []
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

    /// Any picture of this artist's music we already hold — the first sleeve
    /// in their catalogue. For somebody dug into before Discogs gave us a
    /// portrait, this is the difference between a row with a picture and a
    /// row with a hole in it.
    var anyReleaseImageURL: URL? {
        for value in releaseThumbnailURLStrings + releaseImageURLStrings where !value.isEmpty {
            if let url = URL(string: value) { return url }
        }
        return nil
    }

    /// The picture to show for a neighbouring artist: their own portrait if we
    /// happen to have dug into them, otherwise a record of theirs.
    func neighbourImageURL(for name: String) -> URL? {
        let key = RecordingKey.normalizeArtist(name)
        for (names, images) in [(labelNeighbourNames, labelNeighbourImageURLStrings),
                                (styleNeighbourNames, styleNeighbourImageURLStrings)] {
            guard let index = names.firstIndex(where: { RecordingKey.normalizeArtist($0) == key }),
                  index < images.count, !images[index].isEmpty
            else { continue }
            return URL(string: images[index])
        }
        return nil
    }

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
    /// Who is on each track, where the release itself is credited to nobody.
    var trackArtists: [String] = []
    /// Recordings of this release somebody catalogued it alongside. Positional
    /// arrays rather than a relationship: DIG only ever renders them.
    var videoURLStrings: [String] = []
    var videoTitles: [String] = []
    var videoDurations: [Int] = []
    /// What we know about each recording, positionally: 0 not asked, 1 plays,
    /// 2 will not. Kept rather than recomputed so a recording that has already
    /// refused once is never offered again.
    var videoPlayable: [Int] = []
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

    /// Playable recordings of this release, titled as whoever catalogued them
    /// wrote them down.
    /// Every recording attached to this release, including ones already known
    /// not to play. Use `videos` to show them.
    var allVideos: [(url: URL, title: String, seconds: Int?, playable: Int)] {
        videoURLStrings.enumerated().compactMap { index, address in
            guard let url = URL(string: address), YouTubeLink.isYouTube(url) else { return nil }
            let title = index < videoTitles.count ? videoTitles[index] : ""
            let seconds = index < videoDurations.count ? videoDurations[index] : 0
            let verdict = index < videoPlayable.count ? videoPlayable[index] : 0
            return (url, title.isEmpty ? "Untitled" : title, seconds > 0 ? seconds : nil, verdict)
        }
    }

    /// The ones worth offering. A recording that has refused to play is not
    /// listed at all — being shown something and then watching it skip itself
    /// is worse than never being offered it.
    ///
    /// Unverified entries are kept: not yet asked is not the same as refused,
    /// and hiding everything until it had been checked would leave the page
    /// empty for no good reason.
    var videos: [(url: URL, title: String, seconds: Int?)] {
        allVideos.filter { $0.playable != 2 }.map { ($0.url, $0.title, $0.seconds) }
    }

    var profileURL: URL? {
        guard let profileURLString else { return nil }
        if let url = URL(string: profileURLString), url.scheme != nil { return url }
        return URL(string: "https://www.discogs.com\(profileURLString)")
    }
    var isFresh: Bool { Date().timeIntervalSince(fetchedAt) < 24 * 60 * 60 }
}


/// A picture of an artist, looked up on its own.
///
/// Separate from `DiscogsArtist` on purpose. That record means "we have dug
/// into this artist" and carries a discography; this means only "we went and
/// found a thumbnail for a row", which is a quarter of the requests and none
/// of the commitment. Filling one in must never look like having dug.
@Model
nonisolated final class ArtistPortrait {
    @Attribute(.unique) var nameKey: String
    var name: String
    var imageURLString: String?
    var fetchedAt: Date
    /// Set when a lookup ran and found nothing, so the same name is not asked
    /// after every time the app opens.
    var lookupFailed: Bool

    init(nameKey: String, name: String) {
        self.nameKey = nameKey
        self.name = name
        fetchedAt = Date()
        lookupFailed = false
    }

    var imageURL: URL? {
        guard let imageURLString, !imageURLString.isEmpty else { return nil }
        return URL(string: imageURLString)
    }

    /// A miss is worth trying again eventually — a catalogue gains artists —
    /// but not today.
    var isWorthRetrying: Bool {
        lookupFailed && Date().timeIntervalSince(fetchedAt) > 30 * 24 * 60 * 60
    }
}
