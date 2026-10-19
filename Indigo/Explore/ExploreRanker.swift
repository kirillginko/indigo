//
//  ExploreRanker.swift
//  Indigo
//
//  For You, worked out from its arguments and nothing else.
//
//  Everything here is a function of `PersonalInputs`, a `KnowledgeSnapshot`
//  and an `asOf`: no store, no cache, no network, no defaults, no clock. That
//  is what lets two devices be compared at all -- the same three arguments
//  give the same offers, and different offers come from arguments that can be
//  shown to differ. See `ExploreKnowledge.swift`.
//
//  This is the engine `ExploreSuggestionEngine` and `ShowSuggestionEngine`
//  used to run against the store, moved rather than rewritten: each step is
//  the same arithmetic in the same order, which `ExploreGoldenTests` holds it
//  to bit for bit.
//

import Foundation

nonisolated enum ExploreRanker {
    /// Offers for the page. `turn` picks which direction is named (EXPLORE
    /// passes its period); nil names the first.
    /// `alsoKnown` is node ids the listener is known to have beyond their own
    /// rows — see `KnownArtistPolicy`. Empty, the answer is exactly as before.
    static func offers(
        personal: PersonalInputs, knowledge: KnowledgeSnapshot, asOf: Date,
        next: Int = 12, shows: Int = 6, artists: Int = 6, turn: Int? = nil,
        alsoKnown: Set<String> = []
    ) -> ExploreOffers {
        let taste = Self.taste(personal: personal, knowledge: knowledge, asOf: asOf)
        var offers = recommendations(personal: personal, knowledge: knowledge, taste: taste,
                                     next: next, shows: shows, artists: artists, alsoKnown: alsoKnown)
        offers.movingToward = direction(personal: personal, knowledge: knowledge, taste: taste, turn: turn)
        return offers
    }

    /// The blocks somebody can act on: where to go next, shows, more artists.
    static func recommendations(
        personal: PersonalInputs, knowledge: KnowledgeSnapshot, taste: TasteProfile,
        next: Int = 12, shows: Int = 6, artists: Int = 6, alsoKnown: Set<String> = []
    ) -> ExploreOffers {
        let all = suggestions(personal: personal, knowledge: knowledge, taste: taste,
                              limit: next + artists + shows, alsoKnown: alsoKnown)
        var offers = ExploreOffers()
        offers.shows = Array(all.filter { $0.node.kind == .broadcast }.prefix(shows))
        let rest = all.filter { $0.node.kind != .broadcast }
        offers.next = Array(rest.prefix(next))
        let taken = Set(offers.next.map(\.id))
        offers.artists = Array(
            rest.filter { $0.node.kind == .artist && !taken.contains($0.id) }.prefix(artists)
        )
        return offers
    }

    static func taste(personal: PersonalInputs, knowledge: KnowledgeSnapshot, asOf: Date) -> TasteProfile {
        TasteProfile.collected(personal: personal, artistTags: knowledge.shared.artistTags, now: asOf)
    }

    // MARK: Where to start

    /// What this listener already has, strongest first — the places a walk is
    /// worth starting from.
    ///
    /// Three sources, deliberately not averaged: keeping something, listening
    /// to it, and going back to its page are different claims, and the
    /// strongest is the honest reading. Somebody who crated a record once and
    /// never played it still knows it.
    static func knownGround(_ personal: PersonalInputs) -> [(node: MusicNode, weight: Double)] {
        var found: [String: (node: MusicNode, weight: Double)] = [:]

        // The strongest claim on a node, and on a tie the better-identified
        // spelling of it: the origin's title is printed as "via", and which
        // spelling arrived first was the order of three different reads.
        func note(_ node: MusicNode, weight: Double) {
            guard !node.key.isEmpty else { return }
            if let existing = found[node.id] {
                if existing.weight > weight { return }
                if existing.weight == weight {
                    found[node.id] = (MusicNode.preferred(existing.node, node), weight)
                    return
                }
            }
            found[node.id] = (node, weight)
        }

        // The newest sixty. Only these count as already known -- an older
        // record can be offered back, which is a known quirk kept as it was.
        for item in personal.crate.prefix(60) {
            guard let node = item.node else { continue }
            note(node, weight: 0.8)
        }
        let met = recent(personal, limit: 80)
        let loudest = met.map(\.weight).max() ?? 1
        for entry in met where entry.weight > 0 {
            note(entry.node, weight: 0.5 + 0.5 * min(1, entry.weight / max(0.001, loudest)))
        }
        for visit in personal.haunts {
            note(visit.node, weight: 0.6)
        }

        return found.values.sorted {
            $0.weight == $1.weight ? $0.node.presentationKey < $1.node.presentationKey : $0.weight > $1.weight
        }
    }

    /// The starting points a walk goes out of: the neighbourhoods a snapshot
    /// has to hold. Everything else For You considers -- every tracklist,
    /// every scene -- is offered whatever is kept, and is not scoped by this.
    static func startingPoints(_ personal: PersonalInputs) -> [MusicNode] {
        knownGround(personal).prefix(ExploreSuggestionEngine.origins).map(\.node)
    }

    /// What was met most recently, as `ListeningLog.recent` orders it.
    static func recent(_ personal: PersonalInputs, limit: Int) -> [PersonalInputs.Met] {
        Array(personal.met
            .sorted { $0.lastAt == $1.lastAt ? $0.node.presentationKey < $1.node.presentationKey : $0.lastAt > $1.lastAt }
            .prefix(limit))
    }

    // MARK: Where to go

    /// Everywhere worth going, best first.
    static func suggestions(
        personal: PersonalInputs, knowledge: KnowledgeSnapshot, taste: TasteProfile, limit: Int = 12,
        alsoKnown: Set<String> = []
    ) -> [ExploreSuggestion] {
        let known = knownGround(personal)
        guard !known.isEmpty else { return [] }

        let seen = Set(known.map(\.node.id))
        // Excluded before anything is ranked or cut, never after: what is not
        // offered leaves room for the next candidate.
        let encountered = Set(personal.met.map(\.node.id)).union(alsoKnown)
        let neighbourhoods = edgeSets(knowledge)

        var best: [String: ExploreSuggestion] = [:]
        // How many different things they keep reach the same place. Two
        // separate routes to somebody is a much better argument than one, and
        // without it a dozen collaborator edges of identical weight tie and
        // fall back on alphabetical order — which is how a real collection
        // produced a list beginning Aksak Maboul, Blue Foundation, Blue
        // Iverson, Bottlesmoker.
        var reach: [String: Set<String>] = [:]
        for origin in known.prefix(ExploreSuggestionEngine.origins) {
            for connection in (neighbourhoods[origin.node] ?? EdgeSet()).byDestination {
                let node = connection.node
                // Nowhere to land is not a suggestion. A node with no page is
                // a row that looks like a link and does nothing.
                guard node.destination != nil else { continue }
                guard !seen.contains(node.id) else { continue }
                guard !encountered.contains(node.id) else { continue }

                // The best *route*, which is not the same as the best-evidenced
                // edge. See `ExploreSuggestionEngine.worth(_:)`. Equal routes
                // are told apart by what they say, not by which the walk
                // listed first: the route is the reason printed and the kind
                // the block spreads across.
                //
                // Only routes that are a reason to go to somebody: a credit for
                // mixing or mastering the listener's record is true, stays on
                // the release page, and recommends nobody. Classified by the
                // relationship, never the person -- whoever also played on it
                // is reached as the player. See `ContributorRole`.
                guard let route = connection.edges
                    .filter(ContributorRole.canRecommend)
                    .map({ (edge: $0, value: $0.weight * ExploreSuggestionEngine.worth($0)) })
                    .filter({ $0.value > 0 })
                    .min(by: { $0.value != $1.value ? $0.value > $1.value : MusicEdge.precedes($0.edge, $1.edge) })
                else { continue }

                reach[node.id, default: []].insert(origin.node.id)
                let score = route.value * origin.weight
                // The origins are walked in a fixed order, strongest first,
                // so a tie keeps the stronger origin's route.
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
        let fromTracklists = shows(
            knowledge.shared.shows,
            taste: taste,
            known: seen,
            keptArtistKeys: Set(known.compactMap { $0.node.kind == .artist ? $0.node.key : nil }),
            encountered: encountered
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

        return ExploreSuggestionEngine.spread(
            best.values.sorted(by: ExploreSuggestion.ranksAhead),
            limit: limit
        )
    }

    /// Each starting point's edges, the shared ones and this device's own
    /// together. They never merge with each other -- the library's are a kind
    /// of their own -- so leaving the device's out leaves the shared ones
    /// exactly as they were.
    static func edgeSets(_ knowledge: KnowledgeSnapshot) -> [MusicNode: EdgeSet] {
        var sets: [MusicNode: EdgeSet] = [:]
        func add(_ table: [MusicNode], _ neighbourhoods: [Neighbourhood]) {
            for neighbourhood in neighbourhoods where table.indices.contains(neighbourhood.origin) {
                let origin = table[neighbourhood.origin]
                var set = sets[origin] ?? EdgeSet()
                for edge in neighbourhood.edges {
                    guard table.indices.contains(edge.from), table.indices.contains(edge.to),
                          let source = RelationshipSource(rawValue: edge.source) else { continue }
                    set.insert(MusicEdge(
                        from: table[edge.from], to: table[edge.to], kind: edge.kind, source: source,
                        reason: edge.reason, confidence: edge.confidence, occurrences: edge.occurrences
                    ))
                }
                sets[origin] = set
            }
        }
        add(knowledge.shared.nodes, knowledge.shared.neighbourhoods)
        add(knowledge.deviceLocal.nodes, knowledge.deviceLocal.neighbourhoods)
        return sets
    }

    // MARK: Shows

    /// A show has to clear this to be offered at all. Low enough that a
    /// station Indigo has barely heard can still say something, high enough
    /// that a tracklist with nothing in common is not dressed up as a match.
    static let showThreshold = 0.18

    /// Radio shows worth putting on, judged by what they actually played: how
    /// many of these people the listener already keeps, and whether the rest
    /// of it sounds like what they listen to. `known` is the node ids they
    /// already have, so a show they crated is not offered back to them.
    static func shows(
        _ profiles: [ShowProfile], taste: TasteProfile, known: Set<String>,
        keptArtistKeys: Set<String>, encountered: Set<String>, limit: Int = 6
    ) -> [ExploreSuggestion] {
        guard !profiles.isEmpty else { return [] }
        var found: [ExploreSuggestion] = []
        for show in profiles.sorted(by: { $0.key < $1.key }) {
            var node = MusicNode.broadcast(providerID: show.providerID, showID: show.showID, title: show.title)
            node.artworkURL = show.artworkURL
            guard node.destination != nil else { continue }
            guard !known.contains(node.id), !encountered.contains(node.id) else { continue }

            // Whose records were played that this listener keeps.
            let familiar = show.artists
                .filter { keptArtistKeys.contains(RecordingKey.normalizeArtist($0)) }
                .sorted()
            // And what the rest of the hour sounded like.
            let affinity = taste.affinity(for: show.tags)

            // Deliberately not a sum. Three artists you keep is a reason on its
            // own and so is an hour of exactly your music; a show with a little
            // of each should not outrank either.
            let byArtists = min(1, Double(familiar.count) / 3)
            let score = max(byArtists, affinity * 0.9)
            guard score >= showThreshold else { continue }

            found.append(ExploreSuggestion(
                node: node,
                reason: ShowSuggestionEngine.reason(familiar: familiar, tags: show.tags, taste: taste, affinity: affinity),
                via: familiar.first ?? "what you listen to",
                kind: .playedInShow,
                corroboration: max(1, familiar.count),
                score: score
            ))
        }
        return found
            .sorted(by: ExploreSuggestion.ranksAhead)
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Where they are heading

    /// Every scene this listener could be said to be heading into, best
    /// first: a few of its artists in the crate (or the library), a sound that
    /// matches what they play, and names still in front of them. The same
    /// rule as `SceneEngine.directions`, with the foothold counted from the
    /// listener's own rows rather than read out of the store.
    static func directions(
        personal: PersonalInputs, knowledge: KnowledgeSnapshot, taste: TasteProfile, limit: Int = 6
    ) -> [SceneCandidate] {
        scoredDirections(personal: personal, knowledge: knowledge, taste: taste, limit: limit).map(\.scene)
    }

    /// The same, with how much of each the listener has a foot in and its
    /// score, for a caller that wants to see why.
    static func scoredDirections(
        personal: PersonalInputs, knowledge: KnowledgeSnapshot, taste: TasteProfile, limit: Int = 6
    ) -> [(scene: SceneCandidate, foothold: Int, score: Double)] {
        guard !taste.isEmpty, let catalogue = knowledge.shared.scenes else { return [] }

        // A foothold: kept, played to some purpose, or in the library.
        var crate: [String: Int] = [:]
        for item in personal.crate {
            if let key = item.sceneArtistKey { crate[key, default: 0] += 1 }
        }
        for (key, count) in personal.artistPlays { crate[key, default: 0] += count }
        var library = knowledge.deviceLocal.libraryCounts
        // A record by both of them is a record for both of them.
        for credit in catalogue.creditMembers.keys.sorted() {
            for member in catalogue.creditMembers[credit] ?? [] {
                crate[member, default: 0] += crate[credit] ?? 0
                library[member, default: 0] += library[credit] ?? 0
            }
        }
        func foothold(_ key: String) -> Int { (crate[key] ?? 0) + (library[key] ?? 0) }

        var scored: [(scene: SceneCandidate, foothold: Int, score: Double)] = []
        for city in catalogue.cities where city.members.contains(where: { foothold($0) > 0 }) {
            for scene in city.scenes {
                let held = scene.members.reduce(0) { $0 + foothold($1) }
                // No foot in it at all is not a direction, it is a stranger.
                guard held > 0, scene.artistCount >= SceneEngine.directionMinimum else { continue }
                let affinity = taste.affinity(for: scene.signature + scene.tags)
                guard affinity > 0.15 else { continue }
                // Enough of a start to mean something, and enough left to be
                // worth going. A scene they have already worked through is
                // somewhere they have been.
                let started = min(1, Double(held) / 3)
                let room = 1 - min(1, Double(held) / Double(scene.artistCount))
                let score = affinity * started * room
                if score > 0 { scored.append((scene, held, score)) }
            }
        }
        return scored
            .sorted { $0.score == $1.score ? $0.scene.id < $1.scene.id : $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    /// The direction named, flattened to what the page draws.
    static func direction(
        personal: PersonalInputs, knowledge: KnowledgeSnapshot, taste: TasteProfile, turn: Int?
    ) -> ExploreOffers.SceneOffer? {
        let found = directions(personal: personal, knowledge: knowledge, taste: taste)
        guard let scene = turn.map({ SceneEngine.pickDirection(found, turn: $0) }) ?? found.first
        else { return nil }
        return ExploreOffers.SceneOffer(
            city: scene.city, title: scene.city.uppercased(), sound: scene.soundLabel, size: scene.sizeLine
        )
    }
}
