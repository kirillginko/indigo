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
    /// The evidence tables read once, for a reader that asks about hundreds of
    /// names in one go (`IdentityGraph`). Without one, each question is a fetch.
    var fold: IdentityEvidenceFold? = nil

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

    /// Keeps how much an entry's own record says. `releaseCount` nil is a read
    /// that did not complete, kept as such.
    func recordSummary(of detail: DiscogsArtistDetail, releaseCount: Int?, at date: Date = Date()) {
        record(DiscogsIdentityFacts(detail: detail), at: date)
        guard let held = identityRecord(detail.id) else { return }
        held.summaryHasBiography = !(detail.profile ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        held.summaryImageCount = detail.images?.count ?? 0
        held.summaryLinkCount = detail.urls?.count ?? 0
        if let releaseCount {
            held.summaryReleaseCount = releaseCount
            held.summaryStateRaw = "read"
        } else {
            held.summaryStateRaw = "failed"
        }
        held.summaryCheckedAt = date
    }

    /// What an entry's summary establishes, if it was read.
    func summary(_ discogsID: Int) -> ProfileCompleteness? { identityRecord(discogsID)?.summary }

    /// Whether an entry's summary is worth asking for.
    func summaryIsDue(_ discogsID: Int) -> Bool { identityRecord(discogsID)?.summaryIsDue ?? true }

    // MARK: Reading

    /// A spelling that a fresh, complete check has settled. A stale one is
    /// still evidence, but worth asking again; see `needsCheck`.
    func verdict(for spelling: String) -> SpellingVerdict? {
        if let fold { return fold.verdicts[ArtistSpelling.key(spelling)] }
        return spellingRecord(ArtistSpelling.key(spelling))?.verdict
    }

    /// Whether a spelling has no settled verdict, or one old enough to ask again.
    func needsCheck(_ spelling: String) -> Bool {
        guard let held = spellingRecord(ArtistSpelling.key(spelling)), held.verdict != nil else { return true }
        return held.isStale
    }

    func facts(_ discogsID: Int) -> DiscogsIdentityFacts? {
        if let fold { return fold.facts[discogsID] }
        return identityRecord(discogsID)?.facts
    }

    /// Every spelling a check settled on this entry.
    func creditedSpellings(of discogsID: Int) -> [String] {
        if let fold { return fold.spellings[discogsID] ?? [] }
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

    /// Which artist a page means, and every spelling it should read under.
    ///
    /// Evidence first (`ArtistIdentityResolver`). Failing that, the record
    /// DIG shows: if DIG filed the name's catalogue entry under exactly this
    /// name, the spellings verified for that entry belong on its page too —
    /// "Prefuse 73" gathers "Prefuse73". Only under exactly this name: older
    /// rows in that table were filed by looser matching, and one filed under
    /// another spelling ("walton", holding Rik Walton) must never become a
    /// reason to open somebody else.
    func artistResolution(_ reference: ArtistReference) -> ArtistResolution {
        let resolved = resolve(reference)
        guard !resolved.isVerified else { return resolved }
        guard let shown = filedRecord(named: reference.name),
              shown.discogsID > 0,
              ArtistSpelling.filingKey(shown.name) == ArtistSpelling.key(reference.name)
        else { return resolved }
        let filed = ArtistReference(name: reference.name, mbid: reference.mbid, discogsID: shown.discogsID)
        return resolve(filed).asFiledRecord()
    }

    /// The record DIG filed under a name.
    func filedRecord(named name: String) -> DiscogsArtist? {
        if let fold { return fold.filedRecord(named: name, in: context) }
        return DiscogsEnricher(context: context, client: DiscogsClient()).cachedArtist(named: name)
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

/// What an artist page opens: the identity a reference resolved to, the name
/// and identifiers the page is built from, and how it got there.
nonisolated struct ArtistPageIdentity: Equatable, Sendable {
    /// A richer alias's description, shown on a sparse page and attributed.
    nonisolated struct Borrowed: Equatable, Sendable {
        let name: String
        let discogsID: Int
        let biography: String?
    }

    let reference: ArtistReference
    let resolution: ArtistResolution
    /// What the page is called and read under.
    let name: String
    let mbid: String?
    let discogsID: Int?
    /// Every spelling verified to be the artist the page shows.
    let alsoCreditedAs: [String]
    /// Set when the page opened a richer alias in place of one with no record
    /// of its own: the name the listener came from.
    let cameFrom: String?
    let borrowed: Borrowed?
    /// Whether the name is still being resolved; see `PageHeader.titlePending`.
    var titlePending = false

    /// The spelling the listener asked for, when the page is filed otherwise.
    var arrivedAs: String? {
        guard cameFrom == nil, resolution.isRedirect else { return nil }
        return reference.name
    }

    /// Identifies the page, so a change of identity is a different page.
    var pageID: String { "\(discogsID.map { "discogs:\($0)" } ?? resolution.identity.rawValue)|\(ArtistSpelling.key(name))" }

    func borrowing(_ borrowed: Borrowed) -> ArtistPageIdentity {
        ArtistPageIdentity(
            reference: reference, resolution: resolution, name: name, mbid: mbid,
            discogsID: discogsID, alsoCreditedAs: alsoCreditedAs, cameFrom: cameFrom, borrowed: borrowed,
            titlePending: titlePending
        )
    }
}

/// Who each release credits, by Discogs id, as its source document says.
nonisolated struct ReleaseCreditStore {
    let context: ModelContext

    /// Where a release document came from, for its credits' provenance.
    static func source(discogsRelease id: Int) -> String { "discogs:releases/\(id)" }
    static func source(storedRelease id: Int) -> String { "r2:releases/\(id).json" }

    /// Replaces a release's credits with what this document says.
    ///
    /// All of them or none: a document without its artists block is an
    /// incomplete answer and leaves what an earlier one said exactly as it was.
    @discardableResult
    func replace(releaseID: Int, from detail: DiscogsReleaseDetail, source: String, at date: Date = Date()) -> Bool {
        guard releaseID > 0, let credits = ReleaseCredit.credits(in: detail) else { return false }
        if let held = record(releaseID) {
            held.replace(with: credits, source: source, at: date)
        } else {
            context.insert(ReleaseCreditRecord(releaseDiscogsID: releaseID, credits: credits, source: source, fetchedAt: date))
        }
        return true
    }

    /// The release's credits, or nil when none have been kept for it.
    func credits(releaseID: Int) -> [ReleaseCredit]? { record(releaseID)?.credits }

    func provenance(releaseID: Int) -> String? { record(releaseID)?.source }

    private func record(_ id: Int) -> ReleaseCreditRecord? {
        var descriptor = FetchDescriptor<ReleaseCreditRecord>(predicate: #Predicate { $0.releaseDiscogsID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// The identity evidence read once: every settled spelling, every entry's
/// facts and every release's credits — small tables — and DIG's filed records
/// through a fold somebody has already made (`GraphStore`), or one at a time
/// when nobody has. Answers exactly what `ArtistIdentityStore` answers by
/// fetching, for as long as nothing is written; a reader keeps one for a
/// generation, and every write starts another.
nonisolated final class IdentityEvidenceFold {
    let verdicts: [String: SpellingVerdict]
    let spellings: [Int: [String]]
    let facts: [Int: DiscogsIdentityFacts]
    /// Every release's kept credits, by release id.
    let credits: [Int: [ReleaseCredit]]
    /// DIG's filed record under a name from a fold already assembled, or nil
    /// when there is none to ask.
    let filed: (String) -> DiscogsArtist??
    private var byKey: [String: DiscogsArtist]?
    private var fetched: [String: DiscogsArtist?] = [:]
    /// Below this many names, one fetch each; past it, every record at once.
    private static let fetchedAlone = 64

    /// From the assembled fold when there is one. Otherwise a few names are
    /// fetched one at a time — the twelve artists of a listener's history
    /// cost a second when they read five thousand records to place them — and
    /// past a few dozen, every filed record's name and id in one fetch: a walk
    /// asks about hundreds, and a fetch apiece was three seconds of For You's
    /// walks on a real store. Never what assembles the graph's six tables.
    func filedRecord(named name: String, in context: ModelContext) -> DiscogsArtist? {
        if let assembled = filed(name) { return assembled }
        let key = RecordingKey.normalizeArtist(name)
        if byKey == nil {
            if let held = fetched[key] { return held }
            if fetched.count < Self.fetchedAlone {
                let found = DiscogsEnricher(context: context, client: DiscogsClient()).cachedArtist(named: name)
                fetched[key] = found
                return found
            }
            var descriptor = FetchDescriptor<DiscogsArtist>()
            descriptor.propertiesToFetch = [\.nameKey, \.discogsID, \.name]
            byKey = Dictionary(((try? context.fetch(descriptor)) ?? []).map { ($0.nameKey, $0) },
                               uniquingKeysWith: { first, _ in first })
        }
        return byKey?[key]
    }

    init(context: ModelContext, filed: @escaping (String) -> DiscogsArtist??) {
        var verdicts: [String: SpellingVerdict] = [:]
        var spellings: [Int: [String]] = [:]
        for record in (try? context.fetch(FetchDescriptor<ArtistSpellingRecord>())) ?? [] {
            guard let verdict = record.verdict else { continue }
            verdicts[record.spellingKey] = verdict
            if case .variation(let id) = verdict { spellings[id, default: []].append(record.spelling) }
        }
        self.verdicts = verdicts
        self.spellings = spellings.mapValues { $0.sorted() }
        var facts: [Int: DiscogsIdentityFacts] = [:]
        for record in (try? context.fetch(FetchDescriptor<DiscogsIdentityRecord>())) ?? [] {
            facts[record.discogsID] = record.facts
        }
        self.facts = facts
        var credits: [Int: [ReleaseCredit]] = [:]
        for record in (try? context.fetch(FetchDescriptor<ReleaseCreditRecord>())) ?? [] {
            credits[record.releaseDiscogsID] = record.credits
        }
        self.credits = credits
        self.filed = filed
    }

    deinit {}
}
