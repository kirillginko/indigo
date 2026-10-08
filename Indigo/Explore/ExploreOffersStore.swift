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
    /// payload as `ExploreInputs`. Left in place rather than migrated away.
    var crateRevision: Int

    init(payload: Data, builtAt: Date = Date(), crateRevision: Int) {
        self.id = ExploreOffersRecord.key
        self.payload = payload
        self.builtAt = builtAt
        self.crateRevision = crateRevision
    }

    static let key = "explore.offers"
}

/// What an answer was worked out from, in the few numbers that move when it
/// changes: the synced rows EXPLORE reads, counted, with their newest date --
/// and the dig history's starting points, which change by count rather than by
/// row -- and the period it was worked out for.
///
/// The period is a UTC day. Listening is weighed by how long ago it was, so an
/// answer depends on *when* as well as on the rows; measured from the clock,
/// two devices working out the same rows a minute apart weighed every play a
/// little differently. Measured from the end of the day instead (`asOf`), the
/// same rows give the same answer all day on every device, and the next day
/// is a change of input like any other, so the answer is worked out again.
/// The clock decides only which day it is.
///
/// Read from the store rather than from anything this process remembers, so
/// it means the same after a relaunch and after another device's import as it
/// does after a local save. A fold rather than a table walk: two counts, two
/// one-row fetches and the dozen haunts the engine itself starts from.
nonisolated struct ExploreInputs: Codable, Equatable, Sendable {
    var crateCount: Int
    var crateNewest: Date?
    var eventCount: Int
    var eventNewest: Date?
    /// `nodeID×visits`, in the order the engine reads them.
    var haunts: [String]
    /// Days since 1970, UTC.
    var period: Int

    static let periodLength: TimeInterval = 24 * 60 * 60

    static func period(containing moment: Date) -> Int {
        Int((moment.timeIntervalSince1970 / periodLength).rounded(.down))
    }

    /// The end of the period: no play inside it is in its future.
    var asOf: Date { Date(timeIntervalSince1970: Double(period + 1) * Self.periodLength) }

    static func read(context: ModelContext, now: Date = Date()) -> ExploreInputs {
        var crate = FetchDescriptor<CrateItem>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
        crate.fetchLimit = 1
        var events = FetchDescriptor<ListeningEvent>(sortBy: [SortDescriptor(\.at, order: .reverse)])
        events.fetchLimit = 1
        return ExploreInputs(
            crateCount: (try? context.fetchCount(FetchDescriptor<CrateItem>())) ?? -1,
            crateNewest: (try? context.fetch(crate))?.first?.addedAt,
            eventCount: (try? context.fetchCount(FetchDescriptor<ListeningEvent>())) ?? -1,
            eventNewest: (try? context.fetch(events))?.first?.at,
            haunts: DigHistory(context: context)
                .haunts(kinds: ExploreSuggestionEngine.hauntKinds, limit: ExploreSuggestionEngine.hauntLimit)
                .map { "\($0.nodeID)×\($0.visits)" },
            period: period(containing: now)
        )
    }
}

nonisolated struct ExploreOffersStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// The payload: the answer and what it was worked out from. An answer
    /// written before the inputs were kept has none, and is redrawn and then
    /// worked out again.
    private struct Kept: Codable {
        let inputs: ExploreInputs
        let offers: ExploreOffers
    }

    /// What was shown last time, if anything, when, and from what.
    func load() -> (offers: ExploreOffers, builtAt: Date, inputs: ExploreInputs?)? {
        var descriptor = FetchDescriptor<ExploreOffersRecord>(
            predicate: #Predicate { $0.id == "explore.offers" }
        )
        descriptor.fetchLimit = 1
        guard let record = (try? context.fetch(descriptor))?.first else { return nil }
        if let kept = try? JSONDecoder().decode(Kept.self, from: record.payload) {
            return (kept.offers, record.builtAt, kept.inputs)
        }
        guard let offers = try? JSONDecoder().decode(ExploreOffers.self, from: record.payload) else { return nil }
        return (offers, record.builtAt, nil)
    }

    /// Writes the answer down. Failure is silent and harmless: the next launch
    /// simply works it out again, which is what it did before this existed.
    func save(_ offers: ExploreOffers, inputs: ExploreInputs) {
        guard let payload = try? JSONEncoder().encode(Kept(inputs: inputs, offers: offers)) else { return }
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
