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
