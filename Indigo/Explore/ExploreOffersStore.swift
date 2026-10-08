//
//  ExploreOffersStore.swift
//  Indigo
//
//  The last answer, kept across launches.
//
//  Working out what to suggest reads the crate, the listening log, the whole
//  artist cache and a dozen graph walks — a second and more on a real
//  collection. Held only in memory, that cost is paid on every start: the page
//  opens without its headline block and grows one a second later, which is the
//  page appearing to load twice.
//
//  So the answer is written down. A launch draws what it drew last time, and
//  the recomputation happens behind it — the same bargain the crate's row cache
//  makes within a session, extended to survive one.
//
//  Nothing here is a source of truth. It is one row holding one JSON blob, and
//  losing it costs a second the next time somebody opens the page.
//

import Foundation
import SwiftData

@Model
nonisolated final class ExploreOffersRecord {
    /// There is only ever one. A fixed key rather than a table of rows,
    /// because "the last answer" is singular.
    @Attribute(.unique) var id: String
    var payload: Data
    var builtAt: Date
    /// No longer read. It held the crate's in-process revision, which starts
    /// again at nought every launch and so said nothing about a record written
    /// by another one; what an answer was worked out from is now kept in the
    /// payload as its `ExploreStamp`. Left in place rather than migrated away.
    var crateRevision: Int

    init(payload: Data, builtAt: Date = Date(), crateRevision: Int) {
        self.id = ExploreOffersRecord.key
        self.payload = payload
        self.builtAt = builtAt
        self.crateRevision = crateRevision
    }

    static let key = "explore.offers"
}

nonisolated struct ExploreOffersStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// The payload: the answer and what it was worked out from -- the stamp
    /// of the whole answer, and of its first half (everything but the
    /// direction). An answer written before stamps were kept has neither, and
    /// is redrawn and then worked out again.
    private struct Kept: Codable {
        let stamp: ExploreStamp
        let core: ExploreStamp
        let offers: ExploreOffers
    }

    /// What was shown last time, if anything, when, and from what.
    func load() -> (offers: ExploreOffers, builtAt: Date, stamp: ExploreStamp?, core: ExploreStamp?)? {
        var descriptor = FetchDescriptor<ExploreOffersRecord>(
            predicate: #Predicate { $0.id == "explore.offers" }
        )
        descriptor.fetchLimit = 1
        guard let record = (try? context.fetch(descriptor))?.first else { return nil }
        if let kept = try? JSONDecoder().decode(Kept.self, from: record.payload) {
            return (kept.offers, record.builtAt, kept.stamp, kept.core)
        }
        guard let offers = try? JSONDecoder().decode(ExploreOffers.self, from: record.payload) else { return nil }
        return (offers, record.builtAt, nil, nil)
    }

    /// Writes the answer down. Failure is silent and harmless: the next launch
    /// simply works it out again, which is what it did before this existed.
    func save(_ offers: ExploreOffers, stamp: ExploreStamp, core: ExploreStamp) {
        guard let payload = try? JSONEncoder().encode(Kept(stamp: stamp, core: core, offers: offers)) else { return }
        var descriptor = FetchDescriptor<ExploreOffersRecord>(
            predicate: #Predicate { $0.id == "explore.offers" }
        )
        descriptor.fetchLimit = 1
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.payload = payload
            existing.builtAt = Date()
        } else {
            context.insert(ExploreOffersRecord(payload: payload, crateRevision: 0))
        }
        try? context.save()
    }
}
