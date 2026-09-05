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
    static func collected(context: ModelContext, now: Date = Date()) -> TasteProfile {
        var totals: [String: Double] = [:]
        var evidence: Double = 0

        // Listening, decayed. The same arithmetic as `build(from:)`, because
        // an event means the same thing whichever profile is reading it.
        for event in ListeningLog(context: context).since(now.addingTimeInterval(-horizon)) {
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
        let items = crate.items()
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
            if let name = item.recording?.artistName {
                crateArtistKeys.insert(RecordingKey.normalizeArtist(name))
            }
        }

        // And what the catalogue says those artists sound like. This is where
        // most of the detail comes from: a crated row carries whatever tags
        // the surface that crated it happened to have, and a Discogs entry
        // carries a dozen styles.
        if !crateArtistKeys.isEmpty {
            for artist in (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? []
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
