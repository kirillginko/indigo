//
//  DigRecommender.swift
//  Indigo
//
//  What to hear next from an artist page: a few musicians, each with the
//  record that connects them, why, and something to put on.
//
//  DIG's lanes answer "who is connected to whom"; a card answers "what should
//  I hear next". It is built from the page's own routes -- nothing is added
//  that the routes do not say -- and carries:
//
//  - **the musician**, by verified identity (a Discogs id), so the card opens
//    the entry the evidence names;
//  - **the evidence**: the release the connection rests on, by title and year;
//  - **the reason**, the route's own sentence ("Bass on Essence");
//  - **the relationship**, said for what it is: made a record together, played
//    on it, wrote or produced, remixed, on the same record, the same label,
//    played near them on the radio, or -- never confused with the others --
//    sounds related;
//  - **a first listen**: a recording linked to that very release (where you
//    hear them together), or else one of their radio appearances.
//
//  Ranked for evidence, fit with the listener's taste, novelty (nothing they
//  have already been to this session), whether there is somewhere to go from
//  them, and whether there is something to hear; spread so three cards are
//  not three people from one sleeve. Technical credits are never cards.
//  Behind `DigRecommendations` (development builds only).
//

import Foundation

nonisolated enum DigRecommendations {
    #if DEBUG
    static let switchKey = "INDIGO_DIG_RECOMMENDATIONS"
    #endif

    nonisolated(unsafe) static var override: Bool?

    /// Brings the musician-first graph with it: cards are never technical.
    static var isEnabled: Bool {
        if let override { return override }
        #if DEBUG
        return UserDefaults.standard.bool(forKey: switchKey)
        #else
        return false
        #endif
    }
}

nonisolated struct DigRecommendation: Identifiable, Equatable, Sendable {
    nonisolated enum Relationship: String, Sendable, CaseIterable {
        case madeTogether, sameGroup, playedOn, wroteOrProduced, remixed, onTheSameRecord
        case sameLabel, playedNearby, soundsRelated

        /// A fact two records state about two people, as opposed to a
        /// neighbourhood or a resemblance.
        var isDirect: Bool {
            switch self {
            case .madeTogether, .sameGroup, .playedOn, .wroteOrProduced, .remixed, .onTheSameRecord: true
            case .sameLabel, .playedNearby, .soundsRelated: false
            }
        }

        var label: String {
            switch self {
            case .madeTogether: "Made a record together"
            case .sameGroup: "Same group"
            case .playedOn: "Played on it"
            case .wroteOrProduced: "Wrote or produced"
            case .remixed: "Remixed"
            case .onTheSameRecord: "On the same record"
            case .sameLabel: "Same label"
            case .playedNearby: "Played nearby on radio"
            case .soundsRelated: "Sounds related"
            }
        }

        /// What it is worth going down, before the evidence is weighed.
        var weight: Double {
            switch self {
            case .madeTogether: 1
            case .playedOn: 0.95
            case .wroteOrProduced: 0.9
            case .sameGroup: 0.85
            case .remixed: 0.8
            case .onTheSameRecord: 0.6
            case .sameLabel: 0.45
            case .playedNearby: 0.4
            case .soundsRelated: 0.3
            }
        }
    }

    /// The record the connection rests on.
    nonisolated struct Evidence: Equatable, Sendable {
        let title: String
        let year: Int?
        let releaseID: Int?
    }

    /// Something to put on.
    nonisolated enum Listen: Equatable, Sendable {
        /// A recording catalogued with the very release that connects them.
        case recording(URL, title: String)
        /// One of their radio appearances, playable in Indigo.
        case radio(URL, title: String, show: String?)

        var isFromTheEvidence: Bool { if case .recording = self { true } else { false } }
    }

    let artist: MusicNode
    let relationship: Relationship
    let evidence: Evidence?
    /// The route's own words, as the source stated them.
    let reason: String
    var listen: Listen?
    /// Musician routes on from them, when known.
    var onward: Int?
    var score: Double

    var id: String { artist.id }
}

nonisolated enum DigRecommender {
    /// What the recommender may ask about places beyond the page's routes.
    /// Every lookup may answer nil, which counts as unknown, never as a no.
    struct Lookups {
        /// A release on this artist's records, by its title.
        var release: (String) -> (id: Int, year: Int?)? = { _ in nil }
        /// Recordings catalogued with a release.
        var recordings: (Int) -> [(url: URL, title: String)] = { _ in [] }
        /// A radio appearance of an artist, playable in Indigo.
        var radio: (MusicNode) -> DigRecommendation.Listen? = { _ in nil }
        /// Musician routes on from an artist.
        var onward: (MusicNode) -> Int? = { _ in nil }
        /// An artist's styles and genres, folded.
        var tags: (MusicNode) -> [String]? = { _ in nil }
    }

    /// Where the listener is: their long-term taste, the pages they have been
    /// to in this dig, and what they already know.
    struct Listener {
        var taste: TasteProfile = .empty
        /// Already opened in this dig: never offered again, so a journey does
        /// not loop.
        var visited: Set<String> = []
        /// Already kept or played: offered, at half the weight.
        var known: Set<String> = []
    }

    // MARK: Reading a route

    /// The release named in a route's reason, in the formats DIG writes:
    /// "Made X together", "Role on X", "Role on X (A1, B2)", "Appears on X".
    static func releaseTitle(in reason: String) -> String? {
        if reason.hasPrefix("Made "), reason.hasSuffix(" together") {
            let title = reason.dropFirst("Made ".count).dropLast(" together".count)
            return title.isEmpty ? nil : String(title)
        }
        if reason.hasPrefix("Appears on ") { return String(reason.dropFirst("Appears on ".count)).nilIfEmptyTitle }
        // The first " on ": a role never contains it, a title may ("Live on Mars").
        guard let range = reason.range(of: " on ") else { return nil }
        var title = String(reason[range.upperBound...])
        // A trailing "(A1, B2)" is the tracks, not the title.
        if title.hasSuffix(")"), let open = title.range(of: " (", options: .backwards) {
            let inside = title[open.upperBound..<title.index(before: title.endIndex)]
            if inside.split(separator: ",").allSatisfy({ $0.trimmingCharacters(in: .whitespaces).count <= 6 }) {
                title = String(title[..<open.lowerBound])
            }
        }
        return title.isEmpty ? nil : title
    }

    /// The role a route states, when it states one: "Bass" in "Bass on X".
    static func role(in reason: String) -> String? {
        guard !reason.hasPrefix("Made "), !reason.hasPrefix("Appears on"), !reason.hasPrefix("Credited"),
              let range = reason.range(of: " on ") else { return nil }
        let role = String(reason[..<range.lowerBound])
        return role.isEmpty ? nil : role
    }

    static func relationship(of edge: MusicEdge) -> DigRecommendation.Relationship? {
        let role = role(in: edge.reason)
        switch edge.kind {
        case .collaborator:
            guard let role else { return .madeTogether }
            return relationship(role: role) ?? .madeTogether
        case .producer, .personnel:
            return role.flatMap(relationship(role:)) ?? (edge.kind == .producer ? .wroteOrProduced : .playedOn)
        case .aliasOrProject: return .sameGroup
        case .sameRelease, .appearsOnRelease: return .onTheSameRecord
        case .sharedLabel: return .sameLabel
        case .playedInShow, .sharedBroadcast, .playedBySameSelector, .frequentlyPlayedNearby: return .playedNearby
        case .sharedStyle, .sameEra: return .soundsRelated
        default: return nil
        }
    }

    /// A stated role, or nil when it is not a card at all (technical).
    static func relationship(role: String) -> DigRecommendation.Relationship? {
        switch CreditRole.contribution(of: role) {
        case .technical?: return nil
        case .performing?: return .playedOn
        case .creative?: return role.lowercased().contains("remix") ? .remixed : .wroteOrProduced
        case nil: return .madeTogether
        }
    }

    // MARK: Recommending

    /// A few cards from a page's routes, strongest first.
    static func recommend(
        from edges: [MusicEdge], origin: MusicNode, lookups: Lookups, listener: Listener, limit: Int = 3
    ) -> [DigRecommendation] {
        var best: [String: DigRecommendation] = [:]
        var corroboration: [String: Set<DigRecommendation.Relationship>] = [:]
        for edge in edges.sorted(by: MusicEdge.precedes) {
            let artist = edge.to
            guard artist.kind == .artist, artist.id != origin.id, artist.key != origin.key,
                  !listener.visited.contains(artist.id) else { continue }
            // A stated technical role is never a card, whatever the edge kind.
            if let role = role(in: edge.reason), CreditRole.contribution(of: role) == .technical { continue }
            guard let relationship = relationship(of: edge) else { continue }
            corroboration[artist.id, default: []].insert(relationship)

            // Only a direct fact names a record; "Releases on X" names a label.
            let evidence: DigRecommendation.Evidence? = (relationship.isDirect ? releaseTitle(in: edge.reason) : nil).map { title in
                let found = lookups.release(title)
                return .init(title: title, year: found?.year, releaseID: found?.id)
            }
            let listen = evidence?.releaseID.flatMap { lookups.recordings($0).first }
                .map { DigRecommendation.Listen.recording($0.url, title: $0.title) }
                ?? lookups.radio(artist)
            let onward = lookups.onward(artist)
            let tags = lookups.tags(artist)

            var score = relationship.weight * edge.weight
            score *= 1 + 0.15 * log2(Double(max(1, edge.occurrences)))
            if let tags, !tags.isEmpty, !listener.taste.isEmpty {
                score *= 0.85 + 0.3 * listener.taste.affinity(for: tags)
            }
            if listener.known.contains(artist.id) { score *= 0.5 }
            switch onward {
            case 0?: score *= 0.75
            case let count? where count >= 3: score *= 1.05
            default: break
            }
            if listen != nil { score *= 1.1 }

            let card = DigRecommendation(artist: artist, relationship: relationship, evidence: evidence,
                                         reason: edge.reason, listen: listen, onward: onward, score: score)
            if let held = best[artist.id], held.score >= score { continue }
            best[artist.id] = card
        }
        // Two different kinds of fact about the same person agree.
        for (id, kinds) in corroboration where kinds.filter(\.isDirect).count >= 1 && kinds.count >= 2 {
            best[id]?.score *= 1.1
        }
        return spread(best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.artist.presentationKey < $1.artist.presentationKey },
                      limit: limit)
    }

    /// Few and strong, and not one sleeve three times: at most two cards from
    /// one release; direct connections first, a neighbourhood or a
    /// resemblance only where there are not enough of them.
    static func spread(_ ranked: [DigRecommendation], limit: Int) -> [DigRecommendation] {
        var cards: [DigRecommendation] = []
        var perRelease: [String: Int] = [:]
        func take(_ pass: (DigRecommendation) -> Bool) {
            for card in ranked where cards.count < limit && pass(card) && !cards.contains(where: { $0.id == card.id }) {
                let key = card.evidence?.title.lowercased() ?? ""
                if !key.isEmpty, perRelease[key, default: 0] >= 2 { continue }
                perRelease[key, default: 0] += 1
                cards.append(card)
            }
        }
        take { $0.relationship.isDirect }
        take { $0.relationship != .soundsRelated }
        take { _ in true }
        return cards
    }
}

private extension String {
    var nilIfEmptyTitle: String? { isEmpty ? nil : self }
}
