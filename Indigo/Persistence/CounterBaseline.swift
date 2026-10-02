//
//  CounterBaseline.swift
//  Indigo
//
//  The move of a store's counts into components (V7). Every visit and step a
//  store held before V7 has its count in `DigVisit.visits` or `DigStep.count`;
//  each becomes one `base` component, so that the projection of the components
//  is exactly what the row said before.
//
//  It happens to a store that was written before V7 -- one whose model has no
//  `DigCounter` -- and to nothing else. A new device's store is born at V7, and
//  the rows it imports already carry projections; taking those as a base would
//  count everything twice. So the decision is made from the store file's own
//  metadata, before it is opened, and written down in a marker file, so that a
//  launch interrupted after the store was migrated and before the base was
//  written finishes the job the next time.
//
//  Writing it twice changes nothing: a base component's id depends only on what
//  it counts, and copies merge by their largest count.
//
//  Relies on a fact about the rollout, not a general truth: V7 arrives before
//  more than one installation has accumulated counts of its own. Two stores
//  that each counted separately before V7 would each write a base for the same
//  counter, and the larger of two partly different histories is not their sum.
//

import CoreData
import Foundation
import SwiftData

nonisolated enum CounterBaseline {
    /// The schema version that made components authoritative.
    static let generation = 7

    static func marker(in layout: StoreLayout) -> URL {
        layout.directory.appendingPathComponent("counter-baseline-pending")
    }

    /// Before the store is opened: whether it predates components, and if so,
    /// remember that its counts still have to move.
    static func prepare(layout: StoreLayout) {
        guard needsBaseline(store: layout.userData) else { return }
        FileManager.default.createFile(atPath: marker(in: layout).path, contents: Data())
        Trace.note("counters: UserData predates components; their base will be written after it opens")
    }

    /// After it is opened: write the base if it is owed, then forget the debt.
    static func complete(layout: StoreLayout, context: ModelContext) throws {
        let pending = marker(in: layout)
        guard FileManager.default.fileExists(atPath: pending.path) else { return }
        let written = try create(in: context)
        try FileManager.default.removeItem(at: pending)
        Trace.note("counters: base written for \(written.visits) visits and \(written.steps) steps")
    }

    /// A store on disk whose model has no `DigCounter`, with rows in it.
    static func needsBaseline(store url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url),
              let hashes = metadata["NSStoreModelVersionHashes"] as? [String: Any]
        else { return false }
        return hashes["DigCounter"] == nil && (hashes["DigVisit"] != nil || hashes["DigStep"] != nil)
    }

    /// One `base` component per visit and step, carrying what the row says now.
    /// Rows for one thing are folded first, by the rule they had before V7 --
    /// their counts add -- so the base is one count, not one per copy.
    @discardableResult
    static func create(in context: ModelContext) throws -> (visits: Int, steps: Int) {
        // Whole tables, once: a query per counter took sixteen seconds on a
        // real store, at launch.
        let dedupe = UserDataDedupe(context: context)
        var existing = Dictionary(
            ((try? context.fetch(FetchDescriptor<DigCounter>())) ?? []).compactMap { row in row.id.map { ($0, row) } },
            uniquingKeysWith: { first, _ in first })
        var visits = 0, steps = 0

        let visitGroups = Dictionary(grouping: (try? context.fetch(FetchDescriptor<DigVisit>())) ?? [], by: \.nodeID)
        for (nodeID, rows) in visitGroups {
            if rows.count > 1 { dedupe.legacyVisit(nodeID: nodeID) }
            guard let visit = rows.first(where: { !$0.isDeleted }), visit.visits > 0 else { continue }
            write(.visit, key: nodeID, count: visit.visits, firstAt: visit.firstVisitedAt,
                  lastAt: visit.lastVisitedAt, existing: &existing, context: context)
            visits += 1
        }
        let stepGroups = Dictionary(grouping: (try? context.fetch(FetchDescriptor<DigStep>())) ?? [], by: \.identity)
        for (identity, rows) in stepGroups {
            if rows.count > 1 { dedupe.legacyStep(identity: identity) }
            guard let step = rows.first(where: { !$0.isDeleted }), step.count > 0 else { continue }
            write(.step, key: identity, count: step.count, firstAt: nil, lastAt: step.lastAt,
                  existing: &existing, context: context)
            steps += 1
        }
        let generation = CounterID.make(kind: .generation, key: "counters", deviceID: CounterID.base)
        if existing[generation] == nil {
            let row = DigCounter(kind: .generation, key: "counters", deviceID: CounterID.base)
            row.count = Self.generation
            context.insert(row)
        }
        try context.save()
        return (visits, steps)
    }

    private static func write(
        _ kind: DigCounterKind, key: String, count: Int, firstAt: Date?, lastAt: Date,
        existing: inout [UUID: DigCounter], context: ModelContext
    ) {
        let id = CounterID.make(kind: kind, key: key, deviceID: CounterID.base)
        let row = existing[id] ?? {
            let fresh = DigCounter(kind: kind, key: key, deviceID: CounterID.base)
            context.insert(fresh)
            existing[id] = fresh
            return fresh
        }()
        // A base already written by an interrupted run is never lowered.
        row.count = max(row.count, count)
        if kind == .visit, let firstAt, firstAt != Date.distantFuture { row.firstAt = min(row.firstAt ?? firstAt, firstAt) }
        row.lastAt = max(row.lastAt, lastAt)
    }
}
