//
//  TasteProfile.swift
//  Indigo
//
//  What this listener is drawn to, in numbers nobody has to look at.
//
//  Not a genre badge and not a year-in-review. These weights exist to rank
//  candidates inside DIG and EXPLORE, which is why they are derived and never
//  stored: a profile written to disk is a claim about someone that goes stale
//  quietly, and a profile recomputed from the log is only ever as wrong as the
//  log is.
//
//  Two decisions are worth stating outright. Recency decays rather than
//  truncates, so a run through spiritual jazz last winter still counts for
//  something instead of vanishing at an arbitrary cut-off. And the result is
//  normalised against its own strongest interest, so a profile means the same
//  thing after a week of listening as after a year — otherwise every threshold
//  downstream would have to know how long the app had been installed.
//

import Foundation
import SwiftData

nonisolated struct TasteProfile: Sendable {
    /// Interest → 0…1. "fourth-world": 0.91.
    let weights: [String: Double]
    /// How much listening this was built from. A profile drawn from two plays
    /// is not wrong, it is just not worth acting on, and callers deserve to be
    /// able to tell the difference.
    let evidence: Double
    let builtAt: Date

    /// Below this the profile should not be steering anything on its own.
    static let confidentEvidence: Double = 8

    var isConfident: Bool { evidence >= Self.confidentEvidence }
    var isEmpty: Bool { weights.isEmpty }

    /// How long an encounter takes to count half as much. Long enough that a
    /// season of listening still shows, short enough that taste is allowed to
    /// change.
    static let halfLife: TimeInterval = 60 * 24 * 60 * 60

    subscript(interest: String) -> Double { weights[interest.lowercased()] ?? 0 }

    /// The strongest interests, heaviest first.
    func top(_ limit: Int = 8) -> [(interest: String, weight: Double)] {
        weights
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { (interest: $0.key, weight: $0.value) }
    }

    /// How well something described by these tags matches what they listen to.
    ///
    /// The mean of the tags that land rather than the sum, so a release
    /// carrying nine tags cannot out-score a closer match carrying two. The
    /// count of matches is folded back in gently — two independent hits really
    /// are better evidence than one — but never enough to reverse that.
    func affinity(for tags: [String]) -> Double {
        let folded = ListeningLog.foldTags(tags)
        guard !folded.isEmpty else { return 0 }
        let hits = folded.map { self[$0] }.filter { $0 > 0 }
        guard !hits.isEmpty else { return 0 }
        let mean = hits.reduce(0, +) / Double(hits.count)
        let breadth = 1 + min(0.3, Double(hits.count - 1) * 0.1)
        return min(1, mean * breadth)
    }

    // MARK: - Building

    /// Derives a profile from the log.
    ///
    /// `now` is injectable so a test can age events without sleeping.
    static func build(from events: [ListeningEvent], now: Date = Date()) -> TasteProfile {
        var totals: [String: Double] = [:]
        var evidence: Double = 0

        for event in events {
            let weight = event.weight
            guard weight != 0, !event.tags.isEmpty else { continue }
            let age = now.timeIntervalSince(event.at)
            // An event logged in the future is a clock that moved, not
            // evidence from tomorrow; treat it as having just happened.
            let decay = age <= 0 ? 1 : pow(0.5, age / halfLife)
            let decayed = weight * decay
            if decayed > 0 { evidence += decayed }

            // Split evenly across the tags, so tagging a show with twelve
            // styles does not make it count twelve times as much as one
            // tagged "dub".
            let share = decayed / Double(event.tags.count)
            for tag in event.tags {
                totals[tag, default: 0] += share
            }
        }

        // Dismissals can drive an interest negative. Those are not interests
        // at a weight of zero, they are absences, and keeping them would let
        // `affinity` treat a refused genre as merely unfamiliar.
        let positive = totals.filter { $0.value > 0 }
        guard let strongest = positive.values.max(), strongest > 0 else {
            return TasteProfile(weights: [:], evidence: evidence, builtAt: now)
        }
        let normalized = positive.mapValues { min(1, $0 / strongest) }
        return TasteProfile(weights: normalized, evidence: evidence, builtAt: now)
    }

    /// Past this, an encounter has decayed to about a sixtieth of its weight
    /// and cannot change any ranking it appears in. Reading the whole log to
    /// add it in anyway is how a profile gets slower every month the app is
    /// used, which is the opposite of what should happen.
    static let horizon: TimeInterval = 365 * 24 * 60 * 60

    static func build(from log: ListeningLog, now: Date = Date()) -> TasteProfile {
        build(from: log.since(now.addingTimeInterval(-horizon)), now: now)
    }

    static let empty = TasteProfile(weights: [:], evidence: 0, builtAt: .distantPast)
}
