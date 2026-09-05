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
    /// What sort of route this was, so a block of twelve is not twelve of the
    /// same kind of thing.
    let kind: RelationshipKind
    /// How many different things in this collection reach it. One is ordinary;
    /// more than one is the strongest argument this engine can make.
    let corroboration: Int
    let score: Double

    var id: String { node.id }

    /// The line under the card: what this is, and what it came from.
    ///
    /// The origin is dropped when the reason already names it — a show offered
    /// because it played somebody you keep has said so, and "· via Aphex Twin"
    /// after "Played Aphex Twin, who you keep" is the same fact twice.
    var connection: String {
        guard !reason.contains(via) else { return reason }
        guard corroboration > 1 else { return "\(reason) · via \(via)" }
        return "\(reason) · via \(via) and \(corroboration - 1) more"
    }
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
        // How many different things they keep reach the same place. Two
        // separate routes to somebody is a much better argument than one, and
        // without it a dozen collaborator edges of identical weight tie and
        // fall back on alphabetical order — which is how a real collection
        // produced a list beginning Aksak Maboul, Blue Foundation, Blue
        // Iverson, Bottlesmoker.
        var reach: [String: Set<String>] = [:]
        for origin in known.prefix(Self.origins) {
            for connection in graph.neighbors(of: origin.node).byDestination {
                let node = connection.node
                // Nowhere to land is not a suggestion. A node with no page is
                // a row that looks like a link and does nothing.
                guard node.destination != nil else { continue }
                guard !seen.contains(node.id) else { continue }
                guard !log.hasEncountered(node) else { continue }

                // The best *route*, which is not the same as the best-evidenced
                // edge. See `worth(_:)`.
                guard let route = connection.edges
                    .map({ (edge: $0, value: $0.weight * Self.worth($0)) })
                    .filter({ $0.value > 0 })
                    .max(by: { $0.value < $1.value })
                else { continue }

                reach[node.id, default: []].insert(origin.node.id)
                let score = route.value * origin.weight
                if let existing = best[node.id], existing.score >= score { continue }
                best[node.id] = ExploreSuggestion(
                    node: node,
                    reason: route.edge.reason,
                    via: origin.node.title,
                    kind: route.edge.kind,
                    corroboration: 1,
                    score: score
                )
            }
        }
        // Applied after the walk, when every route to a place is known.
        for (id, origins) in reach where origins.count > 1 {
            guard let found = best[id] else { continue }
            best[id] = ExploreSuggestion(
                node: found.node, reason: found.reason, via: found.via, kind: found.kind,
                corroboration: origins.count,
                score: found.score * (1 + 0.22 * Double(origins.count - 1))
            )
        }
        // Shows judged on their tracklists, which the graph cannot reach.
        //
        // An edge to a broadcast exists only where an artist's records are in
        // the local store *and* carry an appearance — five of those across a
        // whole crate, while the appearance log held eighteen complete
        // tracklists nobody was reading. See `ShowSuggestionEngine`.
        let fromTracklists = ShowSuggestionEngine(context: context).suggestions(
            taste: TasteProfile.collected(context: context),
            known: seen,
            keptArtistKeys: Set(known.compactMap {
                $0.node.kind == .artist ? $0.node.key : nil
            })
        )
        for suggestion in fromTracklists {
            guard let existing = best[suggestion.id] else {
                best[suggestion.id] = suggestion
                continue
            }
            // Found both ways. Keep whichever score is better evidenced, and
            // the tracklist's sentence either way: "Played Aphex Twin, who you
            // keep" says something, and the graph's "Played on NTS / 239EF"
            // only repeats the name already printed on the card.
            best[suggestion.id] = ExploreSuggestion(
                node: suggestion.node, reason: suggestion.reason, via: suggestion.via,
                kind: suggestion.kind,
                corroboration: max(existing.corroboration, suggestion.corroboration),
                score: max(existing.score, suggestion.score)
            )
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
    /// And at most this many by the same sort of route.
    ///
    /// Collaboration is the most valuable route there is, which means that
    /// left alone it takes every row: the block became twelve people who had
    /// been credited alongside something, and the label and radio
    /// neighbourhoods — the two things Indigo knows that a catalogue does not
    /// — never appeared at all.
    static let perKind = 6
    /// And at least this many shows, when there are any to offer.
    ///
    /// A show does not compete on the same scale as an artist and should not
    /// have to. It is an hour of somebody's taste that can be put on now,
    /// where an artist is a page to read — and on a real collection the
    /// available shows scored below every labelmate, so a block of twelve had
    /// none in it at all. Reserved rather than reweighted, because inflating
    /// the score would have said the evidence was better than it is.
    static let showFloor = 3

    private static func spread(
        _ ranked: [ExploreSuggestion], limit: Int
    ) -> [ExploreSuggestion] {
        var kept: [ExploreSuggestion] = []
        var chosen = Set<String>()
        var byOrigin: [String: Int] = [:]
        var byKind: [RelationshipKind: Int] = [:]
        // Two episodes of one programme are two nodes and one name. Both
        // showed up as cards reading "239EF", which to anybody looking at the
        // page is the same suggestion printed twice.
        var titles = Set<String>()

        func take(_ suggestion: ExploreSuggestion) {
            byOrigin[suggestion.via, default: 0] += 1
            byKind[suggestion.kind, default: 0] += 1
            chosen.insert(suggestion.id)
            titles.insert(RecordingKey.normalize(suggestion.node.title))
            kept.append(suggestion)
        }

        func isNew(_ suggestion: ExploreSuggestion) -> Bool {
            !chosen.contains(suggestion.id)
                && !titles.contains(RecordingKey.normalize(suggestion.node.title))
        }

        // Filled in three passes, each one giving up a rule the one before it
        // kept. A collection with a single well-connected record in it has
        // nothing to spread across, and a block of three where twelve were
        // asked for is worse than a lopsided twelve — but route variety is
        // given up last, because it is the difference between "here are
        // twelve people credited alongside something" and a list that has the
        // label and the radio neighbourhoods in it.
        func fill(origins: Bool, kinds: Bool) {
            for suggestion in ranked {
                guard kept.count < limit else { return }
                guard isNew(suggestion) else { continue }
                if origins, byOrigin[suggestion.via, default: 0] >= perOrigin { continue }
                if kinds, byKind[suggestion.kind, default: 0] >= perKind { continue }
                take(suggestion)
            }
        }
        // The reserved show slots are claimed before anything competes for
        // them, and then given up: the block reads in score order, so what
        // is reserved is a place on the page rather than a place at the top.
        for suggestion in ranked
        where suggestion.node.kind == .broadcast && isNew(suggestion) {
            guard kept.count < min(showFloor, limit) else { break }
            take(suggestion)
        }
        fill(origins: true, kinds: true)
        fill(origins: false, kinds: true)
        fill(origins: false, kinds: false)
        return kept.sorted {
            $0.score == $1.score ? $0.node.title < $1.node.title : $0.score > $1.score
        }
    }

    /// How much a kind of connection is worth *going down*, which is a
    /// different question from how sure Indigo is that it is true.
    ///
    /// The two came apart the moment this block was looked at. An alias is the
    /// best-evidenced edge in the whole graph — it scores higher than anything
    /// else — and it is worth nothing at all as a suggestion, because it is
    /// the same person under another name. "Also records as Kate NV" offered
    /// to somebody who keeps Kate NV is not a discovery, it is a spelling.
    ///
    /// What is worth going down is somebody else: who they made records with,
    /// who else is on their label, who gets played beside them. Those are the
    /// three that a catalogue and a radio schedule can actually establish, and
    /// they are what this block now favours.
    ///
    /// Zero means never offered, however certain the edge.
    static func worth(_ edge: MusicEdge) -> Double {
        // Radio is the one place where what you are being sent to matters as
        // much as why. A show is a thing you can put on — it has a tracklist,
        // an hour of somebody's taste, and a page — whereas an artist who
        // merely turned up in the same episode is the thinnest connection
        // radio can make. So the route to the show is the one worth taking,
        // and the sideways hop to a stranger is demoted below almost
        // everything else.
        if edge.kind == .playedInShow {
            return edge.to.kind == .broadcast ? 0.96 : 0.7
        }
        return worth(kind: edge.kind)
    }

    static func worth(kind: RelationshipKind) -> Double {
        switch kind {
        // The same person, or something already yours. Not somewhere to go.
        case .sameAlias, .sameArtist, .inYourLibrary, .inYourCrate: 0

        // Another person, established by a record that names them both.
        case .collaborator: 1
        case .producer: 0.98
        case .personnel: 0.94

        // The label neighbourhood.
        case .sharedLabel: 0.92

        // Handled above, where the destination is known.
        case .playedInShow: 0.96

        // Artists reached sideways through radio. A selector reaching for two
        // records across a run of shows means something; two names in one
        // episode means they were an hour apart.
        case .frequentlyPlayedNearby: 0.55
        case .playedBySameSelector: 0.5
        case .sharedBroadcast: 0.35

        // A record with both of them on it.
        case .sameRelease, .appearsOnRelease: 0.72
        case .sharedCollection, .sharedCratePattern: 0.6

        // A group somebody is part of is a different body of work, but it is
        // still largely the same people, so it sits below all of the above.
        case .aliasOrProject: 0.3

        // Resemblance rather than connection. Offered only when nothing
        // better was found.
        case .sharedStyle: 0.28
        case .sameScene, .sameCity, .sameEra: 0.25
        case .sameUserTrail: 0.4
        case .manualRelation: 0.8
        }
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
