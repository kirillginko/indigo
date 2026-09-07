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
    /// What the crate looked like when this was worked out, so a stale answer
    /// can be told from a current one without unpacking it.
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

    /// What was shown last time, if anything, and when.
    func load() -> (offers: ExploreOffers, builtAt: Date, crateRevision: Int)? {
        var descriptor = FetchDescriptor<ExploreOffersRecord>(
            predicate: #Predicate { $0.id == "explore.offers" }
        )
        descriptor.fetchLimit = 1
        guard let record = (try? context.fetch(descriptor))?.first,
              let offers = try? JSONDecoder().decode(ExploreOffers.self, from: record.payload)
        else { return nil }
        return (offers, record.builtAt, record.crateRevision)
    }

    /// Writes the answer down. Failure is silent and harmless: the next launch
    /// simply works it out again, which is what it did before this existed.
    func save(_ offers: ExploreOffers, crateRevision: Int) {
        guard let payload = try? JSONEncoder().encode(offers) else { return }
        var descriptor = FetchDescriptor<ExploreOffersRecord>(
            predicate: #Predicate { $0.id == "explore.offers" }
        )
        descriptor.fetchLimit = 1
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.payload = payload
            existing.builtAt = Date()
            existing.crateRevision = crateRevision
        } else {
            context.insert(ExploreOffersRecord(payload: payload, crateRevision: crateRevision))
        }
        try? context.save()
    }
}
