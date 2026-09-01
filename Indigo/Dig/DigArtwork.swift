//
//  DigArtwork.swift
//  Indigo
//
//  One answer to "what does this record look like".
//
//  Every surface used to work it out for itself: the artist grid read the
//  Discogs artist row then the release cache then Bandcamp, the release page
//  read only the release cache, and the recording page read a third thing. So
//  the same record had a sleeve in one view and a blank square in the next,
//  which reads as the app losing things.
//
//  The ladder lives here instead, and everything asks it.
//

import Foundation
import SwiftData

nonisolated struct DigArtwork {
    let context: ModelContext

    /// A full-size cover and the small cut that stands in while it loads.
    nonisolated struct Pair: Sendable {
        var full: URL?
        var thumbnail: URL?

        var isEmpty: Bool { full == nil && thumbnail == nil }

        /// The first of these that has anything, keeping whichever halves are
        /// known — a thumbnail from one source and a cover from another is
        /// still better than neither.
        static func first(_ candidates: [Pair]) -> Pair {
            var found = Pair()
            for candidate in candidates {
                found.full = found.full ?? candidate.full
                found.thumbnail = found.thumbnail ?? candidate.thumbnail
                if found.full != nil, found.thumbnail != nil { break }
            }
            return found
        }
    }

    /// What a release looks like, from whichever source has a picture.
    func release(title: String, artist: String?) -> Pair {
        Pair.first([
            discogsRelease(title: title, artist: artist),
            // The rung that was missing, and the one the grid was standing on.
            //
            // A record's sleeve in an artist's discography comes from that
            // artist's catalogue listing, not from the release cache — the
            // release itself is only fetched when somebody opens it. So the
            // tile had a picture and the record's own page, which asked only
            // the release cache, had a blank square. That is the same record
            // and the same picture; it was just filed somewhere this ladder
            // never looked.
            artistListing(title: title, artist: artist),
            bandcamp(title: title, artist: artist)
        ])
    }

    /// The sleeve as it appears in an artist's own discography.
    private func artistListing(title: String, artist: String?) -> Pair {
        guard let artist else { return Pair() }
        let key = RecordingKey.normalizeArtist(artist)
        guard !key.isEmpty else { return Pair() }
        var descriptor = FetchDescriptor<DiscogsArtist>(predicate: #Predicate { $0.nameKey == key })
        descriptor.fetchLimit = 1
        guard let record = (try? context.fetch(descriptor))?.first else { return Pair() }
        let wanted = RecordingKey.normalizeTitle(title)
        guard let index = record.releaseTitles.firstIndex(where: {
            RecordingKey.normalizeTitle($0) == wanted
        }) else { return Pair() }
        return Pair(
            full: index < record.releaseImageURLStrings.count
                ? URL(string: record.releaseImageURLStrings[index]) : nil,
            thumbnail: index < record.releaseThumbnailURLStrings.count
                ? URL(string: record.releaseThumbnailURLStrings[index]) : nil
        )
    }

    private func discogsRelease(title: String, artist: String?) -> Pair {
        let wanted = RecordingKey.normalizeTitle(title)
        guard !wanted.isEmpty else { return Pair() }
        let artistKey = artist.map { RecordingKey.normalizeArtist($0) }
        let match = ((try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? [])
            .first { record in
                guard RecordingKey.normalizeTitle(record.title) == wanted else { return false }
                guard let artistKey else { return true }
                return record.artistNames.contains { RecordingKey.normalizeArtist($0) == artistKey }
            }
        return Pair(full: match?.imageURL, thumbnail: match?.thumbnailURL)
    }

    private func bandcamp(title: String, artist: String?) -> Pair {
        let wanted = RecordingKey.normalizeTitle(title)
        guard !wanted.isEmpty else { return Pair() }
        let enricher = BandcampEnricher(context: context)
        let candidates = artist.map { enricher.cachedReleases(forArtist: $0) }
            ?? ((try? context.fetch(FetchDescriptor<BandcampRelease>())) ?? [])
        guard let match = candidates.first(where: {
            RecordingKey.normalizeTitle($0.title) == wanted
        }) else { return Pair() }
        return Pair(
            full: BandcampImage.sized(match.imageURL, BandcampImage.cover),
            thumbnail: BandcampImage.sized(match.imageURL, BandcampImage.thumbnail)
        )
    }
}
