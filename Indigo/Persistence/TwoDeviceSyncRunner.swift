//
//  TwoDeviceSyncRunner.swift
//  Indigo
//
//  Development builds only. Two devices that have never met, in one process:
//  each has a store of its own (new, empty), each mirrors to the same private
//  CloudKit zone as the listener's real store, and each runs the app's real
//  write paths (`CrateService`, `ListeningLog`, `DigHistory`) and its real
//  `HistoryObserver`. They are made to disagree -- at once, and while cut off --
//  and what is judged is whether, once everything has settled, the two stores
//  and CloudKit hold the same rows, with no id repeated, no natural key twice,
//  and every invariant intact.
//
//  The zone holds the listener's real rows, so nothing here may touch one.
//  Every row this makes carries MARKER in its key, and only rows that carry it
//  are ever deleted. The zone itself is never deleted: a store that sees its
//  zone vanish treats it as the listener choosing to erase their iCloud data.
//
//  The report names counts, ids and digests, and pass or fail; nothing the
//  listener made.
//

#if DEBUG

import CloudKit
import CoreData
import Foundation
import SwiftData

@MainActor
enum TwoDeviceSyncRunner {
    static let argument = "-INDIGO_TWO_DEVICE_SYNC_DEV"
    /// Asks for the stage that needs the network cut. It waits for files that
    /// `Scripts/two-device-offline.sh` creates, because the app cannot cut the
    /// network itself.
    static let offlineArgument = "-INDIGO_TWO_DEVICE_OFFLINE"
    static let marker = "indigo-sync-test"
    static let provider = "indigo-sync-test"

    private static var lines: [String] = []
    private static var problems: [String] = []
    private static func say(_ line: String) { print(line); lines.append(line) }
    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        say("  \(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " -- " + detail())")
        if !ok { problems.append(name) }
    }

    static func runAndExit() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            let code = await run()
            let report = Persistence.layout.directory.appendingPathComponent("two-device-report.txt")
            try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
            exit(code)
        }
        dispatchMain()
    }

    // MARK: - A device

    @MainActor
    final class Device {
        let name: String
        let container: ModelContainer
        let context: ModelContext
        private var watcher: Task<Void, Never>?

        init(name: String, directory: URL) throws {
            self.name = name
            container = try Persistence.makeSplitContainer(
                userData: directory.appendingPathComponent("UserDataTwoDevice\(name).store"), local: nil,
                sync: .privateDatabase)
            context = container.mainContext
            context.author = IndigoApp.writerAuthor
            let defaults = UserDefaults(suiteName: "indigo.twodevice.\(name)")!
            defaults.removePersistentDomain(forName: "indigo.twodevice.\(name)")
            let observer = HistoryObserver(context: context, defaults: defaults, ownAuthor: IndigoApp.writerAuthor)
            watcher = Task { @MainActor in
                observer.process()
                for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                    observer.process()
                }
            }
        }

        func stop() { watcher?.cancel(); watcher = nil }

        var crate: CrateService { CrateService(context: context, writable: true) }
        var log: ListeningLog { ListeningLog(context: context, writable: true) }
        var dig: DigHistory { DigHistory(context: context, writable: true) }

        func snapshot() -> SyncRehearsalRunner.Snapshot { (try? SyncRehearsalRunner.snapshot(container)) ?? .init(ids: [:]) }

        func markerRows() -> (crate: [CrateItem], events: [ListeningEvent], visits: [DigVisit], steps: [DigStep]) {
            let m = TwoDeviceSyncRunner.marker
            return (
                ((try? context.fetch(FetchDescriptor<CrateItem>())) ?? []).filter { ($0.providerID ?? "") == TwoDeviceSyncRunner.provider },
                ((try? context.fetch(FetchDescriptor<ListeningEvent>())) ?? []).filter { $0.nodeKey.lowercased().contains(m) },
                ((try? context.fetch(FetchDescriptor<DigVisit>())) ?? []).filter { $0.nodeID.lowercased().contains(m) },
                ((try? context.fetch(FetchDescriptor<DigStep>())) ?? []).filter { $0.identity.lowercased().contains(m) })
        }

        func removeMarkerRows() {
            let rows = markerRows()
            rows.crate.forEach(context.delete); rows.events.forEach(context.delete)
            rows.visits.forEach(context.delete); rows.steps.forEach(context.delete)
            try? context.save()
        }
    }

    // MARK: - Settling

    private static let entities = SyncRehearsalRunner.entities

    /// Waits until both devices and CloudKit hold the same ids, and have for
    /// three looks in a row, ten seconds apart. Returns what it settled on.
    @discardableResult
    private static func settle(
        _ label: String, _ a: Device, _ b: Device, _ database: CKDatabase, within seconds: Double = 420
    ) async -> SyncRehearsalRunner.Snapshot? {
        let deadline = Date().addingTimeInterval(seconds)
        var steady = 0
        var last: SyncRehearsalRunner.Snapshot?
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(10))
            let x = a.snapshot(), y = b.snapshot()
            guard let cloud = try? await SyncRehearsalRunner.cloudCounts(database) else { continue }
            let same = entities.allSatisfy { x.ids[$0] == y.ids[$0] && (cloud.ids[$0] ?? []).sorted() == x.ids[$0] }
            say("  [\(label)] A \(counts(x)) | B \(counts(y)) | CloudKit \(entities.map { "\(cloud.ids[$0]?.count ?? 0)" }.joined(separator: "/")) \(same ? "agree" : "differ")")
            if same, x == last { steady += 1 } else { steady = same ? 1 : 0 }
            last = same ? x : nil
            if steady >= 3 { return x }
        }
        check("\(label): A, B and CloudKit settle on the same rows", false, "did not agree within \(Int(seconds))s")
        return nil
    }

    private static func counts(_ s: SyncRehearsalRunner.Snapshot) -> String { entities.map { "\(s.counts[$0] ?? 0)" }.joined(separator: "/") }

    private static func healthy(_ label: String, _ devices: [Device]) {
        for device in devices {
            let snap = device.snapshot()
            let repeats = snap.ids.filter { Set($0.value).count != $0.value.count }.keys.sorted()
            check("\(label): \(device.name) repeats no id", repeats.isEmpty, "\(repeats)")
            check("\(label): \(device.name) holds no natural key twice", !UserDataDedupe(context: device.context).hasDuplicates())
            let violations = UserDataInvariants.violations(in: device.context)
            check("\(label): \(device.name) passes every invariant", violations.isEmpty, "\(violations.prefix(3))")
        }
    }

    private static func node(_ run: String, _ name: String) -> MusicNode { .artist("\(marker) \(run) \(name)") }

    // MARK: - The run

    private static func run() async -> Int32 {
        let layout = Persistence.layout
        let directory = layout.directory.appendingPathComponent("TwoDeviceSync", isDirectory: true)
        let run = String(UUID().uuidString.prefix(6)).lowercased()

        var refusals: [String] = []
        if !ProcessInfo.processInfo.arguments.contains(argument) { refusals.append("not asked for by name") }
        if Persistence.isRunningTests { refusals.append("this is a test process") }
        let entitlements = CloudKitSeedRunner.signedEntitlements()
        say("entitlement icloud-container-environment: \(entitlements.environment ?? "absent (a debug build uses Development)")")
        if !entitlements.containers.contains(CloudKitSeedRunner.containerID) { refusals.append("the app is not signed for the container") }
        if let environment = entitlements.environment, environment != "Development" {
            refusals.append("the signed environment is \(environment), not Development")
        }
        guard refusals.isEmpty else { for r in refusals { say("REFUSED: \(r)") }; return 2 }

        let container = CKContainer(identifier: CloudKitSeedRunner.containerID)
        let database = container.privateCloudDatabase
        guard (try? await container.accountStatus()) == .available else { say("REFUSED: no iCloud account"); return 2 }
        guard let start = try? await SyncRehearsalRunner.cloudCounts(database), !start.ids.isEmpty else {
            say("REFUSED: the development zone is empty or unreadable; this tests two devices against real data"); return 2
        }
        say("run \(run); the zone holds \(entities.map { "\($0) \(start.ids[$0]?.count ?? 0)" }.joined(separator: ", "))")

        try? FileManager.default.removeItem(at: directory)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { say("no directory: \(error)"); return 1 }
        let log = ExportLog()
        let observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated { log.record(event) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        do {
            // 1. Two new devices import exactly what CloudKit holds.
            say("\n1. two new devices import the zone")
            let a = try Device(name: "A", directory: directory)
            let b = try Device(name: "B", directory: directory)
            defer { a.stop(); b.stop() }
            guard var baseline = await settle("import", a, b, database, within: 900) else { return finish(log) }
            let leftovers = a.markerRows()
            let leftoverCount = leftovers.crate.count + leftovers.events.count + leftovers.visits.count + leftovers.steps.count
            if leftoverCount > 0 {
                say("  \(leftoverCount) marker rows left by an earlier run; removing them first")
                a.removeMarkerRows()
                guard let cleaned = await settle("clear leftovers", a, b, database) else { return finish(log) }
                baseline = cleaned
            }
            check("import: A and B hold what CloudKit holds", true)
            healthy("import", [a, b])
            let base = baseline
            say("  baseline: \(counts(base)); digests \(entities.map { String(base.digests[$0]!.prefix(12)) })")

            // 2. A crate item appears on the other device, and its removal does too.
            say("\n2. crate on A, remove on B")
            let showID = "\(run)-crate"
            a.crate.add(broadcast: showID, providerID: provider, title: "INDIGO-SYNC-TEST \(run)", subtitle: nil,
                        artworkURL: nil, playbackURL: nil, embedProvider: nil)
            if await settle("crated", a, b, database) != nil {
                check("crate: it reached B", b.crate.item(forBroadcast: showID, providerID: provider) != nil)
                if let seen = b.crate.item(forBroadcast: showID, providerID: provider) { b.crate.remove(seen) }
                if await settle("removed", a, b, database) != nil {
                    check("crate: its removal reached A", a.crate.item(forBroadcast: showID, providerID: provider) == nil)
                }
            }

            // 3. Different activity on each; both survive everywhere.
            say("\n3. independent listening")
            let ea = a.log.record(node(run, "listened on A"), action: .played, seconds: 30, completion: 0.2)
            let eb = b.log.record(node(run, "listened on B"), action: .played, seconds: 40, completion: 0.3)
            if await settle("independent", a, b, database) != nil, let ea, let eb {
                for device in [a, b] {
                    let ids = Set(device.snapshot().ids["ListeningEvent"] ?? [])
                    check("listening: \(device.name) holds both events", ids.contains(ea.id.uuidString) && ids.contains(eb.id.uuidString))
                }
            }

            // 4. The same counter from both devices.
            say("\n4. the same counter from both devices")
            let target = node(run, "counter"), origin = node(run, "origin")
            a.dig.record(target, from: origin)
            b.dig.record(target, from: origin)               // both made the row, before either knew
            if await settle("new key, both", a, b, database) != nil {
                for device in [a, b] {
                    let rows = UserDataDedupe(context: device.context).rows(forNodeID: target.id)
                    let steps = UserDataDedupe(context: device.context).rows(forStepIdentity: DigStep.canonicalIdentity(from: origin.id, to: target.id))
                    check("counter: \(device.name) has one visit row, summing both", rows.count == 1 && rows.first?.visits == 2, "rows \(rows.count), visits \(rows.map(\.visits))")
                    check("counter: \(device.name) has one step row, summing both", steps.count == 1 && steps.first?.count == 2, "rows \(steps.count), count \(steps.map(\.count))")
                }
            }
            for _ in 0..<3 { a.dig.record(target, from: origin); b.dig.record(target, from: origin) }  // the same row, both
            if await settle("same row, both", a, b, database) != nil {
                for device in [a, b] {
                    let rows = UserDataDedupe(context: device.context).rows(forNodeID: target.id)
                    let total = rows.map(\.visits).reduce(0, +)
                    say("  MEASURED \(device.name): the same row incremented 3 times on each device: visits \(total) (every increment kept would be 8)")
                    check("counter: \(device.name) still has one visit row", rows.count == 1, "rows \(rows.count)")
                }
            }

            // 5. Replays.
            say("\n5. replays")
            let replayID = UUID()
            func copyOfEvent(_ device: Device) {
                let n = node(run, "replayed")
                device.context.insert(ListeningEvent(restoring: EventValue(
                    id: replayID, at: Date(timeIntervalSince1970: 1_700_000_000), actionRaw: "played", nodeID: n.id,
                    nodeKindRaw: n.kind.rawValue, nodeKey: n.key, title: "INDIGO-SYNC-TEST replay", seconds: 5, completion: 0.1)))
                try? device.context.save()
            }
            copyOfEvent(a); copyOfEvent(b)                                         // the same id on both
            let twin = node(run, "twin")
            let t1 = a.log.record(twin, action: .played, at: Date(timeIntervalSince1970: 1_700_000_100), seconds: 7, completion: 0.2)
            let t2 = b.log.record(twin, action: .played, at: Date(timeIntervalSince1970: 1_700_000_100), seconds: 7, completion: 0.2)
            let crateID = UUID()
            for device in [a, b] {
                device.context.insert(CrateItem(restoring: CrateValue(
                    id: crateID, kindRaw: "broadcast", addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    providerID: provider, showID: "\(run)-replay", showTitle: "INDIGO-SYNC-TEST replay crate")))
                try? device.context.save()
            }
            if await settle("replays", a, b, database) != nil {
                for device in [a, b] {
                    let events = device.snapshot().ids["ListeningEvent"] ?? []
                    check("replay: \(device.name) has the same-id event once", events.filter { $0 == replayID.uuidString }.count == 1)
                    check("replay: \(device.name) keeps identical events with different ids apart",
                          t1 != nil && t2 != nil && events.contains(t1!.id.uuidString) && events.contains(t2!.id.uuidString))
                    let crate = UserDataDedupe(context: device.context).rows(forCrateKey: .broadcast(providerID: provider, showID: "\(run)-replay"))
                    check("replay: \(device.name) has the same crate item once", crate.count == 1, "rows \(crate.count)")
                }
            }
            healthy("after concurrent writes", [a, b])

            // 6. Cut off from each other, then reconnected.
            if ProcessInfo.processInfo.arguments.contains(offlineArgument) {
                await offlineStage(run, a, b, database, directory: directory)
                healthy("after reconnecting", [a, b])
            }

            // 7. Take away only what this run made.
            say("\n7. remove this run's rows")
            a.removeMarkerRows()
            if let end = await settle("cleanup", a, b, database) {
                for entity in entities {
                    check("cleanup: \(entity) is back to the baseline", end.ids[entity] == base.ids[entity],
                          "\(end.counts[entity] ?? 0) rows against \(base.counts[entity] ?? 0)")
                }
                let left = a.markerRows(); let rest = left.crate.count + left.events.count + left.visits.count + left.steps.count
                check("cleanup: no marker row remains", rest == 0, "\(rest)")
            }
            healthy("end", [a, b])
        } catch { problems.append("the run failed: \(error)"); say("the run failed: \(error)") }
        return finish(log)
    }

    private static func finish(_ log: ExportLog) -> Int32 {
        say("\nmirroring events: \(log.summary)")
        say(problems.isEmpty ? "RESULT: every check held" : "RESULT: \(problems.count) problem(s)")
        for problem in problems { say("  - \(problem)") }
        return problems.isEmpty ? 0 : 1
    }

    // MARK: - Offline

    private static func waitFor(file: URL, timeout: Double = 900) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path) { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private static func offlineStage(_ run: String, _ a: Device, _ b: Device, _ database: CKDatabase, directory: URL) async {
        say("\n6. cut off, different changes on each, reconnected")
        let offline = directory.appendingPathComponent("offline.flag"), online = directory.appendingPathComponent("online.flag")
        // Something both already have, to be changed on one and removed on the other.
        let shared = "\(run)-shared"
        a.crate.add(broadcast: shared, providerID: provider, title: "INDIGO-SYNC-TEST shared", subtitle: nil,
                    artworkURL: nil, playbackURL: nil, embedProvider: nil)
        let counter = node(run, "offline counter"), origin = node(run, "offline origin")
        a.dig.record(counter, from: origin)
        guard await settle("before cutting off", a, b, database) != nil else { return }

        say("READY_FOR_OFFLINE")
        guard await waitFor(file: offline) else { check("offline: told to start", false, "no signal"); return }
        try? await Task.sleep(for: .seconds(3))

        if let item = b.crate.item(forBroadcast: shared, providerID: provider) { b.crate.remove(item) }          // B removes it
        a.crate.add(broadcast: "\(run)-offline-a", providerID: provider, title: "INDIGO-SYNC-TEST offline A", subtitle: nil,
                    artworkURL: nil, playbackURL: nil, embedProvider: nil)
        b.crate.add(broadcast: "\(run)-offline-b", providerID: provider, title: "INDIGO-SYNC-TEST offline B", subtitle: nil,
                    artworkURL: nil, playbackURL: nil, embedProvider: nil)
        let ea = a.log.record(node(run, "offline listen A"), action: .played, seconds: 11, completion: 0.4)
        let eb = b.log.record(node(run, "offline listen B"), action: .played, seconds: 12, completion: 0.5)
        for _ in 0..<2 { a.dig.record(counter, from: origin) }
        for _ in 0..<3 { b.dig.record(counter, from: origin) }
        let fresh = node(run, "offline new key")
        a.dig.record(fresh); b.dig.record(fresh); b.dig.record(fresh)
        say("CHANGES_MADE")

        guard await waitFor(file: online) else { check("offline: told to reconnect", false, "no signal"); return }
        if await settle("reconnected", a, b, database, within: 900) != nil {
            for device in [a, b] {
                let events = Set(device.snapshot().ids["ListeningEvent"] ?? [])
                check("offline: \(device.name) holds both offline events", ea != nil && eb != nil && events.contains(ea!.id.uuidString) && events.contains(eb!.id.uuidString))
                check("offline: \(device.name) has both new crate items",
                      device.crate.item(forBroadcast: "\(run)-offline-a", providerID: provider) != nil
                      && device.crate.item(forBroadcast: "\(run)-offline-b", providerID: provider) != nil)
                let sharedNow = device.crate.item(forBroadcast: shared, providerID: provider) != nil
                say("  MEASURED \(device.name): the item B removed while A kept it is \(sharedNow ? "still in the crate" : "gone")")
                let fresh1 = UserDataDedupe(context: device.context).rows(forNodeID: fresh.id)
                check("offline: \(device.name) has one visit row for the key both created", fresh1.count == 1, "rows \(fresh1.count)")
                say("  MEASURED \(device.name): that row's visits \(fresh1.map(\.visits)) (3 if both devices' counts are summed)")
                let existing = UserDataDedupe(context: device.context).rows(forNodeID: counter.id)
                say("  MEASURED \(device.name): the shared counter, +2 on A and +3 on B from 1: visits \(existing.map(\.visits)) (6 if every increment is kept)")
            }
        }
    }
}

#endif
