//
//  ArtistIdentityStore.swift
//  Indigo
//
//  Where the identity evidence DIG has gathered is written, and read back for
//  `ArtistIdentityResolver`.
//
//  Small tables, read by unique key or whole: a spelling check per spelling
//  anybody opened that Discogs files under another name, and an entry per
//  artist DIG has described. Reading the variations as a whole table and
//  filtering here, rather than in a predicate over an array, is deliberate —
//  see `StorePredicateTests`.
//

import Foundation
import SwiftData

nonisolated struct ArtistIdentityStore {
    let context: ModelContext

    // MARK: Writing

    /// Keeps a completed check and every entry it read.
    func record(_ check: DiscogsSpellingCheck, at date: Date = Date()) {
        for facts in check.facts { record(facts, at: date) }
        let key = ArtistSpelling.key(check.spelling)
        guard !key.isEmpty else { return }
        if let held = spellingRecord(key) {
            held.spelling = check.spelling
            held.verdict = check.verdict
            held.resultCount = check.resultCount
            held.checkedAt = date
        } else {
            context.insert(ArtistSpellingRecord(
                spelling: check.spelling, verdict: check.verdict,
                resultCount: check.resultCount, checkedAt: date
            ))
        }
    }

    /// Keeps what an entry says about who it is.
    func record(_ facts: DiscogsIdentityFacts, at date: Date = Date()) {
        guard facts.id > 0 else { return }
        if let held = identityRecord(facts.id) {
            held.update(from: facts, at: date)
        } else {
            context.insert(DiscogsIdentityRecord(facts: facts, fetchedAt: date))
        }
    }

    // MARK: Reading

    /// A spelling that a fresh, complete check has settled. A stale one is
    /// still evidence, but worth asking again; see `needsCheck`.
    func verdict(for spelling: String) -> SpellingVerdict? {
        spellingRecord(ArtistSpelling.key(spelling))?.verdict
    }

    /// Whether a spelling has no settled verdict, or one old enough to ask again.
    func needsCheck(_ spelling: String) -> Bool {
        guard let held = spellingRecord(ArtistSpelling.key(spelling)), held.verdict != nil else { return true }
        return held.isStale
    }

    func facts(_ discogsID: Int) -> DiscogsIdentityFacts? { identityRecord(discogsID)?.facts }

    /// Every spelling a check settled on this entry.
    func creditedSpellings(of discogsID: Int) -> [String] {
        let records = (try? context.fetch(FetchDescriptor<ArtistSpellingRecord>())) ?? []
        return records
            .filter { $0.verdict == .variation(discogsID) }
            .map(\.spelling)
            .sorted()
    }

    /// The evidence one reference needs: its own spelling's verdict, the
    /// entries that verdict and the reference name, and every spelling settled
    /// on those entries.
    func evidence(for reference: ArtistReference) -> ArtistIdentityEvidence {
        var spellings: [String: SpellingVerdict] = [:]
        var ids = Set<Int>()
        if let id = reference.discogsID { ids.insert(id) }
        let key = ArtistSpelling.key(reference.name)
        if let verdict = verdict(for: reference.name) {
            spellings[key] = verdict
            switch verdict {
            case .canonical(let found), .ambiguous(let found): ids.formUnion(found)
            case .variation(let id): ids.insert(id)
            case .nobody: break
            }
        }
        var facts: [DiscogsIdentityFacts] = []
        for id in ids.sorted() {
            guard let found = self.facts(id) else { continue }
            facts.append(found)
            for spelling in creditedSpellings(of: id) {
                spellings[ArtistSpelling.key(spelling)] = .variation(id)
            }
        }
        return ArtistIdentityEvidence(facts: facts, spellings: spellings)
    }

    func resolve(_ reference: ArtistReference) -> ArtistResolution {
        ArtistIdentityResolver(evidence: evidence(for: reference)).resolve(reference)
    }

    // MARK: -

    private func spellingRecord(_ key: String) -> ArtistSpellingRecord? {
        guard !key.isEmpty else { return nil }
        var descriptor = FetchDescriptor<ArtistSpellingRecord>(predicate: #Predicate { $0.spellingKey == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func identityRecord(_ id: Int) -> DiscogsIdentityRecord? {
        var descriptor = FetchDescriptor<DiscogsIdentityRecord>(predicate: #Predicate { $0.discogsID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
