//
//  CloudKitSeedRunner.swift
//  Indigo
//
//  Development builds only. Step 10 of the iCloud plan: the one run that writes
//  a fully populated seed to CloudKit's *development* environment, reads it back
//  with `CKDatabase`, and says exactly what CloudKit made of it.
//
//  It is asked for by name (`-INDIGO_SEED_CLOUDKIT_DEV`) and never reached by a
//  launch without it. It runs before the app's own container exists, so the
//  listener's stores are not opened; the seed lives in a store of its own, which
//  `CloudKitSeedGuard` refuses to let be any file of the layout.
//
//  What it will not do: run against anything but development (the signed
//  entitlement is read, not the build configuration), touch a record that is not
//  one of its own rows, or leave its rows behind.
//

#if DEBUG

import CloudKit
import CoreData
import Foundation
import Security
import SwiftData

@MainActor
enum CloudKitSeedRunner {
    static let containerID = "iCloud.com.oblaststudio.Indigo"
    /// Where Core Data's mirroring puts a private database's records.
    static let zoneID = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)

    private static var lines: [String] = []

    private static func say(_ line: String) {
        print(line)
        lines.append(line)
    }

    /// Runs the whole experiment and ends the process: 0 if every check held.
    static func runAndExit() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            let code = await run()
            let report = Persistence.layout.directory.appendingPathComponent("cloudkit-seed-report.txt")
            try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
            exit(code)
        }
        dispatchMain()
    }

    // MARK: - The run

    private static func run() async -> Int32 {
        let layout = Persistence.layout
        let directory = layout.directory.appendingPathComponent("CloudKitSeed", isDirectory: true)
        let store = directory.appendingPathComponent("CloudKitSchemaSeed.store")

        // 1. The refusals. Every one is printed.
        var refusals = CloudKitSeedGuard.refusals(arguments: ProcessInfo.processInfo.arguments, store: store, layout: layout)
        let entitlements = signedEntitlements()
        say("entitlement icloud-container-identifiers: \(entitlements.containers)")
        say("entitlement icloud-container-environment: \(entitlements.environment ?? "absent (a debug build uses Development)")")
        if !entitlements.containers.contains(containerID) { refusals.append("the app is not signed for \(containerID)") }
        if let environment = entitlements.environment, environment != "Development" {
            refusals.append("the signed environment is \(environment), not Development")
        }
        guard refusals.isEmpty else {
            for reason in refusals { say("REFUSED: \(reason)") }
            return 2
        }

        let container = CKContainer(identifier: containerID)
        let database = container.privateCloudDatabase
        do {
            let status = try await container.accountStatus()
            say("iCloud account status: \(status.rawValue) (1 = available)")
            guard status == .available else { say("REFUSED: no iCloud account is available to this app"); return 2 }
        } catch {
            say("REFUSED: account status failed: \(error)"); return 2
        }

        let seed = CloudKitSchemaSeed.make()
        let seedIDs = Set(
            seed.crate.map { $0.id.uuidString } + seed.events.map { $0.id.uuidString }
                + seed.visits.compactMap { $0.id?.uuidString } + seed.steps.compactMap { $0.id?.uuidString })

        // 2. The zone must hold nothing that is not ours, or we stop before writing.
        do {
            let existing = try await fetchAll(database)
            let foreign = existing.filter { !seedIDs.contains(($0["CD_id"] as? String) ?? "") }
            say("records already in the zone: \(existing.count) (\(foreign.count) not seed rows)")
            guard foreign.isEmpty else { say("REFUSED: the zone holds records that are not seed rows; nothing was written"); return 2 }
            if !existing.isEmpty {
                let cleared = (try? await deleteSeedRecords(database, ids: seedIDs)) ?? 0
                say("seed rows left by an earlier run, deleted first: \(cleared)")
            }
        } catch let error as CKError where error.code == .zoneNotFound {
            say("zone does not exist yet")
        } catch {
            say("REFUSED: could not read the zone first: \(error)"); return 2
        }

        // 3. Write the seed to a store of its own, mirrored to Development.
        try? FileManager.default.removeItem(at: directory)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            say("could not make \(directory.path): \(error)"); return 1
        }
        let events = ExportLog()
        let observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated { events.record(event) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        var wroteRecords = false
        var failures: [String] = []
        do {
            let schema = Schema([CrateItem.self, ListeningEvent.self, DigVisit.self, DigStep.self])
            let configuration = ModelConfiguration(
                "CloudKitSchemaSeed", schema: schema, url: store, cloudKitDatabase: .private(containerID))
            let swiftData = try ModelContainer(for: schema, configurations: configuration)
            let context = swiftData.mainContext
            for value in seed.crate { context.insert(CrateItem(restoring: value)) }
            for value in seed.events { context.insert(ListeningEvent(restoring: value)) }
            for value in seed.visits { context.insert(DigVisit(restoring: value)) }
            for value in seed.steps { context.insert(DigStep(restoring: value)) }
            try context.save()
            say("seed saved: \(seed.crate.count) crate, \(seed.events.count) events, \(seed.visits.count) visits, \(seed.steps.count) steps")

            // 4. Wait for the export, then for the records to be readable.
            let expected = seed.crate.count + seed.events.count + seed.visits.count + seed.steps.count
            var records: [CKRecord] = []
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(5))
                if let found = try? await fetchAll(database) { records = found.filter { seedIDs.contains(($0["CD_id"] as? String) ?? "") } }
                if records.count >= expected { break }
            }
            wroteRecords = !records.isEmpty
            say("export events: \(events.summary)")
            say("seed records read back: \(records.count) of \(expected)")
            if records.count < expected { failures.append("only \(records.count) of \(expected) records arrived") }

            // 5. The schema, field by field.
            failures += compareSchema(records)
            // 6. The values, scalar for scalar.
            failures += compareValues(records, sent: seed)

            // 7. Delete what we wrote -- only rows whose id is a seed id.
            let removed = try await deleteSeedRecords(database, ids: seedIDs)
            say("seed records deleted from CloudKit: \(removed)")
            let left = (try? await fetchAll(database))?.filter { seedIDs.contains(($0["CD_id"] as? String) ?? "") }.count ?? -1
            say("seed records still present after delete: \(left)")
            if left != 0 { failures.append("\(left) seed records remain") }
        } catch {
            failures.append("run failed: \(error)")
            if wroteRecords { _ = try? await deleteSeedRecords(database, ids: seedIDs) }
        }
        try? FileManager.default.removeItem(at: directory)

        say(failures.isEmpty ? "RESULT: every check held" : "RESULT: \(failures.count) problem(s)")
        for failure in failures { say("  - \(failure)") }
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - CloudKit reads and deletes

    /// Every record in the zone, through the zone's change feed -- which needs no
    /// queryable index, so it works on a schema that does not have one yet.
    static func fetchAll(_ database: CKDatabase) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (_, result) in changes.modificationResultsByID { records.append(try result.get().record) }
            token = changes.changeToken
            more = changes.moreComing
        }
        return records
    }

    private static func deleteSeedRecords(_ database: CKDatabase, ids: Set<String>) async throws -> Int {
        let ours = try await fetchAll(database).filter { ids.contains(($0["CD_id"] as? String) ?? "") }
        guard !ours.isEmpty else { return 0 }
        let result = try await database.modifyRecords(saving: [], deleting: ours.map(\.recordID))
        return result.deleteResults.values.filter { (try? $0.get()) != nil }.count
    }

    // MARK: - The schema

    /// Entity name from a Core Data mirrored record type, `CD_CrateItem` -> `CrateItem`.
    private static func entity(of record: CKRecord) -> String { String(record.recordType.dropFirst(3)) }

    private static func compareSchema(_ records: [CKRecord]) -> [String] {
        var problems: [String] = []
        var observed: [String: [String: Set<String>]] = [:]
        var systemFields: Set<String> = []
        for record in records {
            for key in record.allKeys() {
                guard let value = record[key] else { continue }
                observed[entity(of: record), default: [:]][key, default: []]
                    .insert(CloudKitSchemaManifest.classify(value))
            }
        }
        say("")
        say("record types seen: \(Set(records.map(\.recordType)).sorted())")
        var matched = 0
        var total = 0
        for (entity, fields) in CloudKitSchemaManifest.expected.sorted(by: { $0.key < $1.key }) {
            let seen = observed[entity] ?? [:]
            say("\(entity): \(seen.count) fields in CloudKit, \(fields.count) expected")
            if seen.isEmpty { problems.append("record type CD_\(entity) never appeared") }
            for (attribute, type) in fields.sorted(by: { $0.key < $1.key }) {
                total += 1
                let name = CloudKitSchemaManifest.fieldName(attribute)
                guard let actual = seen[name] else {
                    problems.append("\(entity).\(name) is missing"); say("  MISSING \(name)"); continue
                }
                if actual == [type] { matched += 1; say("  ok      \(name): \(type)") }
                else { problems.append("\(entity).\(name) is \(actual.sorted()) not \(type)"); say("  DIFFERS \(name): \(actual.sorted()) expected \(type)") }
            }
            let known = Set(fields.keys.map(CloudKitSchemaManifest.fieldName))
            for extra in seen.keys.sorted() where !known.contains(extra) {
                systemFields.insert(extra)
                say("  extra   \(extra): \(seen[extra]!.sorted())")
            }
        }
        say("fields present with the expected type: \(matched) of \(total)")
        if !systemFields.subtracting(["CD_entityName"]).isEmpty {
            problems.append("fields nobody chose: \(systemFields.subtracting(["CD_entityName"]).sorted())")
        }
        return problems
    }

    // MARK: - The values

    private static func compareValues(_ records: [CKRecord], sent: CloudKitSchemaSeed) -> [String] {
        var problems: [String] = []
        func rows(_ entity: String) -> [CKRecord] { records.filter { $0.recordType == "CD_\(entity)" } }
        func string(_ r: CKRecord, _ f: String) -> String? { r["CD_\(f)"] as? String }

        var received = CloudKitSchemaSeed(crate: [], events: [], visits: [], steps: [])
        for r in rows("CrateItem") {
            guard let id = string(r, "id").flatMap(UUID.init) else { continue }
            var v = CrateValue(id: id, kindRaw: string(r, "kindRaw") ?? "", addedAt: (r["CD_addedAt"] as? Date) ?? .distantPast)
            v.matchKey = string(r, "matchKey") ?? ""; v.title = string(r, "title"); v.showID = string(r, "showID")
            v.genreTagsRaw = string(r, "genreTagsRaw") ?? ""
            received.crate.append(v)
        }
        for r in rows("ListeningEvent") {
            guard let id = string(r, "id").flatMap(UUID.init) else { continue }
            var tags: [String] = []
            if let data = r["CD_tags"] as? Data {
                let classes: [AnyClass] = [NSArray.self, NSString.self, NSData.self, NSDictionary.self, NSNumber.self]
                let object = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data)
                if let array = object as? [Any] {
                    say("tags are an NSKeyedArchiver archive in BYTES; elements: \(array.map { String(describing: type(of: $0)) })")
                    tags = array.compactMap { ($0 as? String) ?? ($0 as? Data).flatMap { String(data: $0, encoding: .utf8) } }
                } else if let inner = object as? Data {
                    // SwiftData archives the array's own encoding: look inside.
                    if let decoded = try? JSONDecoder().decode([String].self, from: inner) {
                        tags = decoded; say("tags are an NSKeyedArchiver archive of JSON in BYTES")
                    } else if let decoded = try? PropertyListDecoder().decode([String].self, from: inner) {
                        tags = decoded; say("tags are an NSKeyedArchiver archive of a property list in BYTES")
                    } else {
                        say("tags BYTES wrap data this does not know: \(inner.prefix(24).map { String($0, radix: 16) })")
                    }
                } else {
                    say("tags BYTES unarchive to \(object.map { String(describing: type(of: $0)) } ?? "nothing"): \(data.prefix(16).map { String($0, radix: 16) })")
                }
            }
            received.events.append(EventValue(
                id: id, nodeID: string(r, "nodeID") ?? "", nodeKey: string(r, "nodeKey") ?? "", tags: tags))
        }
        for r in rows("DigVisit") {
            received.visits.append(VisitValue(
                id: string(r, "id").flatMap(UUID.init), nodeID: string(r, "nodeID") ?? "", visits: 0,
                firstVisitedAt: .distantPast, lastVisitedAt: .distantPast))
        }
        for r in rows("DigStep") {
            received.steps.append(StepValue(
                id: string(r, "id").flatMap(UUID.init), identity: string(r, "identity") ?? "", count: 0, lastAt: .distantPast))
        }

        say("")
        let differences = UnicodeFidelity.differences(sent: sent, received: received)
        let key = CloudKitSchemaSeed.separatedKey
        let keyBack = received.crate.first { $0.matchKey.unicodeScalars.contains("\u{1F}") }?.matchKey
        say("U+001F matchKey sent:     \(Array(key.unicodeScalars).map { String($0.value, radix: 16) })")
        say("U+001F matchKey received: \(keyBack.map { Array($0.unicodeScalars).map { String($0.value, radix: 16) } } ?? ["none"])")
        say("string fields compared scalar-for-scalar: \(differences.isEmpty ? "all identical" : "\(differences.count) differ")")
        problems += differences
        if keyBack != key { problems.append("the U+001F matchKey did not come back identical") }

        // Numbers, dates and UUIDs, on the row that fills every field.
        let full = sent.crate[0], event = sent.events[0], visit = sent.visits[0], step = sent.steps[0]
        func number(_ r: CKRecord?, _ f: String) -> Double? { (r?["CD_\(f)"] as? NSNumber)?.doubleValue }
        func check(_ name: String, _ ok: Bool) { say("  \(ok ? "ok" : "WRONG") \(name)"); if !ok { problems.append("\(name) did not round-trip") } }
        let crateRow = rows("CrateItem").first { string($0, "id") == full.id.uuidString }
        let eventRow = rows("ListeningEvent").first { string($0, "id") == event.id.uuidString }
        let visitRow = rows("DigVisit").first
        let stepRow = rows("DigStep").first
        say("typed values:")
        check("UUID is its uuidString (CrateItem.id)", string(crateRow ?? CKRecord(recordType: "x"), "id") == full.id.uuidString)
        check("Date is the same instant (CrateItem.addedAt)", (crateRow?["CD_addedAt"] as? Date) == full.addedAt)
        check("Bool true is 1 (CrateItem.isLiveStream)", number(crateRow, "isLiveStream") == 1)
        check("Double (CrateItem.broadcastOffsetSeconds)", number(crateRow, "broadcastOffsetSeconds") == full.broadcastOffsetSeconds)
        check("Int (ListeningEvent.discogsID)", number(eventRow, "discogsID") == Double(event.discogsID ?? -1))
        check("Double (ListeningEvent.seconds)", number(eventRow, "seconds") == event.seconds)
        check("Double (ListeningEvent.completion)", number(eventRow, "completion") == event.completion)
        check("Int (DigVisit.visits)", number(visitRow, "visits") == Double(visit.visits))
        check("Date (DigVisit.lastVisitedAt)", (visitRow?["CD_lastVisitedAt"] as? Date) == visit.lastVisitedAt)
        check("Int (DigStep.count)", number(stepRow, "count") == Double(step.count))
        check("Date (DigStep.lastAt)", (stepRow?["CD_lastAt"] as? Date) == step.lastAt)
        check("tags array", received.events.first?.tags == event.tags)
        return problems
    }

    // MARK: - What the process is signed for

    static func signedEntitlements() -> (containers: [String], environment: String?) {
        guard let task = SecTaskCreateFromSelf(nil) else { return ([], nil) }
        func value(_ key: String) -> Any? { SecTaskCopyValueForEntitlement(task, key as CFString, nil) }
        let containers = (value("com.apple.developer.icloud-container-identifiers") as? [String]) ?? []
        let raw = value("com.apple.developer.icloud-container-environment")
        let environment = (raw as? String) ?? (raw as? [String])?.joined(separator: ",")
        return (containers, environment)
    }
}

/// What the mirroring reported while the seed went out.
@MainActor
final class ExportLog {
    private var exports = 0, imports = 0, setups = 0, failed: [String] = []

    func record(_ event: NSPersistentCloudKitContainer.Event) {
        guard event.endDate != nil else { return }
        switch event.type {
        case .export: exports += 1
        case .import: imports += 1
        case .setup: setups += 1
        @unknown default: break
        }
        if !event.succeeded { failed.append("\(event.type.rawValue): \(event.error.map { "\($0)" } ?? "unknown")") }
    }

    var summary: String { "setup \(setups), export \(exports), import \(imports), failed \(failed)" }
}

#endif
