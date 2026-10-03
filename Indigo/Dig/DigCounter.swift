//
//  DigCounter.swift
//  Indigo
//
//  How often a node was opened, and a step taken, counted so that two devices
//  can never lose each other's counts.
//
//  CloudKit settles concurrent changes to one record by the last writer. A
//  count kept on `DigVisit` or `DigStep` itself, raised on two devices at once,
//  kept only one device's increments: 3 + 3 settled at 5, not 8. So the count
//  is kept in components, one per (counter, device), and a device only ever
//  writes its own. Concurrent activity cannot overwrite another device's
//  component, because no other device writes it.
//
//  A component's id is derived from what it counts and who writes it, so every
//  copy of it -- however it arrived -- is the same row. Copies merge by taking
//  the largest count and the widest span; components of different devices add.
//  Both rules give one answer in any order, however often they are applied.
//
//  From V7 the components are what is true. `DigVisit.visits`, `firstVisitedAt`
//  and `lastVisitedAt`, and `DigStep.count` and `lastAt`, are projections of
//  them: kept so that every reader, predicate and sort is unchanged, rewritten
//  only when they differ. A build that raised those fields directly would be
//  overwritten by the projection; V7 is the minimum that may write to a synced
//  store, and builds before it are not supported against one.
//

import CryptoKit
import Foundation
import SwiftData

nonisolated enum DigCounterKind: String, Sendable, CaseIterable {
    case visit
    case step
    /// One row that says the store's counters are components. Written once,
    /// when a store's counts are moved into components; read by nothing but an
    /// inspection. Its `count` is the schema version that introduced them.
    case generation
}

/// One device's share of one counter.
@Model
nonisolated final class DigCounter {
    /// `CounterID.make(kind:key:deviceID:)`. Never random: copies of one
    /// component must be one row.
    var id: UUID?
    var kindRaw: String = ""
    /// The node id for a visit; the step's identity for a step.
    var key: String = ""
    /// Which device writes this component, or `CounterID.base` for the count a
    /// store already held when it moved to components.
    var deviceID: String = ""
    var count: Int = 0
    /// When this component's first visit was. A step has no first, so nil.
    var firstAt: Date?
    var lastAt: Date = Date.distantPast

    init(kind: DigCounterKind, key: String, deviceID: String) {
        id = CounterID.make(kind: kind, key: key, deviceID: deviceID)
        kindRaw = kind.rawValue
        self.key = key
        self.deviceID = deviceID
    }

    var kind: DigCounterKind? { DigCounterKind(rawValue: kindRaw) }
}

// MARK: - Ids

nonisolated enum CounterID {
    /// The writer of the counts a store held before it had components.
    static let base = "base"

    /// The id of a component. A persistence contract: once ids are in CloudKit
    /// this algorithm can never change, so it is pinned by test vectors.
    ///
    /// SHA-256 of `kind NUL key NUL deviceID` in UTF-8; the first sixteen bytes,
    /// marked as an RFC 9562 version-8 (custom) UUID. Nothing from `Hasher`.
    static func make(kind: DigCounterKind, key: String, deviceID: String) -> UUID {
        let canonical = "\(kind.rawValue)\u{0}\(key)\u{0}\(deviceID)"
        var bytes = Array(SHA256.hash(data: Data(canonical.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Values

/// A component's mergeable content, so the rules can be tested without a store.
nonisolated struct CounterValue: Equatable, Sendable {
    var deviceID: String
    var count: Int
    var firstAt: Date?
    var lastAt: Date

    init(deviceID: String, count: Int, firstAt: Date? = nil, lastAt: Date) {
        self.deviceID = deviceID; self.count = count; self.firstAt = firstAt; self.lastAt = lastAt
    }

    init(_ row: DigCounter) {
        self.init(deviceID: row.deviceID, count: row.count, firstAt: row.firstAt, lastAt: row.lastAt)
    }

    /// Copies of one component: the largest count, the widest span. Never a sum.
    static func mergedCopies(_ rows: [CounterValue]) -> CounterValue? {
        guard let first = rows.first else { return nil }
        return CounterValue(
            deviceID: first.deviceID,
            count: rows.map(\.count).max()!,
            firstAt: rows.compactMap(\.firstAt).min(),
            lastAt: rows.map(\.lastAt).max()!)
    }

    /// What a counter is: each device's component (its copies merged), added up.
    static func total(_ rows: [CounterValue]) -> (count: Int, firstAt: Date?, lastAt: Date)? {
        guard !rows.isEmpty else { return nil }
        let perDevice = Dictionary(grouping: rows, by: \.deviceID).values.compactMap(mergedCopies)
        return (perDevice.map(\.count).reduce(0, +),
                perDevice.compactMap(\.firstAt).min(),
                perDevice.map(\.lastAt).max()!)
    }
}

// MARK: - A store's counters

nonisolated struct DigCounters {
    let context: ModelContext

    func components(_ kind: DigCounterKind, key: String) -> [DigCounter] {
        let raw = kind.rawValue
        return (try? context.fetch(FetchDescriptor<DigCounter>(
            predicate: #Predicate { $0.kindRaw == raw && $0.key == key }))) ?? []
    }

    /// Adds one to this device's component, making it if it is not there yet.
    func increment(_ kind: DigCounterKind, key: String, deviceID: String, at date: Date) {
        mergeCopies(kind, key: key)
        let id = CounterID.make(kind: kind, key: key, deviceID: deviceID)
        let row = (try? context.fetch(FetchDescriptor<DigCounter>(predicate: #Predicate { $0.id == id })))?.first ?? {
            let fresh = DigCounter(kind: kind, key: key, deviceID: deviceID)
            context.insert(fresh)
            return fresh
        }()
        row.count += 1
        if kind == .visit { row.firstAt = min(row.firstAt ?? date, date) }
        row.lastAt = max(row.lastAt, date)
    }

    /// Folds copies of one component into one row. Returns how many went.
    @discardableResult
    func mergeCopies(_ kind: DigCounterKind, key: String) -> Int {
        mergeCopies(of: components(kind, key: key))
    }

    /// The same, for the components of one counter already in hand. Rows
    /// already deleted are passed over.
    @discardableResult
    func mergeCopies(of components: [DigCounter]) -> Int {
        var removed = 0
        for (_, copies) in Dictionary(grouping: components.filter { !$0.isDeleted }, by: \.deviceID) where copies.count > 1 {
            let kept = copies.min { UserDataDedupe.idIsBefore($0.id, $1.id) }!
            let merged = CounterValue.mergedCopies(copies.map(CounterValue.init))!
            kept.count = merged.count; kept.firstAt = merged.firstAt; kept.lastAt = merged.lastAt
            for copy in copies where copy !== kept { context.delete(copy); removed += 1 }
        }
        return removed
    }

    /// Rewrites a visit's count and span from its components, if it has any and
    /// they say something different. A visit with no components is left as it
    /// is: what it says came from somewhere that does.
    @discardableResult
    func project(_ visit: DigVisit) -> Bool {
        project(visit, from: components(.visit, key: visit.nodeID))
    }

    /// The same, from the visit's components already in hand.
    @discardableResult
    func project(_ visit: DigVisit, from components: [DigCounter]) -> Bool {
        guard let total = CounterValue.total(components.filter { !$0.isDeleted }.map(CounterValue.init)) else { return false }
        let first = total.firstAt ?? Date.distantFuture
        guard visit.visits != total.count || visit.firstVisitedAt != first || visit.lastVisitedAt != total.lastAt else { return false }
        visit.visits = total.count; visit.firstVisitedAt = first; visit.lastVisitedAt = total.lastAt
        return true
    }

    @discardableResult
    func project(_ step: DigStep) -> Bool {
        project(step, from: components(.step, key: step.identity))
    }

    @discardableResult
    func project(_ step: DigStep, from components: [DigCounter]) -> Bool {
        guard let total = CounterValue.total(components.filter { !$0.isDeleted }.map(CounterValue.init)) else { return false }
        guard step.count != total.count || step.lastAt != total.lastAt else { return false }
        step.count = total.count; step.lastAt = total.lastAt
        return true
    }

    /// Every visit and step for `key`, projected again.
    @discardableResult
    func reproject(_ kind: DigCounterKind, key: String) -> Int {
        switch kind {
        case .visit:
            let rows = (try? context.fetch(FetchDescriptor<DigVisit>(predicate: #Predicate { $0.nodeID == key }))) ?? []
            return rows.filter(project).count
        case .step:
            let rows = (try? context.fetch(FetchDescriptor<DigStep>(predicate: #Predicate { $0.identity == key }))) ?? []
            return rows.filter(project).count
        case .generation:
            return 0
        }
    }
}
