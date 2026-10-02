//
//  SplitMigration.swift
//  Indigo
//
//  Moves the listener from one store to two: what they made into `UserData`,
//  and a copy of everything else into `Local`.
//
//  What it never does is open the old store. `default.store` is copied as bytes,
//  and everything after that is done to the copy. SwiftData opening a store with
//  a schema that leaves something out drops what it left out, and the old store
//  is the only complete record of what the listener made until the new ones have
//  been checked against it.
//
//  Three phases, each repeatable, and the sidecar says which is next:
//
//    copyingLocal       snapshot the old store; build `Local.store` from a copy of
//                       it, with the listener's rows emptied out, and check it.
//    migratingUserData  read the snapshot through the shape it had, rewrite what
//                       names a local recording to name the portable identity,
//                       merge what that puts on one node, and write the result
//                       to `UserData.store` in one save.
//    verifying          check what arrived against what was there.
//
//  `UserData` gets its rows in one save, so it holds all of them or none, and a
//  launch that finds it half-way has nothing to repair. Only when verifying has
//  passed is `splitComplete` written, and after that this launch and every later
//  one treat `UserData` as the truth.
//

import Foundation
import SwiftData
import CryptoKit

nonisolated enum SplitMigrationError: Error, CustomStringConvertible {
    /// Raised by tests after a phase, to stand for the process dying there.
    case interrupted(SplitPhase)
    case verificationFailed([String])
    case unexpectedUserData(String)
    case localCopyIncomplete(String)

    var description: String {
        switch self {
        case .interrupted(let phase): return "interrupted after \(phase.rawValue)"
        case .verificationFailed(let problems): return "verification failed: \(problems.joined(separator: "; "))"
        case .unexpectedUserData(let why): return "unexpected data in the new store: \(why)"
        case .localCopyIncomplete(let why): return "the local copy is incomplete: \(why)"
        }
    }
}

// MARK: - What the old store held, and what it becomes

/// One legacy row, with the local recording it pointed at, if any.
nonisolated struct LegacyCrate { var value: CrateValue; var recordingID: UUID? }
nonisolated struct LegacyEvent { var value: EventValue; var recordingID: UUID? }
nonisolated struct LegacyVisit { var value: VisitValue; var recordingID: UUID? }

nonisolated struct LegacyUserData {
    var crate: [LegacyCrate] = []
    var events: [LegacyEvent] = []
    var visits: [LegacyVisit] = []
    var steps: [StepValue] = []
}

nonisolated struct MigratedUserData: Equatable {
    var crate: [CrateValue] = []
    var events: [EventValue] = []
    var visits: [VisitValue] = []
    var steps: [StepValue] = []

    var eventsRewritten = 0
    var visitsRewritten = 0
    var stepsRewritten = 0
    var merged = 0
    /// Rows whose recording is not in the store. Kept, with the key they had.
    var unresolved = 0
    var ambiguousSteps = 0
    var crateSnapshotsMade = 0
}

nonisolated enum UserDataTransform {
    /// A stable id for a row that never had one, so that doing this twice gives
    /// the same rows.
    static func stableID(_ seed: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The old rows, written as the new shape wants them.
    ///
    /// `recording(id)` finds the recording this device holds for a local id --
    /// in `Local`, where the ids were kept -- and `snapshot(recording)` is what a
    /// crate row keeps of one. Neither is called for a row that does not need it.
    static func transform(
        _ old: LegacyUserData,
        recording: (UUID) -> Recording?,
        snapshot: (Recording) -> CrateSnapshot
    ) -> MigratedUserData {
        var result = MigratedUserData()
        var targets: [String: Set<String>] = [:]     // old node id -> new node ids

        // The crate. A row crated before it kept its own snapshot is given one
        // from the recording it pointed at.
        for row in old.crate {
            var value = row.value
            let unnamed = value.kindRaw == CrateItemKind.recording.rawValue
                && value.matchKey.isEmpty && value.unknownCode == nil
            if unnamed, let id = row.recordingID, let found = recording(id) {
                let kept = snapshot(found)
                value.matchKey = kept.matchKey; value.unknownCode = kept.unknownCode
                value.title = kept.title; value.artistName = kept.artistName; value.albumTitle = kept.albumTitle
                value.identificationStatusRaw = kept.identificationStatusRaw
                value.providerID = value.providerID ?? kept.providerID
                value.showID = value.showID ?? kept.showID
                value.showTitle = value.showTitle ?? kept.showTitle
                value.stationName = kept.stationName
                value.broadcastOffsetSeconds = kept.broadcastOffsetSeconds
                if value.playbackURLString == nil { value.playbackURLString = kept.playbackURLString }
                if value.embedProviderRaw == nil { value.embedProviderRaw = kept.embedProviderRaw }
                if (value.artworkURLString ?? "").isEmpty { value.artworkURLString = kept.artworkURLString }
                result.crateSnapshotsMade += 1
            } else if unnamed {
                result.unresolved += 1
            }
            result.crate.append(value)
        }

        // Events keep their ids. One that names a local recording is rewritten
        // to name its identity.
        for row in old.events {
            var value = row.value
            if let id = row.recordingID {
                if let found = recording(id) {
                    let node = MusicNode.recording(found)
                    targets[value.nodeID, default: []].insert(node.id)
                    if value.nodeID != node.id {
                        value.nodeID = node.id; value.nodeKindRaw = node.kind.rawValue; value.nodeKey = node.key
                        result.eventsRewritten += 1
                    }
                } else {
                    result.unresolved += 1
                }
            }
            result.events.append(value)
        }

        // Visits. A row that never had an id is given a stable one.
        var visits: [VisitValue] = []
        for row in old.visits {
            var value = row.value
            let oldNodeID = value.nodeID
            if value.id == nil { value.id = stableID("indigo.visit|\(oldNodeID)") }
            if let id = row.recordingID {
                if let found = recording(id) {
                    let node = MusicNode.recording(found)
                    targets[oldNodeID, default: []].insert(node.id)
                    if oldNodeID != node.id {
                        value.nodeID = node.id; value.kindRaw = node.kind.rawValue
                        result.visitsRewritten += 1
                    }
                } else {
                    result.unresolved += 1
                }
            }
            visits.append(value)
        }
        for group in Dictionary(grouping: visits, by: \.nodeID).values.sorted(by: { $0[0].nodeID < $1[0].nodeID }) {
            result.merged += group.count - 1
            result.visits.append(VisitValue.merged(group)!)
        }

        // Steps follow the nodes they join, where the old id meant one thing.
        let moves = targets.compactMapValues { $0.count == 1 ? $0.first : nil }.filter { $0.key != $0.value }
        let ambiguous = Set(targets.filter { $0.value.count > 1 }.keys)
        var steps: [StepValue] = []
        for var value in old.steps {
            if ambiguous.contains(value.fromNodeID) || ambiguous.contains(value.toNodeID) { result.ambiguousSteps += 1 }
            let from = moves[value.fromNodeID] ?? value.fromNodeID
            let to = moves[value.toNodeID] ?? value.toNodeID
            if from != value.fromNodeID || to != value.toNodeID {
                value.fromNodeID = from; value.toNodeID = to
                value.identity = DigStep.canonicalIdentity(from: from, to: to)
                result.stepsRewritten += 1
            }
            if value.id == nil { value.id = stableID("indigo.step|\(value.identity)") }
            steps.append(value)
        }
        for group in Dictionary(grouping: steps, by: \.identity).values.sorted(by: { $0[0].identity < $1[0].identity }) {
            result.merged += group.count - 1
            result.steps.append(StepValue.merged(group)!)
        }

        result.crate.sort { $0.id.uuidString < $1.id.uuidString }
        result.events.sort { $0.id.uuidString < $1.id.uuidString }
        return result
    }
}

// MARK: - Reading the old shape

/// The old store, read through the last shape that held the bridge fields.
nonisolated enum LegacyReader {
    /// Reads the user-owned rows from a copy of the old store. The copy is
    /// brought to V5 first, which changes only the copy, and nothing is saved.
    static func read(copy url: URL) throws -> LegacyUserData {
        let schema = Schema(versionedSchema: IndigoSchemaV5.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: IndigoLegacyMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        let context = ModelContext(container)
        var old = LegacyUserData()

        for row in try context.fetch(FetchDescriptor<IndigoSchemaV5.CrateItem>()) {
            var value = CrateValue(id: row.id, kindRaw: row.kindRaw, addedAt: row.addedAt)
            value.matchKey = row.matchKey; value.unknownCode = row.unknownCode
            value.title = row.title; value.artistName = row.artistName; value.albumTitle = row.albumTitle
            value.identificationStatusRaw = row.identificationStatusRaw
            value.stationName = row.stationName; value.broadcastOffsetSeconds = row.broadcastOffsetSeconds
            value.providerID = row.providerID; value.showID = row.showID
            value.showTitle = row.showTitle; value.showSubtitle = row.showSubtitle
            value.artworkURLString = row.artworkURLString; value.playbackURLString = row.playbackURLString
            value.embedProviderRaw = row.embedProviderRaw; value.isLiveStream = row.isLiveStream
            value.genreTagsRaw = row.genreTagsRaw
            old.crate.append(LegacyCrate(value: value, recordingID: row.legacyRecording?.id))
        }
        for row in try context.fetch(FetchDescriptor<IndigoSchemaV5.ListeningEvent>()) {
            let value = EventValue(
                id: row.id, at: row.at, actionRaw: row.actionRaw, nodeID: row.nodeID,
                nodeKindRaw: row.nodeKindRaw, nodeKey: row.nodeKey, title: row.title, subtitle: row.subtitle,
                mbid: row.mbid, discogsID: row.discogsID, providerID: row.providerID, handle: row.handle,
                sourceProviderID: row.sourceProviderID, sourceShowID: row.sourceShowID,
                sourceShowTitle: row.sourceShowTitle, seconds: row.seconds, completion: row.completion,
                tags: row.tags)
            old.events.append(LegacyEvent(value: value, recordingID: row.legacyRecordingID))
        }
        for row in try context.fetch(FetchDescriptor<IndigoSchemaV5.DigVisit>()) {
            let value = VisitValue(
                id: row.id, nodeID: row.nodeID, kindRaw: row.kindRaw, title: row.title, subtitle: row.subtitle,
                visits: row.visits, firstVisitedAt: row.firstVisitedAt, lastVisitedAt: row.lastVisitedAt,
                mbid: row.mbid, discogsID: row.discogsID, providerID: row.providerID, handle: row.handle)
            old.visits.append(LegacyVisit(value: value, recordingID: row.legacyRecordingID))
        }
        for row in try context.fetch(FetchDescriptor<DigStep>()) {
            old.steps.append(StepValue(row))
        }
        return old
    }
}

// MARK: - The move

nonisolated struct SplitMigration {
    var layout: StoreLayout
    /// Tests stop the move after one of these, standing for the process dying
    /// there, and then run it again.
    var crashAt: Checkpoint? = nil

    nonisolated enum Checkpoint: String, CaseIterable, Sendable {
        case markedCopying, localBuilt, markedMigrating, userDataSaved, markedVerifying, verified
    }

    private var stateStore: SplitStateStore { SplitStateStore(url: layout.sidecar) }

    private func reach(_ checkpoint: Checkpoint) throws {
        if crashAt == checkpoint { throw SplitMigrationError.interrupted(.legacy) }
    }

    /// The tables of the listener's own rows, which `Local` does not keep.
    private static var userTables: [String] { IndigoSchemaV6.userDataModelNames.sorted().map { "Z" + $0.uppercased() } }
    private static var localTables: [String] {
        IndigoSchemaV6.localModels.map { "Z" + String(describing: $0).uppercased() }
    }

    /// Carries the move as far as it will go, and returns the container for the
    /// split stores once it has been checked and recorded. Throws, leaving the old
    /// store as it was and the state at the phase that failed, if it cannot.
    func run() throws -> ModelContainer {
        var state: SplitState
        switch stateStore.load() {
        case .valid(let found): state = found
        case .missing: state = SplitState(phase: .legacy)
        case .unreadable: throw SplitMigrationError.unexpectedUserData("the state file cannot be read")
        }
        if state.phase == .splitComplete { return try Persistence.openSplitStores(layout: layout) }

        func mark(_ phase: SplitPhase) throws {
            state.phase = phase
            try stateStore.save(state)
        }

        if state.phase == .legacy {
            try mark(.copyingLocal)
            try reach(.markedCopying)
        }
        if state.phase == .copyingLocal {
            state.legacyCounts = try buildLocal()
            try reach(.localBuilt)
            try mark(.migratingUserData)
            try reach(.markedMigrating)
        }
        if state.phase == .migratingUserData {
            do {
                state.migratedCounts = try migrateUserData()
            } catch let error as SplitMigrationError {
                if case .localCopyIncomplete = error { try? mark(.copyingLocal) }
                throw error
            }
            try reach(.userDataSaved)
            try mark(.verifying)
            try reach(.markedVerifying)
        }
        if state.phase == .verifying {
            try verify()
            try reach(.verified)
            state.fresh = false
            try mark(.splitComplete)
            try? FileManager.default.removeItem(at: layout.work)
        }
        return try Persistence.openSplitStores(layout: layout)
    }

    // MARK: copyingLocal

    /// Builds `Local.store` from a copy of the old store and returns how many of
    /// the listener's own rows the old store held, by entity.
    private func buildLocal() throws -> [String: Int] {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: layout.work)
        try fileManager.createDirectory(at: layout.work, withIntermediateDirectories: true)

        let snapshot = layout.work.appendingPathComponent("snapshot.store")
        try SQLiteFiles.snapshot(of: layout.legacy, to: snapshot, scratch: layout.work.appendingPathComponent("scratch"))

        let building = layout.work.appendingPathComponent("Local.building.store")
        try fileManager.copyItem(at: snapshot, to: building)
        let scratchUserData = layout.work.appendingPathComponent("scratch-UserData.store")

        // Bring the copy to the current shape. Both stores are opened together, so
        // that the schema is never one that leaves a model out.
        try autoreleasepool { _ = try Persistence.makeSplitContainer(userData: scratchUserData, local: building) }
        try SQLiteFiles.checkpoint(building)
        try SQLiteFiles.empty(Self.userTables, in: building)

        // Placeholders that share a key are given codes of their own now, in the
        // cache, so that identities are unique before any row is written against
        // them.
        try autoreleasepool {
            let container = try Persistence.makeSplitContainer(userData: scratchUserData, local: building)
            let context = ModelContext(container)
            RecordingStore(context: context).repairIdentities()
            try context.save()
        }
        try SQLiteFiles.checkpoint(building)

        // Every cache table has as many rows as it had.
        for table in Self.localTables {
            let before = SQLiteFiles.count(table, in: snapshot)
            let after = SQLiteFiles.count(table, in: building)
            guard before == after else {
                throw SplitMigrationError.localCopyIncomplete("\(table): \(before ?? -1) -> \(after ?? -1)")
            }
        }
        for table in Self.userTables where (SQLiteFiles.count(table, in: building) ?? 0) != 0 {
            throw SplitMigrationError.localCopyIncomplete("\(table) still holds rows")
        }

        Persistence.destroyCache(at: layout.local, layout: layout)
        try fileManager.moveItem(at: building, to: layout.local)

        var counts: [String: Int] = [:]
        for name in IndigoSchemaV6.userDataModelNames {
            counts[name] = SQLiteFiles.count("Z" + name.uppercased(), in: snapshot) ?? 0
        }
        return counts
    }

    // MARK: migratingUserData

    /// What the old store held, rewritten, from a fresh snapshot of it.
    private func readOld() throws -> LegacyUserData {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.work, withIntermediateDirectories: true)
        let snapshot = layout.work.appendingPathComponent("snapshot-user.store")
        try SQLiteFiles.snapshot(of: layout.legacy, to: snapshot, scratch: layout.work.appendingPathComponent("scratch"))
        let reader = layout.work.appendingPathComponent("reader.store")
        try? fileManager.removeItem(at: reader)
        try fileManager.copyItem(at: snapshot, to: reader)
        return try LegacyReader.read(copy: reader)
    }

    private func migrated(_ old: LegacyUserData, in context: ModelContext) -> MigratedUserData {
        let recordings = RecordingStore(context: context)
        return UserDataTransform.transform(
            old,
            recording: { (try? recordings.recording(id: $0)) ?? nil },
            snapshot: { CrateSnapshot.capture($0, context: context) })
    }

    /// Writes the listener's rows into `UserData` in one save, and returns how
    /// many of each there are.
    private func migrateUserData() throws -> [String: Int] {
        let old = try readOld()
        let container = try Persistence.openSplitStores(layout: layout)
        let context = ModelContext(container)

        // The cache has to be the one that was built. If it is not -- it was
        // thrown away and made empty because it would not open -- the rewrite
        // would find no recordings and keep every old key.
        let expectedRecordings = SQLiteFiles.count("ZRECORDING", in: layout.work.appendingPathComponent("snapshot-user.store"))
        let haveRecordings = try context.fetchCount(FetchDescriptor<Recording>())
        guard expectedRecordings == haveRecordings else {
            throw SplitMigrationError.localCopyIncomplete("recordings \(expectedRecordings ?? -1) vs \(haveRecordings)")
        }

        let result = migrated(old, in: context)
        let expected = [
            "CrateItem": result.crate.count, "ListeningEvent": result.events.count,
            "DigVisit": result.visits.count, "DigStep": result.steps.count
        ]
        let present = [
            "CrateItem": try context.fetchCount(FetchDescriptor<CrateItem>()),
            "ListeningEvent": try context.fetchCount(FetchDescriptor<ListeningEvent>()),
            "DigVisit": try context.fetchCount(FetchDescriptor<DigVisit>()),
            "DigStep": try context.fetchCount(FetchDescriptor<DigStep>())
        ]

        if present.values.contains(where: { $0 > 0 }) {
            // A save that finished before the state could say so holds exactly
            // what this would write. Anything else is not this move's.
            if present == expected { return expected }
            // Nothing is exposed until the move is complete, so what is here is
            // an earlier attempt's and can be replaced.
            try context.delete(model: CrateItem.self)
            try context.delete(model: ListeningEvent.self)
            try context.delete(model: DigVisit.self)
            try context.delete(model: DigStep.self)
            try context.delete(model: DigCounter.self)
            try context.save()
        }

        for value in result.crate { context.insert(CrateItem(restoring: value)) }
        for value in result.events { context.insert(ListeningEvent(restoring: value)) }
        for value in result.visits { context.insert(DigVisit(restoring: value)) }
        for value in result.steps { context.insert(DigStep(restoring: value)) }
        try context.save()
        // The counts the old store held become the base of each counter, as
        // they do for any store from before components.
        try CounterBaseline.create(in: context)
        return expected
    }

    // MARK: verifying

    /// Checks what is in `UserData` against what the old store held, row by row.
    private func verify() throws {
        let old = try readOld()
        let container = try Persistence.openSplitStores(layout: layout)
        let context = ModelContext(container)
        let expected = migrated(old, in: context)
        var problems: [String] = []

        func compare<V: Equatable>(_ name: String, _ want: [V], _ have: [V], key: (V) -> String) {
            let wanted = Dictionary(want.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
            let had = Dictionary(have.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
            if want.count != have.count { problems.append("\(name): \(want.count) expected, \(have.count) present") }
            if have.count != had.count { problems.append("\(name): \(have.count - had.count) rows share a key") }
            let differ = wanted.filter { had[$0.key] != $0.value }.count
            if differ > 0 { problems.append("\(name): \(differ) rows differ from what was moved") }
        }
        compare("CrateItem", expected.crate,
                (try context.fetch(FetchDescriptor<CrateItem>())).map(CrateValue.init), key: { $0.id.uuidString })
        compare("ListeningEvent", expected.events,
                (try context.fetch(FetchDescriptor<ListeningEvent>())).map(EventValue.init), key: { $0.id.uuidString })
        compare("DigVisit", expected.visits,
                (try context.fetch(FetchDescriptor<DigVisit>())).map(VisitValue.init), key: { $0.nodeID })
        compare("DigStep", expected.steps,
                (try context.fetch(FetchDescriptor<DigStep>())).map(StepValue.init), key: { $0.identity })

        // What was counted is still counted: nothing was lost in a merge.
        let visitsBefore = old.visits.reduce(0) { $0 + $1.value.visits }
        let stepsBefore = old.steps.reduce(0) { $0 + $1.count }
        let secondsBefore = old.events.reduce(0.0) { $0 + $1.value.seconds }
        if expected.visits.reduce(0, { $0 + $1.visits }) != visitsBefore { problems.append("visit counts changed") }
        if expected.steps.reduce(0, { $0 + $1.count }) != stepsBefore { problems.append("step counts changed") }
        if expected.events.reduce(0.0, { $0 + $1.seconds }) != secondsBefore { problems.append("listening time changed") }

        // Nothing in the new store names a local id, and every identity is one
        // recording's.
        if !RecordingStore(context: context).identityCollisions().isEmpty { problems.append("recording identities collide") }
        // And no row disagrees with itself: the fields stored beside the parts
        // they are made of still match them.
        for violation in UserDataInvariants.violations(in: context).prefix(5) { problems.append("\(violation)") }
        if UserDataDedupe(context: context).hasDuplicates() { problems.append("duplicate rows remain") }

        if !problems.isEmpty { throw SplitMigrationError.verificationFailed(problems) }
    }
}
