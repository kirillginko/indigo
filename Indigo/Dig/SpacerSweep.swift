//
//  SpacerSweep.swift
//  Indigo
//
//  Clears the "no picture" pictures out of rows already written.
//
//  Discogs answers a request for an artist with no photograph by sending one:
//  `st.discogs.com/<hash>/images/spacer.gif`, a transparent single pixel on
//  what looks like that artist's own address. Stored, it is indistinguishable
//  from a real picture until it is drawn — see `DiscogsArtist.imageURL`, which
//  now filters it, as does the enricher that writes it.
//
//  Those two changes are what make the app behave; this is for the rows that
//  were written before them. Reading them correctly is enough to draw the
//  right thing, so nothing here is required — but a store full of addresses
//  that mean their own opposite is a trap for the next person to read one
//  directly, and three separate places had already fallen into it.
//
//  One shot, and it finds nothing to do on every launch after the first. The
//  shape is `BandcampEnricher.repairSelfPublishedLabels`, for the same reason.
//

import Foundation
import SwiftData

nonisolated enum SpacerSweep {
    /// What was cleared, for the caller that wants to log it. Zero on a store
    /// that has already been swept, and on a failed save.
    struct Result: Sendable {
        var artists = 0
        var portraits = 0
        var releases = 0
        var isEmpty: Bool { artists == 0 && portraits == 0 && releases == 0 }
    }

    static func run(in container: ModelContainer) async -> Result {
        let context = ModelContext(container)
        var result = Result()

        // Fetched whole and filtered here rather than asked of the store.
        //
        // The obvious `#Predicate { $0.imageURLString?.contains("/images/spacer") }`
        // is the shape that takes the process down against SQLite while
        // passing against an in-memory container — see `StorePredicateTests`.
        // These are small tables and this runs once, so there is nothing to
        // win by being clever about it.
        for artist in (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? [] {
            var cleared = false
            if artist.imageURLString != nil,
               DiscogsClient.usableImage(artist.imageURLString) == nil {
                artist.imageURLString = nil
                cleared = true
            }
            if artist.thumbnailURLString != nil,
               DiscogsClient.usableImage(artist.thumbnailURLString) == nil {
                artist.thumbnailURLString = nil
                cleared = true
            }
            if cleared { result.artists += 1 }
        }

        for record in (try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? [] {
            var cleared = false
            if record.imageURLString != nil,
               DiscogsClient.usableImage(record.imageURLString) == nil {
                record.imageURLString = nil
                cleared = true
            }
            if record.thumbnailURLString != nil,
               DiscogsClient.usableImage(record.thumbnailURLString) == nil {
                record.thumbnailURLString = nil
                cleared = true
            }
            if cleared { result.releases += 1 }
        }

        // A portrait row is the background fill's own answer, so clearing one
        // has a second effect: the name becomes worth looking up again.
        //
        // `lookupFailed` is deliberately left alone. A spacer *is* Discogs
        // saying it holds no photograph, so a row that recorded that is not
        // wrong — and turning a settled miss back into an open question would
        // put every one of these names back into a queue that is already
        // paced at one request every second and a half. What the fill needed
        // was to stop treating a spacer as a picture it already had, and that
        // is fixed where the list is built. See `DigWorker.pendingPortraits`.
        for portrait in (try? context.fetch(FetchDescriptor<ArtistPortrait>())) ?? [] {
            guard portrait.imageURLString != nil,
                  DiscogsClient.usableImage(portrait.imageURLString) == nil else { continue }
            portrait.imageURLString = nil
            result.portraits += 1
        }

        guard !result.isEmpty else { return result }
        // A count is worth nothing if the clearing did not land, so a failed
        // save reports none. Nothing is lost: the rows are still there and the
        // next launch sweeps again.
        do { try context.save() } catch { return Result() }
        return result
    }
}
