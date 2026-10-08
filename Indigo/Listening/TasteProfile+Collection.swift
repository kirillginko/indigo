//
//  TasteProfile+Collection.swift
//  Indigo
//
//  A taste profile built from everything, not only from the log.
//
//  `TasteProfile.build(from:)` reads listening events, which is the right
//  source and, on any copy of the app that predates them, an almost empty one.
//  The crate does not have that problem: it is years of decisions, each one
//  carrying the tags whatever crated it knew at the time, and the artists in
//  it have styles sitting in the Discogs cache.
//
//  So this folds three sources into one profile. The log leads where it has
//  anything to say, because listening is better evidence than keeping, and the
//  rest fills in behind it.
//

import Foundation
import SwiftData

extension TasteProfile {
    /// What this listener is drawn to, from the log, the crate, and the
    /// catalogue entries for the artists they kept.
    ///
    /// Each source is read in an order of its own content before anything is
    /// added up. These are sums of doubles, and the store returns rows in the
    /// order it filed them, which two devices holding the same rows do not
    /// share; a last-bit difference in a weight is enough to swap two equal
    /// suggestions. `now` is the moment plays are aged from -- EXPLORE passes
    /// its `asOf` rather than the clock.
    static func collected(context: ModelContext, now: Date = Date()) -> TasteProfile {
        var totals: [String: Double] = [:]
        var evidence: Double = 0

        // Listening, decayed. The same arithmetic as `build(from:)`, because
        // an event means the same thing whichever profile is reading it.
        let events = ListeningLog(context: context).since(now.addingTimeInterval(-horizon))
            .sorted { $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at }
        for event in events {
            let weight = event.weight
            guard weight != 0, !event.tags.isEmpty else { continue }
            let age = max(0, now.timeIntervalSince(event.at))
            let decayed = weight * pow(0.5, age / halfLife)
            if decayed > 0 { evidence += decayed }
            let share = decayed / Double(event.tags.count)
            for tag in event.tags { totals[tag, default: 0] += share }
        }

        // The crate. Not decayed: keeping something is a standing statement
        // rather than a moment, and a record filed two years ago is still on
        // the shelf.
        let crate = CrateService(context: context)
        let items = crate.items().sorted {
            $0.addedAt == $1.addedAt ? ($0.node?.id ?? "") < ($1.node?.id ?? "") : $0.addedAt < $1.addedAt
        }
        var crateArtistKeys = Set<String>()
        for item in items {
            let tags = ListeningLog.foldTags(item.genreTags)
            if !tags.isEmpty {
                evidence += 0.6
                let share = 0.6 / Double(tags.count)
                for tag in tags { totals[tag, default: 0] += share }
            }
            if let node = item.node, node.kind == .artist {
                crateArtistKeys.insert(RecordingKey.normalizeArtist(node.title))
            }
            if let name = item.artistName {
                crateArtistKeys.insert(RecordingKey.normalizeArtist(name))
            }
        }

        // And what the catalogue says those artists sound like. This is where
        // most of the detail comes from: a crated row carries whatever tags
        // the surface that crated it happened to have, and a Discogs entry
        // carries a dozen styles.
        if !crateArtistKeys.isEmpty {
            for artist in (try? context.fetch(FetchDescriptor<DiscogsArtist>(sortBy: [SortDescriptor(\.nameKey)]))) ?? []
            where crateArtistKeys.contains(artist.nameKey) {
                let tags = ListeningLog.foldTags(artist.styles + artist.genres)
                guard !tags.isEmpty else { continue }
                evidence += 0.4
                let share = 0.4 / Double(tags.count)
                for tag in tags { totals[tag, default: 0] += share }
            }
        }

        let positive = totals.filter { $0.value > 0 }
        guard let strongest = positive.values.max(), strongest > 0 else {
            return TasteProfile(weights: [:], evidence: evidence, builtAt: now)
        }
        return TasteProfile(
            weights: positive.mapValues { min(1, $0 / strongest) },
            evidence: evidence, builtAt: now
        )
    }
}
