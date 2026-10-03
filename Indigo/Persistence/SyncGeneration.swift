//
//  SyncGeneration.swift
//  Indigo
//
//  Which representation of the synced store this build understands, and what
//  it does when the store says it was written by one it does not.
//
//  The store carries its generation in one row: the `DigCounter` of kind
//  `generation`, key "counters", written by `CounterBaseline` with the schema
//  version that made counter components authoritative. Its id is fixed, so
//  every device's copy is the same row, and copies merge by their largest
//  count. A later build that changes what synced rows mean raises that count.
//
//  This build understands generation 7. A store that says more was written by
//  a newer build, and this one would rewrite it by its own rules -- the
//  projection overwrites `DigVisit.visits` from components as V7 reads them. So
//  it does not mirror that store and does not write to it: the library opens
//  to be read, and the listener is told to update. This cannot protect anything
//  from builds before V7, which do not have it; none was ever signed for
//  Production.
//

import Foundation
import SwiftData

nonisolated enum SyncGeneration {
    /// The newest generation this build may write to.
    static let understood = CounterBaseline.generation

    /// The generation a store's rows advertise, read from the file before
    /// SwiftData opens it, so that a store from a newer build is never mirrored
    /// by this one. Nil for a new store, or one with no marker yet.
    static func advertised(inStoreAt url: URL) -> Int? {
        SQLiteFiles.integer(
            "SELECT MAX(ZCOUNT) FROM ZDIGCOUNTER WHERE ZKINDRAW = '\(DigCounterKind.generation.rawValue)'", in: url)
    }

    /// The same, through a context: for rows that arrive while the app runs.
    static func advertised(in context: ModelContext) -> Int? {
        let kind = DigCounterKind.generation.rawValue
        let rows = (try? context.fetch(FetchDescriptor<DigCounter>(predicate: #Predicate { $0.kindRaw == kind }))) ?? []
        return rows.map(\.count).max()
    }

    static func isNewer(_ generation: Int?) -> Bool {
        (generation ?? 0) > understood
    }

    static let notice =
        "Your library was updated by a newer version of Indigo. Update Indigo on this device to keep saving and syncing."
}
