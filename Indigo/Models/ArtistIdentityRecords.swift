//
//  ArtistIdentityRecords.swift
//  Indigo
//
//  The evidence `ArtistIdentityResolver` decides from, kept on this device.
//
//  Two tables, both caches in the local store and neither synced: what a
//  Discogs entry says about who it is, and what a complete search established
//  about one spelling. Each row says where it came from and when, so a
//  verdict can always be traced to the request that made it.
//
//  Kept apart from `DiscogsArtist` deliberately. That table is keyed on the
//  name somebody asked for, and older rows were filed by looser matching than
//  today's — "walton" holds Rik Walton. Nothing in it is evidence of identity;
//  everything in these is.
//

import Foundation
import SwiftData

/// What `artists/{id}` says about who an entry is.
@Model
nonisolated final class DiscogsIdentityRecord {
    @Attribute(.unique) var discogsID: Int
    /// As Discogs files it, disambiguator and all: "Anika (9)".
    var name: String
    var realName: String?
    /// The spellings this entry's records were credited under.
    var nameVariations: [String]
    /// Positionally paired, as Discogs lists them.
    var aliasIDs: [Int]
    var aliasNames: [String]
    var groupIDs: [Int]
    var groupNames: [String]
    var memberIDs: [Int]
    var memberNames: [String]
    /// The request this row was read from: "discogs:artists/3722".
    var source: String
    var fetchedAt: Date

    /// How much this entry's own record says, read for an empty alias that
    /// needed a richer one (see `DigStore.discoverRicherAlias`). "unknown"
    /// until asked; "read" once both its entry and the size of its shelf
    /// answered; "failed" when the shelf would not. Only "read" is evidence —
    /// a failed read is never taken for an empty record.
    var summaryStateRaw: String = "unknown"
    var summaryReleaseCount: Int = 0
    var summaryHasBiography: Bool = false
    var summaryImageCount: Int = 0
    var summaryLinkCount: Int = 0
    var summaryCheckedAt: Date? = nil

    init(facts: DiscogsIdentityFacts, fetchedAt: Date = Date()) {
        discogsID = facts.id
        name = facts.name
        realName = facts.realName
        nameVariations = facts.nameVariations
        aliasIDs = facts.aliases.map(\.id)
        aliasNames = facts.aliases.map(\.name)
        groupIDs = facts.groups.map(\.id)
        groupNames = facts.groups.map(\.name)
        memberIDs = facts.members.map(\.id)
        memberNames = facts.members.map(\.name)
        source = "discogs:artists/\(facts.id)"
        self.fetchedAt = fetchedAt
    }

    func update(from facts: DiscogsIdentityFacts, at date: Date = Date()) {
        name = facts.name
        realName = facts.realName
        nameVariations = facts.nameVariations
        aliasIDs = facts.aliases.map(\.id)
        aliasNames = facts.aliases.map(\.name)
        groupIDs = facts.groups.map(\.id)
        groupNames = facts.groups.map(\.name)
        memberIDs = facts.members.map(\.id)
        memberNames = facts.members.map(\.name)
        fetchedAt = date
    }

    /// What the summary establishes, or nil when it establishes nothing.
    var summary: ProfileCompleteness? {
        guard summaryStateRaw == "read" else { return nil }
        return ProfileCompleteness(
            releases: summaryReleaseCount,
            hasBiography: summaryHasBiography,
            hasArtwork: summaryImageCount > 0,
            links: summaryLinkCount
        )
    }

    /// Whether the summary is worth asking for again: never read, failed more
    /// than a day ago, or read more than a month ago.
    var summaryIsDue: Bool {
        guard let checked = summaryCheckedAt else { return true }
        let age = Date().timeIntervalSince(checked)
        switch summaryStateRaw {
        case "read": return age > 30 * 24 * 60 * 60
        case "failed": return age > 24 * 60 * 60
        default: return true
        }
    }

    var facts: DiscogsIdentityFacts {
        func links(_ ids: [Int], _ names: [String]) -> [DiscogsIdentityFacts.Link] {
            zip(ids, names).map { DiscogsIdentityFacts.Link(id: $0, name: $1) }
        }
        return DiscogsIdentityFacts(
            id: discogsID, name: name, realName: realName, nameVariations: nameVariations,
            aliases: links(aliasIDs, aliasNames),
            groups: links(groupIDs, groupNames),
            members: links(memberIDs, memberNames)
        )
    }
}

/// What a complete Discogs artist search established about one spelling.
///
/// Only verdicts are written. A check that failed, paginated, or could not
/// read one of its candidates has no row, so it is asked again next time
/// rather than remembered as a no.
@Model
nonisolated final class ArtistSpellingRecord {
    /// `ArtistSpelling.key` of the spelling.
    @Attribute(.unique) var spellingKey: String
    /// The spelling as it was asked.
    var spelling: String
    /// "canonical", "variation", "ambiguous" or "nobody".
    var verdictRaw: String
    var discogsIDs: [Int]
    /// How many matches the search reported, all of which it returned.
    var resultCount: Int
    /// The request: "discogs:database/search?type=artist&q=Prefuse73".
    var source: String
    var checkedAt: Date

    init(spelling: String, verdict: SpellingVerdict, resultCount: Int, checkedAt: Date = Date()) {
        spellingKey = ArtistSpelling.key(spelling)
        self.spelling = spelling
        verdictRaw = ""
        discogsIDs = []
        self.resultCount = resultCount
        source = "discogs:database/search?type=artist&q=\(spelling)"
        self.checkedAt = checkedAt
        self.verdict = verdict
    }

    var verdict: SpellingVerdict? {
        get {
            switch verdictRaw {
            case "canonical": return .canonical(discogsIDs)
            case "variation": return discogsIDs.first.map(SpellingVerdict.variation)
            case "ambiguous": return .ambiguous(discogsIDs)
            case "nobody": return .nobody
            default: return nil
            }
        }
        set {
            switch newValue {
            case .canonical(let ids)?: verdictRaw = "canonical"; discogsIDs = ids
            case .variation(let id)?: verdictRaw = "variation"; discogsIDs = [id]
            case .ambiguous(let ids)?: verdictRaw = "ambiguous"; discogsIDs = ids
            case .nobody?: verdictRaw = "nobody"; discogsIDs = []
            case nil: verdictRaw = ""; discogsIDs = []
            }
        }
    }

    /// A catalogue gains artists and spellings. A verdict is worth asking again
    /// after a month — never sooner, so a page does not pay for it twice.
    var isStale: Bool { Date().timeIntervalSince(checkedAt) > 30 * 24 * 60 * 60 }
}

// MARK: - Credits

/// One appearance of an artist on a release, exactly as its document states it.
///
/// Kept per appearance: the same person producing two tracks and mixing a
/// third is three credits, not one person, and none of them is merged with
/// another on the strength of a shared id.
nonisolated struct ReleaseCredit: Hashable, Sendable {
    nonisolated enum Category: String, Hashable, Sendable {
        /// Who the release is by.
        case artist
        /// Who else worked on the release as a whole.
        case credit
        /// Who is on one track, or worked on it.
        case track
    }

    let category: Category
    /// Position among the document's entries of this category, from zero.
    let order: Int
    /// The spelling the record used: its `anv` when it has one, else the name.
    let creditedName: String
    /// The name Discogs files them under, disambiguator and all: "Hype Williams (2)".
    let filingName: String
    /// Nil when the document named nobody Discogs has an entry for.
    let discogsID: Int?
    /// The job as written — "Producer, Mixed By" — empty for headline artists.
    let role: String
    /// Which tracks: the credit's own `tracks`, or the track's position.
    let tracks: String

    /// The name to open them under: their filing name without its marks.
    var name: String { DiscogsClient.withoutDisambiguator(filingName) }

    /// Every artist a release document names, in document order. Nil when the
    /// document has no artists block at all — an incomplete answer, which must
    /// not replace what an earlier, complete one said.
    static func credits(in detail: DiscogsReleaseDetail) -> [ReleaseCredit]? {
        guard let headline = detail.artists else { return nil }
        func make(_ category: Category, _ order: Int, id: Int?, name: String?, anv: String?, role: String?, tracks: String?) -> ReleaseCredit? {
            guard let filing = name?.trimmingCharacters(in: .whitespacesAndNewlines), !filing.isEmpty else { return nil }
            let variation = anv?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ReleaseCredit(
                category: category, order: order,
                creditedName: (variation?.isEmpty == false ? variation! : filing),
                filingName: filing,
                discogsID: id.flatMap { $0 > 0 ? $0 : nil },
                role: role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                tracks: tracks?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
        var credits: [ReleaseCredit] = []
        for (order, artist) in headline.enumerated() {
            if let credit = make(.artist, order, id: artist.id, name: artist.name, anv: artist.anv, role: nil, tracks: nil) {
                credits.append(credit)
            }
        }
        for (order, extra) in (detail.extraartists ?? []).enumerated() {
            if let credit = make(.credit, order, id: extra.id, name: extra.name, anv: extra.anv, role: extra.role, tracks: extra.tracks) {
                credits.append(credit)
            }
        }
        var order = 0
        for line in detail.tracklist ?? [] {
            let position = line.position ?? ""
            for artist in line.artists ?? [] {
                if let credit = make(.track, order, id: artist.id, name: artist.name, anv: artist.anv, role: nil, tracks: position) {
                    credits.append(credit)
                    order += 1
                }
            }
            for extra in line.extraartists ?? [] {
                if let credit = make(.track, order, id: extra.id, name: extra.name, anv: extra.anv, role: extra.role, tracks: position) {
                    credits.append(credit)
                    order += 1
                }
            }
        }
        return credits
    }
}

/// Who a release credits, with their Discogs ids, for one release.
///
/// One row per release, its credits in parallel arrays, so a refreshed
/// document replaces them in a single write. Kept beside `DiscogsReleaseRecord`
/// rather than in it: that model is in every schema version, and its name
/// lists are what everything else still reads.
@Model
nonisolated final class ReleaseCreditRecord {
    @Attribute(.unique) var releaseDiscogsID: Int
    var categories: [String]
    var orders: [Int]
    var creditedNames: [String]
    var filingNames: [String]
    /// Zero where the document named nobody with an entry.
    var artistDiscogsIDs: [Int]
    var roles: [String]
    var tracks: [String]
    /// The document these came from: "discogs:releases/123" or
    /// "r2:releases/123.json".
    var source: String
    var fetchedAt: Date

    init(releaseDiscogsID: Int, credits: [ReleaseCredit], source: String, fetchedAt: Date = Date()) {
        self.releaseDiscogsID = releaseDiscogsID
        categories = []; orders = []; creditedNames = []; filingNames = []
        artistDiscogsIDs = []; roles = []; tracks = []
        self.source = source
        self.fetchedAt = fetchedAt
        replace(with: credits, source: source, at: fetchedAt)
    }

    /// Every credit at once, so the row is never half old and half new.
    func replace(with credits: [ReleaseCredit], source: String, at date: Date = Date()) {
        categories = credits.map(\.category.rawValue)
        orders = credits.map(\.order)
        creditedNames = credits.map(\.creditedName)
        filingNames = credits.map(\.filingName)
        artistDiscogsIDs = credits.map { $0.discogsID ?? 0 }
        roles = credits.map(\.role)
        tracks = credits.map(\.tracks)
        self.source = source
        fetchedAt = date
    }

    var credits: [ReleaseCredit] {
        let count = [categories.count, orders.count, creditedNames.count, filingNames.count,
                     artistDiscogsIDs.count, roles.count, tracks.count].min() ?? 0
        return (0..<count).compactMap { index in
            guard let category = ReleaseCredit.Category(rawValue: categories[index]) else { return nil }
            return ReleaseCredit(
                category: category, order: orders[index],
                creditedName: creditedNames[index], filingName: filingNames[index],
                discogsID: artistDiscogsIDs[index] > 0 ? artistDiscogsIDs[index] : nil,
                role: roles[index], tracks: tracks[index]
            )
        }
    }
}
