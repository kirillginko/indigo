//
//  SyncRehearsalRunner.swift
//  Indigo
//
//  Development builds only. The rehearsal before `UserData` is first mirrored
//  for real. There is no data transformation to rehearse this time; what is
//  being proved is that turning mirroring on for an already populated store
//
//    - does not change, drop or duplicate a row just by opening it,
//    - uploads every row of every entity, once each, and
//    - does not change anything on a save and a reopen, nor when the records
//      come back from CloudKit.
//
//  It runs on a *copy* of the store (`Scripts/sync-rehearsal-prepare.sh` makes
//  it), against CloudKit's development environment, which must hold nothing
//  yet. Because the copy's rows carry the real rows' ids, its upload is
//  removed afterwards by deleting the whole zone, and the zone is checked to be
//  gone, so the real first sync starts from nothing. The listener's own stores
//  are not opened.
//
//  The report names counts, ids and digests; nothing the listener made.
//

#if DEBUG

import CloudKit
import CoreData
import Foundation
import SwiftData

@MainActor
enum SyncRehearsalRunner {
    static let argument = "-INDIGO_REHEARSE_USERDATA_SYNC"

    private static var lines: [String] = []
    private static func say(_ line: String) { print(line); lines.append(line) }

    static func runAndExit() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            let code = await run()
            let report = Persistence.layout.directory.appendingPathComponent("sync-rehearsal-report.txt")
            try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
            exit(code)
        }
        dispatchMain()
    }

    // MARK: - What a store holds

    struct Snapshot: Equatable {
        var ids: [String: [String]]   // entity -> sorted ids
        var counts: [String: Int] { ids.mapValues(\.count) }
        var digests: [String: String] { ids.mapValues(RowIDs.digest) }
    }

    static let entities = ["CrateItem", "ListeningEvent", "DigVisit", "DigStep"]

    private static func snapshot(_ container: ModelContainer) throws -> Snapshot {
        let context = ModelContext(container)
        func ids<T: PersistentModel>(_ type: T.Type, _ id: (T) -> UUID?) throws -> [String] {
            try context.fetch(FetchDescriptor<T>()).compactMap { id($0)?.uuidString }.sorted()
        }
        return Snapshot(ids: [
            "CrateItem": try ids(CrateItem.self) { $0.id },
            "ListeningEvent": try ids(ListeningEvent.self) { $0.id },
            "DigVisit": try ids(DigVisit.self) { $0.id },
            "DigStep": try ids(DigStep.self) { $0.id }
        ])
    }

    private static func describe(_ label: String, _ snap: Snapshot) {
        say("\(label):")
        for entity in entities {
            let ids = snap.ids[entity] ?? []
            let sample = ids.isEmpty ? "-" : "\(ids[0]) \(ids[ids.count / 2]) \(ids[ids.count - 1])"
            say("  \(entity): \(ids.count) rows, \(Set(ids).count) distinct, digest \(snap.digests[entity]!.prefix(16)), first/middle/last \(sample)")
        }
    }

    private static func compare(_ label: String, _ a: Snapshot, _ b: Snapshot) -> [String] {
        var problems: [String] = []
        for entity in entities where a.ids[entity] != b.ids[entity] {
            problems.append("\(label): \(entity) changed (\(a.counts[entity] ?? 0) -> \(b.counts[entity] ?? 0) rows)")
        }
        say("\(label): \(problems.isEmpty ? "logical contents identical" : "CHANGED")")
        return problems
    }

    private static func open(_ copy: URL, sync: UserDataSync) throws -> ModelContainer {
        try Persistence.makeSplitContainer(userData: copy, local: nil, sync: sync)
    }

    // MARK: - CloudKit counts

    private static func cloudCounts(_ database: CKDatabase) async throws -> (counts: [String: Int], ids: [String: [String]]) {
        let records = try await CloudKitSeedRunner.fetchAll(database)
        var ids: [String: [String]] = [:]
        for record in records { ids[String(record.recordType.dropFirst(3)), default: []].append((record["CD_id"] as? String) ?? "?") }
        return (Dictionary(grouping: records, by: \.recordType).mapValues(\.count), ids)
    }

    // MARK: - The run

    private static func run() async -> Int32 {
        let layout = Persistence.layout
        let directory = layout.directory.appendingPathComponent("SyncRehearsal", isDirectory: true)
        let copy = directory.appendingPathComponent("UserDataSyncRehearsal.store")

        var refusals: [String] = []
        if !ProcessInfo.processInfo.arguments.contains(argument) { refusals.append("not asked for by name") }
        if Persistence.isRunningTests { refusals.append("this is a test process") }
        for file in [layout.userData, layout.local, layout.legacy, layout.archive].flatMap(layout.files(of:))
        where file.standardizedFileURL.path == copy.standardizedFileURL.path {
            refusals.append("the copy is \(file.lastPathComponent), which is the listener's")
        }
        let entitlements = CloudKitSeedRunner.signedEntitlements()
        say("entitlement icloud-container-environment: \(entitlements.environment ?? "absent (a debug build uses Development)")")
        if !entitlements.containers.contains(CloudKitSeedRunner.containerID) { refusals.append("the app is not signed for the container") }
        if let environment = entitlements.environment, environment != "Development" {
            refusals.append("the signed environment is \(environment), not Development")
        }
        if !FileManager.default.fileExists(atPath: copy.path) { refusals.append("no copy at \(copy.path); run Scripts/sync-rehearsal-prepare.sh") }
        guard refusals.isEmpty else { for r in refusals { say("REFUSED: \(r)") }; return 2 }

        let container = CKContainer(identifier: CloudKitSeedRunner.containerID)
        let database = container.privateCloudDatabase
        do {
            guard try await container.accountStatus() == .available else { say("REFUSED: no iCloud account"); return 2 }
            let existing = try await CloudKitSeedRunner.fetchAll(database)
            guard existing.isEmpty else { say("REFUSED: the development zone already holds \(existing.count) records; nothing was written"); return 2 }
            say("development zone: empty")
        } catch let error as CKError where error.code == .zoneNotFound {
            say("development zone: does not exist yet")
        } catch { say("REFUSED: could not read the zone: \(error)"); return 2 }

        var problems: [String] = []
        var uploaded = false
        do {
            // 1. The copy as it is, opened without mirroring.
            let before = try autoreleasepool { try snapshot(try open(copy, sync: .off)) }
            describe("before mirroring (copy, opened unmirrored)", before)
            for entity in entities where before.ids[entity]!.isEmpty { problems.append("the copy has no \(entity) rows; this rehearses nothing") }
            if before.ids.values.contains(where: { Set($0).count != $0.count }) { problems.append("the copy already holds a repeated id") }

            // 2. Open it mirroring. Nothing about the rows may change by opening.
            let log = ExportLog()
            let observer = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
            ) { note in
                guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
                MainActor.assumeIsolated { log.record(event) }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            var synced: ModelContainer? = try open(copy, sync: .privateDatabase)
            uploaded = true
            let afterInit = try snapshot(synced!)
            problems += compare("right after mirroring was switched on", before, afterInit)

            // 3. Wait until CloudKit holds every row, each once.
            let deadline = Date().addingTimeInterval(900)
            var settled = false
            var cloud: (counts: [String: Int], ids: [String: [String]]) = ([:], [:])
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(10))
                if let found = try? await cloudCounts(database) { cloud = found }
                let have = entities.map { cloud.counts["CD_\($0)"] ?? 0 }
                say("  waiting: CloudKit holds \(zip(entities, have).map { "\($0) \($1)" }.joined(separator: ", ")); \(log.summary)")
                if entities.allSatisfy({ (cloud.counts["CD_\($0)"] ?? 0) == before.ids[$0]!.count }) { settled = true; break }
            }
            if !settled { problems.append("CloudKit did not reach the local counts in time") }

            // 4. CloudKit against the store, entity by entity.
            say("CloudKit against the store:")
            for entity in entities {
                let theirs = cloud.ids[entity] ?? []
                let ours = before.ids[entity]!
                let same = theirs.sorted() == ours
                say("  CD_\(entity): CloudKit \(theirs.count) records, \(Set(theirs).count) distinct ids; store \(ours.count); ids \(same ? "identical" : "DIFFER")")
                if !same { problems.append("CD_\(entity) in CloudKit does not match the store") }
            }
            let strangers = cloud.counts.keys.filter { !entities.map { "CD_\($0)" }.contains($0) }
            if !strangers.isEmpty { say("  other record types in the zone: \(strangers.sorted().map { "\($0) \(cloud.counts[$0]!)" })") }

            // 5. A save, then close and reopen, then give any import time to arrive.
            try synced!.mainContext.save()
            problems += compare("after export and a save", before, try snapshot(synced!))
            synced = nil
            try? await Task.sleep(for: .seconds(5))
            let reopened = try open(copy, sync: .privateDatabase)
            problems += compare("immediately after reopening mirrored", before, try snapshot(reopened))
            try? await Task.sleep(for: .seconds(45))
            problems += compare("45s after reopening, once any import has arrived", before, try snapshot(reopened))
            say("mirroring events: \(log.summary)")
            let after = try await cloudCounts(database)
            for entity in entities where (after.counts["CD_\(entity)"] ?? 0) != before.ids[entity]!.count {
                problems.append("CD_\(entity) in CloudKit changed to \(after.counts["CD_\(entity)"] ?? 0) records")
            }
        } catch {
            problems.append("the rehearsal failed: \(error)")
        }

        // 6. Take it all away again: the whole zone, then the copy.
        if uploaded {
            try? await Task.sleep(for: .seconds(5))
            do {
                _ = try await database.modifyRecordZones(saving: [], deleting: [CloudKitSeedRunner.zoneID])
                try? await Task.sleep(for: .seconds(15))
                do {
                    let left = try await CloudKitSeedRunner.fetchAll(database).count
                    say("zone after deletion still reads: \(left) records")
                    if left != 0 { problems.append("\(left) records remain in the zone") }
                } catch let error as CKError where error.code == .zoneNotFound {
                    say("development zone deleted; it is gone")
                }
            } catch { problems.append("could not delete the zone: \(error)") }
        }
        try? FileManager.default.removeItem(at: directory)

        say(problems.isEmpty ? "RESULT: every check held" : "RESULT: \(problems.count) problem(s)")
        for problem in problems { say("  - \(problem)") }
        return problems.isEmpty ? 0 : 1
    }
}

#endif
