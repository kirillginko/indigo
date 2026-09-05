//
//  ExploreSuggestions.swift
//  Indigo
//
//  Somewhere to go next, out of what you already keep.
//
//  EXPLORE could only ever show the listener their own crate back. Every
//  section on it was a filter over things they had already decided to keep,
//  which makes it a nicely arranged inventory rather than a way of finding
//  anything — and the stations block, the one part that did suggest something,
//  ranked seven hard-coded names against a bag of genre words.
//
//  This walks the graph the earlier phases built: one step out of the records,
//  labels and shows they kept, minus everything they have already met. The
//  subtraction is the whole point. A suggestion somebody has already heard
//  four times is not a suggestion, and leaving those in is precisely how a
//  discovery surface turns back into a mirror.
//
//  Nothing here asks a network. These are connections Indigo already holds.
//

import Foundation
import SwiftData

/// Something worth digging into, and the thing in this listener's own
/// collection that argues for it.
nonisolated struct ExploreSuggestion: Identifiable, Sendable {
    let node: MusicNode
    /// The evidence, as the edge itself stated it — "Releases on Orange Milk
    /// Records", "Mastered By on Pool". Never a phrase this file invented.
    let reason: String
    /// What it was reached from, by name.
    let via: String
    let score: Double

    var id: String { node.id }

    /// The line under the card: what this is, and what it came from.
    var connection: String { "\(reason) · via \(via)" }
}

nonisolated struct ExploreSuggestionEngine {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// How many places the walk starts from. Every origin is a full graph
    /// walk, so this is the knob that decides what the whole thing costs.
    static let origins = 12

    /// Everywhere worth going, best first.
    func suggestions(limit: Int = 12) -> [ExploreSuggestion] {
        let known = knownGround()
        guard !known.isEmpty else { return [] }

        let graph = GraphStore(context: context)
        let log = ListeningLog(context: context)
        let seen = Set(known.map(\.node.id))

        var best: [String: ExploreSuggestion] = [:]
        for origin in known.prefix(Self.origins) {
            for connection in graph.neighbors(of: origin.node).byDestination {
                let node = connection.node
                // Nowhere to land is not a suggestion. A node with no page is
                // a row that looks like a link and does nothing.
                guard node.destination != nil else { continue }
                guard !seen.contains(node.id) else { continue }
                guard !log.hasEncountered(node) else { continue }

                let score = connection.confidence * origin.weight
                if let existing = best[node.id], existing.score >= score { continue }
                best[node.id] = ExploreSuggestion(
                    node: node,
                    reason: connection.edges.first?.reason ?? "Connected to \(origin.node.title)",
                    via: origin.node.title,
                    score: score
                )
            }
        }
        return Self.spread(
            best.values.sorted {
                $0.score == $1.score ? $0.node.title < $1.node.title : $0.score > $1.score
            },
            limit: limit
        )
    }

    /// At most this many suggestions from any one starting point.
    ///
    /// Without it a single well-connected record takes the whole block: one
    /// real collection produced five of twelve rows "via Nav Katze", which is
    /// not a picture of where that listener could go, it is a picture of one
    /// remix album. The cap costs a little ranking accuracy and buys a list
    /// that spans the collection.
    static let perOrigin = 3

    private static func spread(
        _ ranked: [ExploreSuggestion], limit: Int
    ) -> [ExploreSuggestion] {
        var taken: [String: Int] = [:]
        var kept: [ExploreSuggestion] = []
        var overflow: [ExploreSuggestion] = []
        for suggestion in ranked {
            guard kept.count < limit else { break }
            if taken[suggestion.via, default: 0] < perOrigin {
                taken[suggestion.via, default: 0] += 1
                kept.append(suggestion)
            } else {
                overflow.append(suggestion)
            }
        }
        // A thin collection has few origins to spread across, and a short list
        // is worse than a slightly lopsided one.
        if kept.count < limit {
            kept.append(contentsOf: overflow.prefix(limit - kept.count))
        }
        return kept
    }

    /// What this listener already has, strongest first — the places a walk is
    /// worth starting from.
    ///
    /// Three sources, deliberately not averaged: keeping something, listening
    /// to it, and going back to its page are different claims, and the
    /// strongest is the honest reading. Somebody who crated a record once and
    /// never played it still knows it.
    private func knownGround() -> [(node: MusicNode, weight: Double)] {
        var found: [String: (node: MusicNode, weight: Double)] = [:]

        func note(_ node: MusicNode, weight: Double) {
            guard !node.key.isEmpty else { return }
            if let existing = found[node.id], existing.weight >= weight { return }
            found[node.id] = (node, weight)
        }

        for item in CrateService(context: context).items().prefix(60) {
            guard let node = item.node else { continue }
            note(node, weight: 0.8)
        }
        let log = ListeningLog(context: context)
        let met = log.recent(limit: 80)
        let loudest = met.map(\.weight).max() ?? 1
        for entry in met where entry.weight > 0 {
            note(entry.node, weight: 0.5 + 0.5 * min(1, entry.weight / max(0.001, loudest)))
        }
        for visit in DigHistory(context: context).haunts(
            kinds: [.artist, .label, .broadcast], limit: 12
        ) {
            note(visit.node, weight: 0.6)
        }

        return found.values.sorted {
            $0.weight == $1.weight ? $0.node.id < $1.node.id : $0.weight > $1.weight
        }
    }
}
