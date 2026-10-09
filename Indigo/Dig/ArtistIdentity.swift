//
//  ArtistIdentity.swift
//  Indigo
//
//  Which artist a reference means, decided from evidence rather than from
//  how the name happens to be spelled.
//
//  "Prefuse73" and "Prefuse 73" are one artist, and Indigo opened them as two
//  pages: one with Discogs' whole record of him and one with nothing, because
//  every part of DIG keys on the folded name and the two fold differently.
//  Folding harder is not the answer. "Arp" and "A.R.P." fold together and are
//  two people; so do "Twin S" and "TWÏNS". What separates the cases is what
//  Discogs itself has said: Prefuse 73's entry lists "Prefuse73" among the
//  spellings his records were credited under, and nobody else is filed under
//  it.
//
//  So identity here is decided by evidence, in a fixed order of strength — an
//  id the reference already carries, a link MusicBrainz made, a filing name
//  only one artist holds, a credited spelling only one artist answers to —
//  and a reference with none of those stays exactly what it was: its own
//  name, unverified, with anything that merely looks similar kept aside as a
//  possible match and never acted on.
//
//  Being another name for someone is a different claim from being the same
//  name. Mica Levi and Micachu are aliases — Discogs keeps two discographies
//  on purpose — so they resolve to two identities with a relation between
//  them. `PreferredProfileResolver` decides how a sparse one borrows from a
//  rich one without folding their records together.
//
//  Everything in this file is pure: it reads evidence it is handed and
//  fetches nothing.
//

import Foundation

// MARK: - Identity

/// Indigo's name for an artist, stable however richly they are described.
///
/// Anchored on the strongest identifier verified for them: a Discogs entry, a
/// MusicBrainz entry, or — for someone who so far exists only on a radio
/// tracklist, on SoundCloud or on Bandcamp — their folded name. A name
/// identity is provisional: when evidence arrives it resolves onward to the
/// verified one, and the name key it had keeps working as a way in.
nonisolated struct ArtistIdentity: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    static func discogs(_ id: Int) -> ArtistIdentity { ArtistIdentity(rawValue: "discogs:\(id)") }
    static func musicBrainz(_ mbid: String) -> ArtistIdentity {
        ArtistIdentity(rawValue: "mbid:\(mbid.lowercased())")
    }
    static func name(_ name: String) -> ArtistIdentity {
        ArtistIdentity(rawValue: "name:\(RecordingKey.normalizeArtist(name))")
    }

    var discogsID: Int? {
        guard rawValue.hasPrefix("discogs:") else { return nil }
        return Int(rawValue.dropFirst("discogs:".count))
    }

    /// Whether anything stronger than a spelling stands behind it.
    var isVerified: Bool { !rawValue.hasPrefix("name:") }

    var description: String { rawValue }
}

/// What a caller knows about an artist it wants to open: always a name, and
/// whichever identifiers it already had. Navigation carries these through
/// rather than dropping them and searching the name again.
nonisolated struct ArtistReference: Hashable, Sendable {
    let name: String
    var mbid: String?
    var discogsID: Int?

    init(name: String, mbid: String? = nil, discogsID: Int? = nil) {
        self.name = name
        self.mbid = mbid?.nilIfBlank
        self.discogsID = discogsID.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// How two spellings are compared.
///
/// Case, diacritics and punctuation are ignored; spacing is not. "Prefuse73"
/// and "Prefuse 73" are different strings to this on purpose — that they are
/// one artist is a fact Discogs has to supply, not one spacing can.
nonisolated enum ArtistSpelling {
    /// For a name as somebody wrote it.
    static func key(_ name: String) -> String { RecordingKey.normalize(name) }

    /// For a name as Discogs files it: "Anika (9)" is filed under "Anika".
    static func filingKey(_ name: String) -> String {
        RecordingKey.normalize(DiscogsClient.withoutDisambiguator(name))
    }

    /// With the spaces gone too — used only to decide which entries are worth
    /// reading, never to decide who anybody is.
    static func compact(_ name: String) -> String {
        key(DiscogsClient.withoutDisambiguator(name)).replacingOccurrences(of: " ", with: "")
    }
}

// MARK: - Evidence

/// What a Discogs artist entry says about who it is, read from `artists/{id}`.
nonisolated struct DiscogsIdentityFacts: Hashable, Sendable {
    nonisolated struct Link: Hashable, Sendable {
        let id: Int
        let name: String
    }

    let id: Int
    /// As Discogs files it, disambiguator and all.
    let name: String
    let realName: String?
    /// The spellings records have credited this entry under.
    let nameVariations: [String]
    /// Other entries Discogs says are the same person under another name.
    let aliases: [Link]
    let groups: [Link]
    let members: [Link]

    /// The name without Discogs' filing marks.
    var canonicalName: String { DiscogsClient.withoutDisambiguator(name) }

    /// How this entry answers to a spelling, if it does.
    func answers(to spellingKey: String) -> IdentityBasis? {
        guard !spellingKey.isEmpty else { return nil }
        if ArtistSpelling.filingKey(name) == spellingKey { return .canonicalName }
        if nameVariations.contains(where: { ArtistSpelling.key($0) == spellingKey }) { return .nameVariation }
        return nil
    }
}

extension DiscogsIdentityFacts {
    init(detail: DiscogsArtistDetail) {
        func links(_ references: [DiscogsArtistReference]?) -> [Link] {
            (references ?? []).compactMap { reference in
                guard let id = reference.id, id > 0, let name = reference.name?.nilIfBlank else { return nil }
                return Link(id: id, name: name)
            }
        }
        self.init(
            id: detail.id,
            name: detail.name,
            realName: detail.realname?.nilIfBlank,
            nameVariations: (detail.namevariations ?? []).compactMap(\.nilIfBlank),
            aliases: links(detail.aliases),
            groups: links(detail.groups),
            members: links(detail.members)
        )
    }
}

/// Why an identity was accepted. Ordered strongest first.
nonisolated enum IdentityBasis: String, Hashable, Sendable {
    /// The reference arrived carrying a Discogs id.
    case discogsID
    /// The reference arrived carrying a MusicBrainz id.
    case musicBrainzID
    /// MusicBrainz' entry for the reference's MBID links this Discogs entry.
    case musicBrainzLink
    /// A complete search found exactly one artist filed under this name.
    case canonicalName
    /// A complete search found exactly one artist credited under this spelling,
    /// and nobody filed under it.
    case nameVariation
}

/// What a complete Discogs artist search for one spelling established.
///
/// Only ever made from a search that answered in full and whose candidates
/// were all read. A refused, truncated or partly-read search is no verdict at
/// all — `SpellingCheck.verdict` answers nil — and nil is never stored, so it
/// is asked again rather than remembered as an answer.
nonisolated enum SpellingVerdict: Hashable, Sendable {
    /// Filed under exactly this name by these entries. One is an identity;
    /// several are namesakes, which only their ids can tell apart.
    case canonical([Int])
    /// Nobody is filed under it, and exactly one entry lists it as a spelling
    /// its records were credited under.
    case variation(Int)
    /// Nobody is filed under it, and more than one entry lists it.
    case ambiguous([Int])
    /// Nobody answers to it at all.
    case nobody
}

/// Deciding whether a spelling belongs to exactly one Discogs entry.
nonisolated enum SpellingCheck {
    /// How many entries a check will read. More candidates than this and the
    /// check gives up rather than guess which of them to skip.
    static let candidateLimit = 3

    /// How many results a check asks for. The search must fit in one page for
    /// its absence of other claimants to mean anything.
    static let pageSize = 50

    /// The entries whose own record must be read before a verdict: those that
    /// might list the spelling as a variation — the ones it matches once spaces
    /// are gone — and that are not already filed under it. Nil when there are
    /// too many to read, which is an incomplete check.
    static func candidates(for spelling: String, in results: [DiscogsSearchResult]) -> [Int]? {
        let key = ArtistSpelling.key(spelling)
        let compact = ArtistSpelling.compact(spelling)
        guard !key.isEmpty, !compact.isEmpty else { return [] }
        var ids: [Int] = []
        for result in results {
            guard let id = result.id, id > 0, !ids.contains(id) else { continue }
            guard ArtistSpelling.filingKey(result.title) != key else { continue }
            if ArtistSpelling.compact(result.title) == compact { ids.append(id) }
        }
        return ids.count > candidateLimit ? nil : ids
    }

    /// The verdict, or nil when the evidence is incomplete.
    ///
    /// - Parameters:
    ///   - complete: whether the search answered and returned every match it
    ///     has. A failed or paginated search is never complete.
    ///   - details: each candidate's own entry, keyed by id. A candidate that
    ///     could not be read makes the whole check incomplete — a refusal is
    ///     not evidence that it does not answer to the spelling.
    static func verdict(
        spelling: String,
        results: [DiscogsSearchResult],
        complete: Bool,
        details: [Int: DiscogsIdentityFacts]
    ) -> SpellingVerdict? {
        guard complete else { return nil }
        let key = ArtistSpelling.key(spelling)
        guard !key.isEmpty else { return nil }

        let filed = results.compactMap { result -> Int? in
            guard let id = result.id, id > 0 else { return nil }
            return ArtistSpelling.filingKey(result.title) == key ? id : nil
        }
        if !filed.isEmpty { return .canonical(Array(Set(filed)).sorted()) }

        guard let candidates = candidates(for: spelling, in: results) else { return nil }
        var holders: [Int] = []
        for id in candidates {
            guard let facts = details[id] else { return nil }
            if facts.answers(to: key) == .nameVariation { holders.append(id) }
        }
        switch holders.count {
        case 0: return .nobody
        case 1: return .variation(holders[0])
        default: return .ambiguous(holders.sorted())
        }
    }
}

/// Everything the resolvers know, gathered by whoever calls them.
nonisolated struct ArtistIdentityEvidence: Sendable {
    /// Discogs entries read in full, by id.
    var facts: [Int: DiscogsIdentityFacts] = [:]
    /// Complete spelling checks, by `ArtistSpelling.key`.
    var spellings: [String: SpellingVerdict] = [:]
    /// The Discogs entries MusicBrainz links to an MBID (lowercased), as the
    /// backend's `musicbrainz_discogs` rows record them.
    var musicBrainzLinks: [String: [Int]] = [:]

    init(
        facts: [DiscogsIdentityFacts] = [],
        spellings: [String: SpellingVerdict] = [:],
        musicBrainzLinks: [String: [Int]] = [:]
    ) {
        self.facts = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.spellings = spellings
        self.musicBrainzLinks = musicBrainzLinks
    }
}

// MARK: - Resolving a reference

nonisolated struct ArtistResolution: Hashable, Sendable {
    let reference: ArtistReference
    let identity: ArtistIdentity
    /// Nil when nothing verified the identity; it is then the reference's own
    /// name and nothing more.
    let basis: IdentityBasis?
    /// What the profile is called: Discogs' filing name without its marks,
    /// once an entry is known, otherwise the name the reference arrived with.
    let canonicalName: String
    /// Every spelling verified to be this identity, the canonical one first.
    /// What DIG reads recordings, releases and radio under.
    let equivalentNames: [String]
    /// Entries that look like this reference and that nothing verified, kept so
    /// they can be shown as possibilities. Never followed automatically.
    let possibleMatches: [Int]

    var isVerified: Bool { basis != nil }

    /// Whether the reference should open under a different name than it came
    /// with — a verified spelling of somebody filed otherwise.
    var isRedirect: Bool {
        isVerified && ArtistSpelling.key(reference.name) != ArtistSpelling.key(canonicalName)
    }
}

nonisolated struct ArtistIdentityResolver: Sendable {
    let evidence: ArtistIdentityEvidence

    func resolve(_ reference: ArtistReference) -> ArtistResolution {
        if let id = reference.discogsID {
            return verified(reference, discogsID: id, basis: .discogsID)
        }
        if let mbid = reference.mbid {
            if let linked = musicBrainzLink(for: mbid, named: reference.name) {
                return verified(reference, discogsID: linked, basis: .musicBrainzLink)
            }
            return ArtistResolution(
                reference: reference,
                identity: .musicBrainz(mbid),
                basis: .musicBrainzID,
                canonicalName: reference.name,
                equivalentNames: [reference.name],
                possibleMatches: evidence.musicBrainzLinks[mbid.lowercased()] ?? []
            )
        }

        let key = ArtistSpelling.key(reference.name)
        switch evidence.spellings[key] {
        case .canonical(let ids) where ids.count == 1:
            return verified(reference, discogsID: ids[0], basis: .canonicalName)
        case .variation(let id):
            return verified(reference, discogsID: id, basis: .nameVariation)
        case .canonical(let ids), .ambiguous(let ids):
            return unverified(reference, possible: ids)
        case .nobody, nil:
            return unverified(reference, possible: lookalikes(of: reference.name))
        }
    }

    /// The entries Discogs says are this one under another name, or that it
    /// belongs to or is made of — each its own identity.
    func relations(of discogsID: Int) -> [ArtistRelation] {
        guard let facts = evidence.facts[discogsID] else { return [] }
        let aliases = facts.aliases.map { ArtistRelation(identity: .discogs($0.id), name: $0.name, kind: .alias) }
        let groups = facts.groups.map { ArtistRelation(identity: .discogs($0.id), name: $0.name, kind: .group) }
        let members = facts.members.map { ArtistRelation(identity: .discogs($0.id), name: $0.name, kind: .member) }
        return aliases + groups + members
    }

    /// Which of the entries MusicBrainz links to an MBID the reference means.
    ///
    /// One link is an identity. Several is common and true — Anika's entry
    /// links both "Anika (9)" and "Annika Henderson", her name and her real
    /// name — but Discogs keeps those as aliases with discographies of their
    /// own, so several only settle on the one filed under the name the
    /// reference arrived with, and otherwise on none.
    private func musicBrainzLink(for mbid: String, named name: String) -> Int? {
        let linked = Array(Set(evidence.musicBrainzLinks[mbid.lowercased()] ?? [])).sorted()
        if linked.count == 1 { return linked[0] }
        let key = ArtistSpelling.key(name)
        let filed = linked.filter { evidence.facts[$0].map { ArtistSpelling.filingKey($0.name) == key } ?? false }
        return filed.count == 1 ? filed[0] : nil
    }

    private func verified(_ reference: ArtistReference, discogsID: Int, basis: IdentityBasis) -> ArtistResolution {
        let facts = evidence.facts[discogsID]
        let canonical = facts?.canonicalName ?? reference.name
        var names = [canonical]
        func add(_ name: String) {
            guard !names.contains(where: { ArtistSpelling.key($0) == ArtistSpelling.key(name) }) else { return }
            names.append(name)
        }
        add(reference.name)
        // Spellings a complete check settled on this entry, in a fixed order so
        // the list does not depend on which was checked first.
        for (spelling, verdict) in evidence.spellings.sorted(by: { $0.key < $1.key }) {
            if case .variation(let id) = verdict, id == discogsID {
                add(facts?.nameVariations.first { ArtistSpelling.key($0) == spelling } ?? spelling)
            }
        }
        return ArtistResolution(
            reference: reference,
            identity: .discogs(discogsID),
            basis: basis,
            canonicalName: canonical,
            equivalentNames: names,
            possibleMatches: []
        )
    }

    private func unverified(_ reference: ArtistReference, possible: [Int]) -> ArtistResolution {
        ArtistResolution(
            reference: reference,
            identity: .name(reference.name),
            basis: nil,
            canonicalName: reference.name,
            equivalentNames: [reference.name],
            possibleMatches: possible.sorted()
        )
    }

    /// Entries that match the name once spaces and punctuation are gone, and
    /// that nothing verified. Exactly what must not be acted on.
    private func lookalikes(of name: String) -> [Int] {
        let compact = ArtistSpelling.compact(name)
        guard !compact.isEmpty else { return [] }
        return evidence.facts.values
            .filter { ArtistSpelling.compact($0.name) == compact }
            .map(\.id)
            .sorted()
    }
}

nonisolated struct ArtistRelation: Hashable, Sendable {
    nonisolated enum Kind: String, Hashable, Sendable {
        /// The same person, recording as someone else.
        case alias
        /// A group the subject is in.
        case group
        /// Someone the subject, as a group, is made of.
        case member
    }

    let identity: ArtistIdentity
    let name: String
    let kind: Kind
}

// MARK: - Choosing the profile to show

/// How much an artist's record actually says.
nonisolated struct ProfileCompleteness: Hashable, Sendable {
    var releases: Int = 0
    var credits: Int = 0
    var hasBiography = false
    var hasArtwork = false
    var styles: Int = 0
    var labels: Int = 0
    var links: Int = 0

    /// Releases dominate, capped so a vast catalogue cannot drown everything
    /// else out; a biography and a picture are each worth a small shelf.
    var score: Int {
        min(releases, 200) * 3
            + min(credits, 100)
            + (hasBiography ? 40 : 0)
            + (hasArtwork ? 30 : 0)
            + min(styles, 10) * 2
            + min(labels, 20) * 2
            + min(links, 10)
    }

    /// Nothing a page could show: no records, no credits, no words, no picture.
    var isEmpty: Bool { releases == 0 && credits == 0 && !hasBiography && !hasArtwork }

    /// Enough to stand as a page, though thinly: a handful of records and no
    /// biography.
    var isSparse: Bool { !isEmpty && releases < 5 && !hasBiography }
}

/// Which profile a verified identity is shown with.
nonisolated struct ProfileChoice: Hashable, Sendable {
    nonisolated enum Mode: Hashable, Sendable {
        /// Its own record, which is enough.
        case own
        /// Its own name and its own records, with what a richer alias says
        /// about the person shown beside them and attributed to that alias.
        case ownWithFallback(ArtistIdentity)
        /// Its own record says nothing at all: open the richer alias, saying
        /// which name the listener came from.
        case openRelated(ArtistIdentity)
    }

    let subject: ArtistIdentity
    let mode: Mode

    /// The identity whose page DIG opens.
    var opens: ArtistIdentity {
        if case .openRelated(let related) = mode { return related }
        return subject
    }
}

/// Picks the profile to show for an identity among the ones Discogs says are
/// the same person under other names.
///
/// Never merges: an alias keeps its own name, its own records and its own
/// identity. What a sparse alias borrows is the richer one's description of
/// the person, attributed; what an empty one gets is a door to the richer
/// page. Both are recomputed from whatever is known now, so a richer record
/// arriving later changes the answer without anything being rewritten.
nonisolated struct PreferredProfileResolver: Sendable {
    let evidence: ArtistIdentityEvidence
    /// What is known of each entry's record, by Discogs id. An entry missing
    /// here is unknown, and an unknown alias is never preferred.
    let completeness: [Int: ProfileCompleteness]

    func choice(for identity: ArtistIdentity) -> ProfileChoice {
        guard let id = identity.discogsID, let own = completeness[id] else {
            return ProfileChoice(subject: identity, mode: .own)
        }
        guard own.isEmpty || own.isSparse, let richer = richestAlias(of: id, beating: own) else {
            return ProfileChoice(subject: identity, mode: .own)
        }
        return ProfileChoice(subject: identity, mode: own.isEmpty ? .openRelated(.discogs(richer)) : .ownWithFallback(.discogs(richer)))
    }

    /// The richest verified alias with more to say than the subject. Ties go
    /// to the lower Discogs id, so the answer never depends on order.
    ///
    /// Aliases only. A group the subject played in is somebody else's
    /// discography as well as theirs, so it is related, never preferred.
    private func richestAlias(of id: Int, beating own: ProfileCompleteness) -> Int? {
        guard let facts = evidence.facts[id] else { return nil }
        let known = facts.aliases.compactMap { link -> (id: Int, score: Int)? in
            guard link.id != id, let found = completeness[link.id], !found.isEmpty else { return nil }
            return (link.id, found.score)
        }
        let best = known.filter { $0.score > own.score }
            .min { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        return best?.id
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
