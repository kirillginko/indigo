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
            case .sameGroup: 0.7
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
        /// Their record, which the page's artist worked on -- the other way
        /// round from a credit on the page artist's own record.
        var isTheirs = false
    }

    /// What the card's chip says: the relationship, or, when the page's
    /// artist worked on their record, that -- the reason says in what part.
    var chip: String { evidence?.isTheirs == true ? "On their record" : relationship.label }

    /// Something to put on.
    nonisolated enum Listen: Equatable, Sendable {
        /// A recording catalogued with the very release that connects them.
        case recording(URL, title: String)
        /// One of their radio appearances: the episode's page in Indigo when
        /// it has one, its archive link when that is what is known.
        case radio(title: String, show: String?, url: URL?, page: MusicNode?)

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
        /// A release's tracklist: position and title.
        var tracks: (Int) -> [(position: String, title: String)] = { _ in [] }
        /// A radio appearance of an artist, playable in Indigo.
        var radio: (MusicNode) -> DigRecommendation.Listen? = { _ in nil }
        /// Musician routes on from an artist.
        var onward: (MusicNode) -> Int? = { _ in nil }
        /// An artist's styles and genres, folded.
        var tags: (MusicNode) -> [String]? = { _ in nil }
        /// The artist as a verified entry, or nil when nothing verifies who a
        /// name is. A card is only ever a verified entry.
        var identity: (MusicNode) -> MusicNode? = { $0.discogsID != nil || $0.mbid != nil ? $0 : nil }
        /// Whether this is the page's own artist under another name: their
        /// real name, an alias, a spelling their entry lists.
        var samePerson: (MusicNode) -> Bool = { _ in false }
        /// The record on the page artist's own shelf that is somebody else's
        /// -- the record behind a bare "Credited together" -- and the page
        /// artist's role on it, by the other artist's folded name.
        var shelf: (MusicNode) -> ShelfEntry? = { _ in nil }
    }

    /// One entry of an artist's shelf that is somebody else's record.
    struct ShelfEntry: Equatable, Sendable {
        let title: String
        let year: Int?
        /// The shelf artist's role on it, as Discogs files it: "Appearance",
        /// "TrackAppearance", "Remix", "Producer".
        let role: String
        let releaseID: Int?
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
        /// The styles of the pages this dig has been through, the current one
        /// first: what the listener is exploring right now.
        var sessionTags: [String] = []
        /// Names already opened in this dig, for spotting the same person
        /// under a variant entry ("Alan Ginsberg" after Allen Ginsberg).
        var visitedNames: [String] = []
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
        // A trailing "(A1, B2)", "(1 to 4, 6 to 19)" or "(A1 to B5)" is the
        // tracks, not the title.
        if title.hasSuffix(")"), let open = title.range(of: " (", options: .backwards) {
            let inside = String(title[open.upperBound..<title.index(before: title.endIndex)])
            if inside.range(of: trackSpec, options: .regularExpression) != nil {
                title = String(title[..<open.lowerBound])
            }
        }
        return title.isEmpty ? nil : title
    }

    /// Track positions as Discogs writes them: "A1", "2.3", "B", "1 to 4",
    /// "A1-B2", any number of them separated by commas.
    /// Each position carries a digit, so "(II)" and "(EP)" stay in the title.
    private static let trackSpec = #"^(?:[A-Za-z]{0,2}\d+(?:\.\d+)?[a-z]?(?:\s*(?:to|-|–)\s*[A-Za-z]{0,2}\d+(?:\.\d+)?[a-z]?)?)(?:\s*,\s*[A-Za-z]{0,2}\d+(?:\.\d+)?[a-z]?(?:\s*(?:to|-|–)\s*[A-Za-z]{0,2}\d+(?:\.\d+)?[a-z]?)?)*$"#

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
    ///
    /// Two passes: every route is weighed on what it says (relationship,
    /// evidence, a named record), and only the strongest few are looked up
    /// further (something to hear, whether they lead on, their styles) -- a
    /// page has hundreds of routes and three cards.
    static func recommend(
        from edges: [MusicEdge], origin: MusicNode, lookups: Lookups, listener: Listener, limit: Int = 3,
        shortlist: Int = 25
    ) -> [DigRecommendation] {
        let best = firstPass(from: edges, origin: origin, lookups: lookups, listener: listener)

        return finish(best: best, origin: origin, lookups: lookups, listener: listener, limit: limit, shortlist: shortlist)
    }

    /// The recording to put on first: one of the tracks the credit names
    /// ("Piano on First Class! (1, 3, 5)"), when the tracklist and a
    /// recording's title say which; otherwise the record's first.
    static func firstListen(release: Int, reason: String, lookups: Lookups) -> (url: URL, title: String)? {
        let recordings = lookups.recordings(release)
        guard let first = recordings.first else { return nil }
        guard reason.hasSuffix(")"), let open = reason.range(of: " (", options: .backwards) else { return first }
        let positions = reason[open.upperBound..<reason.index(before: reason.endIndex)]
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let named = lookups.tracks(release)
            .filter { positions.contains($0.position.lowercased()) }
            .map { RecordingKey.normalize($0.title) }
            .filter { $0.count >= 3 }
        return recordings.first { recording in
            let title = RecordingKey.normalize(recording.title)
            return named.contains { title.contains($0) }
        } ?? first
    }

    /// More neighbours than this through one label, and the label is a hub.
    static let labelHub = 12

    /// Every route weighed on what it says, one card per artist.
    private static func firstPass(
        from edges: [MusicEdge], origin: MusicNode, lookups: Lookups, listener: Listener
    ) -> [String: DigRecommendation] {
        let avoid = ([origin.title] + listener.visitedNames).map(nameKey)
        // A label that reaches a great many of this page's neighbours is a
        // hub -- a session series, a distributor, a major -- and being on it
        // says nothing about two artists.
        var perLabel: [String: Int] = [:]
        for edge in edges where edge.kind == .sharedLabel { perLabel[edge.reason, default: 0] += 1 }
        var best: [String: DigRecommendation] = [:]
        var corroboration: [String: Set<DigRecommendation.Relationship>] = [:]
        for edge in edges.sorted(by: MusicEdge.precedes) {
            if edge.kind == .sharedLabel, perLabel[edge.reason, default: 0] > labelHub { continue }
            let artist = edge.to
            guard artist.kind == .artist, artist.id != origin.id, artist.key != origin.key,
                  !listener.visited.contains(artist.id) else { continue }
            // The same person under a variant entry or their own other name
            // is not somebody new.
            guard !avoid.contains(where: { sameName($0, nameKey(artist.title)) }), !lookups.samePerson(artist) else { continue }
            // A stated technical role is never a card, whatever the edge kind.
            if let role = role(in: edge.reason), CreditRole.contribution(of: role) == .technical { continue }
            guard var relationship = relationship(of: edge) else { continue }

            // Only a direct fact names a record; "Releases on X" names a label.
            var evidence: DigRecommendation.Evidence? = (relationship.isDirect ? releaseTitle(in: edge.reason) : nil).map { title in
                let found = lookups.release(title)
                return .init(title: title, year: found?.year, releaseID: found?.id)
            }
            var reason = edge.reason
            // A bare "Credited together": the page artist's own shelf says
            // which record of theirs it was, and in what part.
            if relationship.isDirect, evidence == nil, let entry = lookups.shelf(artist) {
                let role = shelfRole(entry.role)
                guard CreditRole.contribution(of: role) != .technical else { continue }
                evidence = .init(title: entry.title, year: entry.year, releaseID: entry.releaseID, isTheirs: true)
                relationship = relationship == .sameGroup ? .sameGroup : (DigRecommender.relationship(role: role) ?? .madeTogether)
                reason = "\(origin.title): \(role) on \(entry.title)"
            }
            corroboration[artist.id, default: []].insert(relationship)
            var score = relationship.weight * edge.weight
            score *= 1 + 0.15 * log2(Double(max(1, edge.occurrences)))
            // A direct connection that names no record ("Credited together")
            // is a weaker claim than one that says which record and what part.
            if relationship.isDirect && evidence == nil { score *= 0.6 }
            if listener.known.contains(artist.id) { score *= 0.5 }

            let card = DigRecommendation(artist: artist, relationship: relationship, evidence: evidence,
                                         reason: reason, listen: nil, onward: nil, score: score)
            if let held = best[artist.id], held.score >= score { continue }
            best[artist.id] = card
        }
        for (id, kinds) in corroboration where kinds.contains(where: \.isDirect) && kinds.count >= 2 {
            best[id]?.score *= 1.1
        }

        return best
    }

    /// The bare names among the strongest candidates that nothing verifies
    /// yet: what is worth asking the catalogue about while a page is open.
    static func unverified(
        from edges: [MusicEdge], origin: MusicNode, lookups: Lookups, listener: Listener, limit: Int = 4
    ) -> [MusicNode] {
        var probe = lookups
        probe.identity = { $0.discogsID != nil || $0.mbid != nil ? $0 : nil }
        var held = lookups
        held.radio = { _ in nil }; held.onward = { _ in nil }; held.tags = { _ in nil }; held.recordings = { _ in [] }
        // The ranking without the lookups that cost anything.
        let candidates = firstPass(from: edges, origin: origin, lookups: held, listener: listener)
            .values.sorted(by: ahead).filter { $0.relationship.isDirect }
        return candidates.filter { probe.identity($0.artist) == nil && lookups.identity($0.artist) == nil }
            .prefix(limit).map(\.artist)
    }

    private static func finish(
        best: [String: DigRecommendation], origin: MusicNode, lookups: Lookups, listener: Listener, limit: Int, shortlist: Int
    ) -> [DigRecommendation] {
        // The shortlist, looked up.
        let session = TasteProfile(weights: Dictionary(listener.sessionTags.enumerated().map {
            ($0.element, max(0.5, 1 - Double($0.offset) * 0.05))
        }, uniquingKeysWith: max), evidence: Double(listener.sessionTags.count), builtAt: .distantPast)
        let shortlisted = best.values.sorted(by: ahead).prefix(shortlist).compactMap { found -> DigRecommendation? in
            // A card opens the entry the evidence names: a bare name is only
            // a card once something verifies whose it is.
            guard let verified = lookups.identity(found.artist), !lookups.samePerson(verified),
                  verified.id != origin.id, !listener.visited.contains(verified.id) else { return nil }
            var card = DigRecommendation(artist: verified, relationship: found.relationship, evidence: found.evidence,
                                         reason: found.reason, listen: nil, onward: nil, score: found.score)
            card.listen = card.evidence?.releaseID.flatMap { firstListen(release: $0, reason: card.reason, lookups: lookups) }
                .map { DigRecommendation.Listen.recording($0.url, title: $0.title) }
                ?? lookups.radio(card.artist)
            card.onward = lookups.onward(card.artist)
            if let tags = lookups.tags(card.artist), !tags.isEmpty {
                // What they have liked over time, and what this dig is about.
                if !listener.taste.isEmpty { card.score *= 0.85 + 0.3 * listener.taste.affinity(for: tags) }
                if !session.isEmpty { card.score *= 0.85 + 0.3 * session.affinity(for: tags) }
            }
            switch card.onward {
            case 0?: card.score *= 0.75
            case let count? where count >= 3: card.score *= 1.05
            default: break
            }
            if card.listen != nil { card.score *= 1.1 }
            return card
        }
        return spread(shortlisted.sorted(by: ahead), limit: limit)
    }

    /// Score, then the more recent record (a tie used to be the alphabet,
    /// which put every page's "A" collaborators first), then the name.
    private static func ahead(_ a: DigRecommendation, _ b: DigRecommendation) -> Bool {
        if a.score != b.score { return a.score > b.score }
        let ay = a.evidence?.year ?? 0, by = b.evidence?.year ?? 0
        if ay != by { return ay > by }
        return a.artist.presentationKey < b.artist.presentationKey
    }

    /// Discogs' shelf roles in words a card can say.
    static func shelfRole(_ role: String) -> String {
        switch role {
        case "Appearance": "Appears"
        case "TrackAppearance": "Track appearance"
        case "UnofficialRelease": "Unofficial release"
        default: role
        }
    }

    /// A name folded for comparison: lowercased, letters and digits only.
    static func nameKey(_ name: String) -> String {
        RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(name)).filter { $0.isLetter || $0.isNumber }
    }

    /// The same name give or take a letter or two -- "Alan Ginsberg" and
    /// "Allen Ginsberg" -- on names long enough for that to mean something.
    static func sameName(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard min(a.count, b.count) >= 8, abs(a.count - b.count) <= 2 else { return false }
        let x = Array(a), y = Array(b)
        var row = Array(0...y.count)
        for i in 1...x.count {
            var previous = row[0]
            row[0] = i
            for j in 1...y.count {
                let held = row[j]
                row[j] = x[i - 1] == y[j - 1] ? previous : 1 + min(previous, row[j], row[j - 1])
                previous = held
            }
        }
        return row[y.count] <= 2
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
                // One group at most: a list of collectives is a list of aliases.
                if card.relationship == .sameGroup, cards.contains(where: { $0.relationship == .sameGroup }) { continue }
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
