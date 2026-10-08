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
nonisolated struct ExploreSuggestion: Identifiable, Sendable, Codable {
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

    /// Best first: score, then name, then id. Two things of one name -- an
    /// artist and the label named after them -- used to tie, and came out in
    /// whatever order a dictionary held them, which also decided which of the
    /// two the page's one-per-name rule kept.
    static func ranksAhead(_ left: ExploreSuggestion, _ right: ExploreSuggestion) -> Bool {
        if left.score != right.score { return left.score > right.score }
        if left.node.title != right.node.title { return left.node.title < right.node.title }
        return left.id < right.id
    }

    /// How far outside charted territory this sits, 0…1.
    ///
    /// EXPLORE draws a map, and on a map position is an argument. Until now
    /// it was not one: a card's distance from the spine came out of a cosine
    /// of its ordinal, which is to say the layout was decorated rather than
    /// drawn, and two things sitting side by side meant only that they had
    /// been counted next to each other.
    ///
    /// Corroboration is the honest axis for it. One route to somewhere is the
    /// frontier however good that route is; four separate things this listener
    /// keeps arriving at the same place is not a frontier at all — it is a gap
    /// in the middle of ground they have already charted, and it should be
    /// drawn where the rest of that ground is. Strength only breaks ties
    /// within a reach, because a strong single edge is still a single edge.
    var frontier: Double {
        let reach = 1 - 1 / Double(max(1, corroboration))
        let strength = min(1, max(0, score))
        return min(1, max(0, 1 - (reach * 0.65 + strength * 0.35)))
    }

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

/// Everything EXPLORE has to offer, sorted into the places it goes.
///
/// One walk produces all of it. The page shows shows, artists and the rest in
/// different blocks, and computing them separately would mean walking the
/// graph three times to answer one question.
nonisolated struct ExploreOffers: Sendable, Codable {
    /// Mixed, minus shows — they have a block of their own.
    var next: [ExploreSuggestion] = []
    /// Radio worth an hour.
    var shows: [ExploreSuggestion] = []
    /// The scene this listener is heading into, when they are heading
    /// anywhere. See `SceneEngine.movingToward(taste:)`.
    var movingToward: SceneOffer?
    /// Further artists, for the crate's own artists block. Deliberately the
    /// ones `next` did not take: the same face twice on one page is a page
    /// that has run out of things to say.
    var artists: [ExploreSuggestion] = []

    var isEmpty: Bool { next.isEmpty && shows.isEmpty && artists.isEmpty && movingToward == nil }

    /// A scene, flattened to what the page draws. `MusicScene` is not
    /// `Sendable` all the way down and does not need to cross the actor
    /// boundary — a name, a sound and a size do.
    nonisolated struct SceneOffer: Sendable, Codable {
        let city: String
        let title: String
        let sound: String
        let size: String
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

    /// The dig history's share of the starting points, as `PersonalInputs`
    /// reads it.
    static let hauntKinds: Set<MusicNodeKind> = [.artist, .label, .broadcast]
    static let hauntLimit = 12

    /// Everything the page needs, worked out from this store.
    ///
    /// `asOf` is the moment listening is weighed from -- how far back a play
    /// was is the one thing here that depends on when it is asked. It is
    /// passed in, never read off the clock, so the same rows give the same
    /// answer whenever and wherever they are worked out.
    ///
    /// The work is three steps: the listener's rows (`PersonalInputs`), what
    /// is known around them (`LocalKnowledgeAdapter`), and the ranking
    /// (`ExploreRanker`), which reads nothing but those two. EXPLORE itself
    /// runs them separately on the worker, so it can tell which one changed;
    /// this is the same thing for a caller that only wants the answer.
    func offers(next: Int = 12, shows: Int = 6, artists: Int = 6, asOf: Date) -> ExploreOffers {
        let (personal, knowledge) = inputs(asOf: asOf, scenes: true)
        return ExploreRanker.offers(personal: personal, knowledge: knowledge, asOf: asOf,
                                    next: next, shows: shows, artists: artists)
    }

    /// The blocks somebody can act on: where to go next, shows, more artists.
    func recommendations(
        next: Int = 12, shows: Int = 6, artists: Int = 6, taste: TasteProfile? = nil, asOf: Date
    ) -> ExploreOffers {
        let (personal, knowledge) = inputs(asOf: asOf, scenes: false)
        return ExploreRanker.recommendations(
            personal: personal, knowledge: knowledge,
            taste: taste ?? ExploreRanker.taste(personal: personal, knowledge: knowledge, asOf: asOf),
            next: next, shows: shows, artists: artists
        )
    }

    /// Where this listener is heading, which is the slow half.
    func direction(taste: TasteProfile? = nil, asOf: Date) -> ExploreOffers.SceneOffer? {
        let (personal, knowledge) = inputs(asOf: asOf, scenes: true)
        return ExploreRanker.direction(
            personal: personal, knowledge: knowledge,
            taste: taste ?? ExploreRanker.taste(personal: personal, knowledge: knowledge, asOf: asOf),
            turn: nil
        )
    }

    /// Everywhere worth going, best first.
    func suggestions(limit: Int = 12, taste: TasteProfile? = nil, asOf: Date) -> [ExploreSuggestion] {
        let (personal, knowledge) = inputs(asOf: asOf, scenes: false)
        return ExploreRanker.suggestions(
            personal: personal, knowledge: knowledge,
            taste: taste ?? ExploreRanker.taste(personal: personal, knowledge: knowledge, asOf: asOf),
            limit: limit
        )
    }

    private func inputs(asOf: Date, scenes: Bool) -> (PersonalInputs, KnowledgeSnapshot) {
        let personal = PersonalInputs.read(context: context, asOf: asOf)
        let adapter = LocalKnowledgeAdapter(context: context)
        return (personal, adapter.snapshot(for: personal, scenes: scenes))
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

    static func spread(
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
        return kept.sorted(by: ExploreSuggestion.ranksAhead)
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
}

nonisolated extension Array where Element == ExploreSuggestion {
    /// The same offers, regrouped so everything reached from one place in the
    /// collection sits together.
    ///
    /// Ranked by score alone, a cluster is invisible: four artists reached
    /// out of the same crated label land in first, fourth, seventh and
    /// eleventh place, separated by four unrelated people, and the one thing
    /// the arrangement could have said — that these belong together — is the
    /// thing it does not say. Adjacency is what makes a cluster a cluster.
    ///
    /// Origins keep the order their strongest offer gave them, and offers keep
    /// theirs within an origin, so the best thing on the page is still the
    /// first thing on it. This regroups; it does not re-rank.
    func clusteredByOrigin() -> [ExploreSuggestion] {
        var order: [String] = []
        var clusters: [String: [ExploreSuggestion]] = [:]
        for suggestion in self {
            if clusters[suggestion.via] == nil { order.append(suggestion.via) }
            clusters[suggestion.via, default: []].append(suggestion)
        }
        return order.flatMap { clusters[$0] ?? [] }
    }
}
