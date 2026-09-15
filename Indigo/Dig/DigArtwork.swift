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
        func isTheRecord(_ record: DiscogsReleaseRecord) -> Bool {
            guard RecordingKey.normalizeTitle(record.title) == wanted else { return false }
            guard let artistKey else { return true }
            return record.artistNames.contains { RecordingKey.normalizeArtist($0) == artistKey }
        }

        // The catalogue's own spelling first, which is what nearly every
        // caller is holding — a tracklist row's release line, an artist's
        // discography entry. The store answers that without handing back the
        // rest of the table, and handing back the rest of the table is what
        // this used to do on the main actor once per row.
        var exact = FetchDescriptor<DiscogsReleaseRecord>(predicate: #Predicate { $0.title == title })
        exact.fetchLimit = 12
        if let match = ((try? context.fetch(exact)) ?? []).first(where: isTheRecord) {
            return Pair(full: match.imageURL, thumbnail: match.thumbnailURL)
        }

        // A different spelling of the same record — punctuation, an edition
        // in brackets — is only findable by comparing the normalised form of
        // every one of them.
        //
        // That comparison used to walk the table here, and the comment above
        // it said never to call this from a render pass. A tracklist row whose
        // release is not cached does exactly that, once per row: five misses
        // measured 4,075ms. The walk now happens once, in `ReleasesByTitle`,
        // and every ask after it is a lookup.
        let match = ReleasesByTitle.shared.index(in: context)[wanted]?.first(where: isTheRecord)
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

/// Catalogued releases folded by the normalised form of their title.
///
/// The last rung of the sleeve ladder compares the normalised title of every
/// catalogued release, because a record filed as "Untitled (Edition 2)" and
/// asked for as "Untitled" is the same record and no index can say so. Its own
/// comment says never to call it from a render pass — and a tracklist row whose
/// release is not cached calls it, once per row, which is a render pass.
///
/// Measured on the benchmark's store: five rows that match nothing cost
/// 4,075ms, 815ms each. Folded once, the walk happens one time and every miss
/// after it is a dictionary lookup.
///
/// Held the way `LibraryAlbums` and `BandcampByArtist` are held, and stale for
/// the same two reasons — a row added, or a row written over in place by
/// `DiscogsEnricher.release(id:)`, which changes no count and does stamp
/// `fetchedAt`.
nonisolated final class ReleasesByTitle: @unchecked Sendable {
    static let shared = ReleasesByTitle()

    private let lock = NSLock()
    private var signature: [Double]?
    private var source: ObjectIdentifier?
    private var held: [String: [DiscogsReleaseRecord]] = [:]

    private static func signature(in context: ModelContext) -> [Double] {
        let count = (try? context.fetchCount(FetchDescriptor<DiscogsReleaseRecord>())) ?? -1
        var newest = FetchDescriptor<DiscogsReleaseRecord>(
            sortBy: [SortDescriptor(\DiscogsReleaseRecord.fetchedAt, order: .reverse)]
        )
        newest.fetchLimit = 1
        let touched = (try? context.fetch(newest))?.first?.fetchedAt.timeIntervalSince1970 ?? -1
        return [Double(count), touched]
    }

    func index(in context: ModelContext) -> [String: [DiscogsReleaseRecord]] {
        let current = Self.signature(in: context)
        let store = ObjectIdentifier(context.container)

        lock.lock()
        if let signature, signature == current, source == store {
            let answer = held
            lock.unlock()
            return answer
        }
        lock.unlock()

        var built: [String: [DiscogsReleaseRecord]] = [:]
        for record in (try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? [] {
            let key = RecordingKey.normalizeTitle(record.title)
            guard !key.isEmpty else { continue }
            built[key, default: []].append(record)
        }

        lock.lock()
        signature = current
        source = store
        held = built
        lock.unlock()
        return built
    }
}
