//
//  MusicianFirstRanker.swift
//  Indigo
//
//  For You and DIG, musician-first and aware of long-term taste: a shadow of
//  `ExploreRanker`, worked out from the same arguments and nothing else, so
//  the two can be compared on one listener's rows. Nothing visible reads it
//  unless `MusicianFirst` is on.
//
//  Where `ExploreRanker` starts: the strongest of the newest sixty crate
//  items, the eighty things met most recently (scaled to the loudest of
//  them), and the dozen pages most returned to -- twelve places, and on a tie
//  the alphabet. What was crated today arrives twice (kept, and met as a
//  `.saved` event at 1.5, the heaviest event there is), so it ranks with the
//  loudest; what was kept or played a month ago and not since cannot start a
//  walk at all once eighty newer things have been met.
//
//  Here the starting points are two halves, chosen apart:
//  - **Now**: up to four places touched in the last fortnight, by weight
//    decayed with a week's half-life -- what the listener is into today. A
//    record crated counts double a play, so crating one is noticed at once.
//  - **Over time**: the rest from the whole of what is kept, played and
//    returned to, undecayed and logarithmic in repetition, so a record played
//    forty times outweighs one played twice without drowning the collection;
//    at most two from any one artist, so one discography cannot fill it.
//
//  And the routes out of them are valued musician-first: a bandmate, a player,
//  a writer or a producer above a labelmate; a group somebody is in counts as
//  a place to go (the band), not as their other name. Then three questions the
//  old ranking did not ask: does it sound like what they have liked over time
//  (`candidateTags` against the long-term `TasteProfile`), is it reached by
//  more than one kind of fact, and does it lead anywhere (`onward`: the
//  musician routes out of it, when known). Missing data is neutral, never a
//  penalty: an artist does not need a biography or a long discography.
//

import Foundation

nonisolated enum MusicianFirstRanker {
    /// How many of the twelve starting points are what is happening now.
    static let nowShare = 4
    /// What counts as now, and how fast it fades within that.
    static let nowWindow: TimeInterval = 14 * 24 * 60 * 60
    static let nowHalfLife: TimeInterval = 7 * 24 * 60 * 60
    /// At most this many long-term starting points from one artist.
    static let perArtist = 2

    /// A starting point, and which half chose it.
    struct Origin: Equatable, Sendable {
        let node: MusicNode
        let weight: Double
        let half: Half
    }

    enum Half: String, Sendable { case now, overTime }

    // MARK: Where to start

    /// What the listener is into now: touched in the last fortnight, by weight
    /// decayed with a week's half-life. Kept and met are added, so a record
    /// crated and then played counts for both.
    static func nowGround(_ personal: PersonalInputs, asOf: Date) -> [(node: MusicNode, weight: Double)] {
        var score: [String: (node: MusicNode, weight: Double)] = [:]
        func add(_ node: MusicNode, _ weight: Double, at: Date) {
            let age = asOf.timeIntervalSince(at)
            guard !node.key.isEmpty, age <= nowWindow else { return }
            let decayed = weight * pow(0.5, max(0, age) / nowHalfLife)
            let held = score[node.id]
            score[node.id] = (held.map { MusicNode.preferred($0.node, node) } ?? node, (held?.weight ?? 0) + decayed)
        }
        // Crating is a decision and the strongest claim on what someone is
        // into now; a station played all week should not outweigh it.
        for item in personal.crate { if let node = item.node { add(node, 2.0, at: item.addedAt) } }
        // A play is attention, counted once however often: a week of one
        // station, or a record crated and played this morning, must not keep
        // what was crated a moment ago out of the four.
        for met in personal.met where met.weight > 0 { add(met.node, min(met.weight, 1), at: met.lastAt) }
        return ordered(score)
    }

    /// What the listener has cared about over the whole of what is kept:
    /// everything crated, everything met, every page returned to.
    static func overTimeGround(_ personal: PersonalInputs) -> [(node: MusicNode, weight: Double)] {
        var score: [String: (node: MusicNode, weight: Double)] = [:]
        func add(_ node: MusicNode, _ weight: Double) {
            guard !node.key.isEmpty, weight > 0 else { return }
            let held = score[node.id]
            score[node.id] = (held.map { MusicNode.preferred($0.node, node) } ?? node, (held?.weight ?? 0) + weight)
        }
        // Keeping is a standing statement; repetition counts, logarithmically.
        for item in personal.crate { if let node = item.node { add(node, 1.0) } }
        for met in personal.met where met.weight > 0 { add(met.node, 0.5 * log2(1 + met.weight)) }
        for haunt in personal.haunts { add(haunt.node, 0.4 * log2(1 + Double(haunt.visits))) }
        return ordered(score)
    }

    /// Strongest first; on a tie by node, so every device agrees.
    private static func ordered(_ score: [String: (node: MusicNode, weight: Double)]) -> [(node: MusicNode, weight: Double)] {
        score.values.sorted {
            $0.weight == $1.weight ? $0.node.presentationKey < $1.node.presentationKey : $0.weight > $1.weight
        }
    }

    /// The artist a starting point belongs to, for the per-artist cap: a kept
    /// item's own artist, an artist's own key, or the node's key.
    static func artistKey(of node: MusicNode, in personal: PersonalInputs) -> String {
        if node.kind == .artist { return node.key }
        if let kept = personal.crate.first(where: { $0.node?.id == node.id }),
           let key = kept.sceneArtistKey ?? kept.tasteArtistKeys.first {
            return key
        }
        if let subtitle = node.subtitle, !subtitle.isEmpty, node.kind == .release || node.kind == .recording {
            return RecordingKey.normalizeArtist(subtitle)
        }
        return node.key
    }

    /// Twelve starting points: up to four from now, the rest over time.
    static func startingPoints(_ personal: PersonalInputs, asOf: Date,
                               count: Int = ExploreSuggestionEngine.origins) -> [Origin] {
        var chosen: [Origin] = []
        var ids = Set<String>()
        let now = nowGround(personal, asOf: asOf)
        let loudestNow = now.first?.weight ?? 1
        for entry in now.prefix(min(nowShare, count)) {
            // 0.8 to 1: today's interest is the strongest single claim.
            chosen.append(Origin(node: entry.node, weight: 0.8 + 0.2 * entry.weight / max(0.001, loudestNow), half: .now))
            ids.insert(entry.node.id)
        }
        let overTime = overTimeGround(personal)
        let loudest = overTime.first?.weight ?? 1
        var byArtist: [String: Int] = [:]
        for origin in chosen { byArtist[artistKey(of: origin.node, in: personal), default: 0] += 1 }
        for entry in overTime where chosen.count < count && !ids.contains(entry.node.id) {
            let artist = artistKey(of: entry.node, in: personal)
            guard byArtist[artist, default: 0] < perArtist else { continue }
            byArtist[artist, default: 0] += 1
            ids.insert(entry.node.id)
            // 0.5 to 0.9: the collection, a shade under what is happening now.
            chosen.append(Origin(node: entry.node, weight: 0.5 + 0.4 * entry.weight / max(0.001, loudest), half: .overTime))
        }
        return chosen
    }

    // MARK: Where to go

    /// What a kind of route is worth going down, musician-first. The same
    /// scale as `ExploreSuggestionEngine.worth`, changed only where it put a
    /// label or a stranger in the same episode beside a musician, or treated
    /// a band as somebody's other name.
    static func worth(_ edge: MusicEdge) -> Double {
        switch edge.kind {
        // The band somebody is in, or the people in it: somewhere to go.
        case .aliasOrProject: return 0.85
        // A label is a neighbourhood, not a musician: below every musician
        // route, above resemblance.
        case .sharedLabel: return 0.6
        default: return ExploreSuggestionEngine.worth(edge)
        }
    }

    /// Whether a kind of route is a musician one, for corroboration and for
    /// what "leads on" means.
    static func isMusicianRoute(_ kind: RelationshipKind) -> Bool {
        switch kind {
        case .collaborator, .producer, .personnel, .aliasOrProject, .sameRelease, .appearsOnRelease: true
        default: false
        }
    }

    /// How much it sounds like what they have liked over time: neutral when
    /// nothing is known of it, which is not evidence against it.
    static func relevance(_ tags: [String]?, taste: TasteProfile) -> Double {
        guard let tags, !tags.isEmpty, !taste.isEmpty else { return 0.9 }
        return 0.8 + 0.4 * taste.affinity(for: tags)
    }

    /// Whether it leads anywhere: unknown is neutral; a place with no
    /// musician route out of it is a dead end, demoted rather than dropped --
    /// and never below a labelmate: the drummer on the record is still worth
    /// meeting when Discogs knows nothing more of them.
    static func onwardFactor(_ count: Int?) -> Double {
        guard let count else { return 1 }
        switch count {
        case 0: return 0.75
        case 1...2: return 0.9
        default: return 1
        }
    }

    /// Everywhere worth going, best first, from the same knowledge as
    /// `ExploreRanker.suggestions` (built with `MusicianFirst` on, for the
    /// technical credits to be gone), and two lookups it does not have:
    /// `candidateTags` (styles and genres by artist key) and `onward` (musician
    /// routes out of a place, by node id). Both may be empty.
    static func suggestions(
        personal: PersonalInputs, knowledge: KnowledgeSnapshot, taste: TasteProfile, asOf: Date,
        candidateTags: [String: [String]] = [:], onward: [String: Int] = [:],
        limit: Int = 12, alsoKnown: Set<String> = []
    ) -> [ExploreSuggestion] {
        let origins = startingPoints(personal, asOf: asOf)
        guard !origins.isEmpty else { return [] }

        // Everything kept is known, not only the newest sixty.
        let seen = Set(origins.map(\.node.id)).union(personal.crate.compactMap { $0.node?.id })
        let encountered = Set(personal.met.map(\.node.id)).union(alsoKnown)
        let neighbourhoods = ExploreRanker.edgeSets(knowledge)

        var best: [String: ExploreSuggestion] = [:]
        var reach: [String: Set<String>] = [:]
        var kinds: [String: Set<RelationshipKind>] = [:]
        // Where the best route came from what they are into now: judged by
        // that, not by how well it fits what they liked before.
        var fromNow = Set<String>()
        for origin in origins {
            for connection in (neighbourhoods[origin.node] ?? EdgeSet()).byDestination {
                let node = connection.node
                guard node.destination != nil, !seen.contains(node.id), !encountered.contains(node.id) else { continue }
                // A catalogue number is a filing detail, not somewhere to go.
                guard node.kind != .catalogNumber else { continue }
                guard let route = connection.edges
                    .map({ (edge: $0, value: $0.weight * worth($0)) })
                    .filter({ $0.value > 0 })
                    .min(by: { $0.value != $1.value ? $0.value > $1.value : MusicEdge.precedes($0.edge, $1.edge) })
                else { continue }
                reach[node.id, default: []].insert(origin.node.id)
                for edge in connection.edges where worth(edge) > 0 { kinds[node.id, default: []].insert(edge.kind) }
                let score = route.value * origin.weight
                if let existing = best[node.id], existing.score >= score { continue }
                best[node.id] = ExploreSuggestion(
                    node: node, reason: route.edge.reason, via: origin.node.title, kind: route.edge.kind,
                    corroboration: 1, score: score
                )
                if origin.half == .now { fromNow.insert(node.id) } else { fromNow.remove(node.id) }
            }
        }
        for (id, found) in best {
            let origins = reach[id]?.count ?? 1
            let musicianKinds = (kinds[id] ?? []).filter(isMusicianRoute)
            // Two kinds of fact agreeing -- played on it and on the label --
            // is independent; two edges of one kind are not.
            let independent = (kinds[id]?.count ?? 0) >= 2 && !musicianKinds.isEmpty ? 1.1 : 1
            let tags = found.node.kind == .artist ? candidateTags[found.node.key] : nil
            let score = found.score
                * (1 + 0.22 * Double(origins - 1))
                * independent
                * (found.node.kind == .artist && !fromNow.contains(id) ? relevance(tags, taste: taste) : 1)
                * (found.node.kind == .artist ? onwardFactor(onward[id]) : 1)
            best[id] = ExploreSuggestion(node: found.node, reason: found.reason, via: found.via, kind: found.kind,
                                         corroboration: origins, score: score)
        }
        let fromTracklists = ExploreRanker.shows(
            knowledge.shared.shows, taste: taste, known: seen,
            keptArtistKeys: Set(origins.compactMap { $0.node.kind == .artist ? $0.node.key : nil })
                .union(personal.tasteArtistKeys),
            encountered: encountered
        )
        for suggestion in fromTracklists {
            guard let existing = best[suggestion.id] else { best[suggestion.id] = suggestion; continue }
            best[suggestion.id] = ExploreSuggestion(
                node: suggestion.node, reason: suggestion.reason, via: suggestion.via, kind: suggestion.kind,
                corroboration: max(existing.corroboration, suggestion.corroboration),
                score: max(existing.score, suggestion.score)
            )
        }
        // A label is a neighbourhood: a few of its roster, never the list.
        var labels = 0
        let ranked = best.values.sorted(by: ExploreSuggestion.ranksAhead).filter { suggestion in
            guard suggestion.kind == .sharedLabel else { return true }
            labels += 1
            return labels <= labelCap
        }
        return ExploreSuggestionEngine.spread(ranked, limit: limit)
    }

    /// The blocks For You shows, cut as `ExploreRanker.recommendations`
    /// cuts them: where to go next, shows, more artists.
    static func recommendations(
        personal: PersonalInputs, knowledge: KnowledgeSnapshot, taste: TasteProfile, asOf: Date,
        candidateTags: [String: [String]], onward: [String: Int],
        next: Int = 12, shows: Int = 6, artists: Int = 6, alsoKnown: Set<String> = []
    ) -> ExploreOffers {
        let all = suggestions(personal: personal, knowledge: knowledge, taste: taste, asOf: asOf,
                              candidateTags: candidateTags, onward: onward,
                              limit: next + artists + shows, alsoKnown: alsoKnown)
        var offers = ExploreOffers()
        offers.shows = Array(all.filter { $0.node.kind == .broadcast }.prefix(shows))
        let rest = all.filter { $0.node.kind != .broadcast }
        offers.next = Array(rest.prefix(next))
        let taken = Set(offers.next.map(\.id))
        offers.artists = Array(rest.filter { $0.node.kind == .artist && !taken.contains($0.id) }.prefix(artists))
        return offers
    }

    /// At most this many labelmates in one list.
    static let labelCap = 3
}
