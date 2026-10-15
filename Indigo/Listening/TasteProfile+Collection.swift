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
    /// catalogue entries for the artists they kept -- read from the store.
    ///
    /// The same profile `collected(personal:artistTags:now:)` works out from
    /// plain values, given what the store holds; EXPLORE builds those values
    /// itself and calls that directly.
    static func collected(context: ModelContext, now: Date = Date()) -> TasteProfile {
        let personal = PersonalInputs.read(context: context, asOf: now)
        return collected(
            personal: personal,
            artistTags: LocalKnowledgeAdapter.artistTags(for: personal.tasteArtistKeys, in: context),
            now: now
        )
    }

    /// The profile itself, from the listener's rows and what the catalogue
    /// says their kept artists sound like (`artistTags`: folded styles and
    /// genres by artist key).
    ///
    /// Each source is added up in an order of its own content. These are sums
    /// of doubles, and a last-bit difference in a weight is enough to swap two
    /// equal suggestions. `now` is the moment plays are aged from -- EXPLORE
    /// passes its `asOf` rather than the clock.
    static func collected(personal: PersonalInputs, artistTags: [String: [String]], now: Date) -> TasteProfile {
        var totals: [String: Double] = [:]
        var evidence: Double = 0

        // Listening, decayed. The same arithmetic as `build(from:)`, because
        // an event means the same thing whichever profile is reading it.
        // `plays` is oldest first, then by id.
        for play in personal.plays where play.at >= now.addingTimeInterval(-horizon) {
            let weight = play.weight
            guard weight != 0, !play.tags.isEmpty else { continue }
            let age = max(0, now.timeIntervalSince(play.at))
            let decayed = weight * pow(0.5, age / halfLife)
            if decayed > 0 { evidence += decayed }
            let share = decayed / Double(play.tags.count)
            for tag in play.tags { totals[tag, default: 0] += share }
        }

        // The crate. Not decayed: keeping something is a standing statement
        // rather than a moment, and a record filed two years ago is still on
        // the shelf. Oldest first, as the store's own order was.
        var crateArtistKeys = Set<String>()
        for item in personal.crate.reversed() {
            let tags = ListeningLog.foldTags(item.genreTags)
            if !tags.isEmpty {
                evidence += 0.6
                let share = 0.6 / Double(tags.count)
                for tag in tags { totals[tag, default: 0] += share }
            }
            crateArtistKeys.formUnion(item.tasteArtistKeys)
        }

        // And what the catalogue says those artists sound like. This is where
        // most of the detail comes from: a crated row carries whatever tags
        // the surface that crated it happened to have, and a Discogs entry
        // carries a dozen styles.
        for key in artistTags.keys.sorted() where crateArtistKeys.contains(key) {
            let tags = artistTags[key] ?? []
            guard !tags.isEmpty else { continue }
            evidence += 0.4
            let share = 0.4 / Double(tags.count)
            for tag in tags { totals[tag, default: 0] += share }
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
