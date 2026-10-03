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
    /// Runs the import, crate, listening and counter stages, then cleans up.
    static let onlyCounterArgument = "-INDIGO_TWO_DEVICE_ONLY_COUNTER"
    static let marker = "indigo-sync-test"
    static let provider = "indigo-sync-test"

    /// A key folded the way a node's key is -- hyphens become spaces -- still
    /// carries the marker. Matching only the spelled-out form once left a run's
    /// events, visits and steps behind.
    static func isMarker(_ text: String) -> Bool {
        text.lowercased().replacingOccurrences(of: "-", with: " ").contains(marker.replacingOccurrences(of: "-", with: " "))
    }

    private static var lines: [String] = []
    private static var problems: [String] = []
    /// Checks that are expected to fail until a decision is made, kept visible
    /// rather than deleted. One that starts passing is reported, so it is noticed.
    private static var knownFailures: [String] = []
    private static var latencies: [String] = []
    private static func say(_ line: String) { print(line); lines.append(line) }
    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        say("  \(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " -- " + detail())")
        if !ok { problems.append(name) }
    }

    private static func expectFailure(_ name: String, _ ok: Bool, because reason: String) {
        if ok {
            say("  UNEXPECTED PASS \(name) -- the known failure is gone; update the plan")
            problems.append("\(name) passed but is recorded as a known failure")
        } else {
            say("  XFAIL \(name) -- \(reason)")
            knownFailures.append(name)
        }
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
        private let url: URL
        private(set) var container: ModelContainer
        private(set) var context: ModelContext
        private var watcher: Task<Void, Never>?
        /// How many times this device was closed and opened again to take in
        /// what CloudKit holds. Two stores in one process are not both told
        /// about a push, which a real second device always is.
        private(set) var reopened = 0
        /// What this device's observer was told and did: counts only.
        private(set) var notifications = 0
        private(set) var passes = 0
        private(set) var merged = 0
        /// The last passes that looked at anything from another writer.
        private(set) var recentPasses: [String] = []
        private(set) var passKinds: [String: Int] = [:]

        init(name: String, directory: URL) throws {
            self.name = name
            url = directory.appendingPathComponent("UserDataTwoDevice\(name).store")
            container = try Persistence.makeSplitContainer(userData: url, local: nil, sync: .privateDatabase)
            context = container.mainContext
            context.author = IndigoApp.writerAuthor
            start()
        }

        private func start() {
            let defaults = UserDefaults(suiteName: "indigo.twodevice.\(name)")!
            var observer = HistoryObserver(context: context, defaults: defaults, ownAuthor: IndigoApp.writerAuthor)
            observer.onPass = { [weak self] pass in
                guard let self else { return }
                if pass.transactions == -1 { self.passKinds["history fetch failed", default: 0] += 1 }
                else if pass.transactions == 0 { self.passKinds["nothing after the token", default: 0] += 1 }
                else if pass.foreign == 0 { self.passKinds["only own transactions", default: 0] += 1 }
                else {
                    self.passKinds["saw another writer", default: 0] += 1
                    self.recentPasses.append("token \(pass.hadToken) transactions \(pass.transactions) foreign \(pass.foreign) named \(pass.named) rows \(pass.fetched) merged \(pass.merged)")
                    if self.recentPasses.count > 12 { self.recentPasses.removeFirst() }
                }
            }
            // A device that was reopened has a new container and context; the
            // old watcher must not touch the old one, whose container is gone.
            watcher = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                self?.count(observer.process())
                for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                    guard !Task.isCancelled else { return }
                    self?.notifications += 1
                    self?.count(observer.process())
                }
            }
        }

        /// Opens the same store again: a relaunch, which imports at setup.
        ///
        /// Only once the old container is really gone. Core Data allows one
        /// mirroring instance of a store per process; a second one opened while
        /// the first is still registered fails setup (134422, "another instance
        /// of this persistent store actively syncing") and never syncs again.
        /// Returns false, and opens nothing, if the old one will not let go.
        func reopen() async throws -> Bool {
            stop()
            weak var old = container
            context = ModelContext(try Persistence.makeSplitContainer(userData: nil, local: nil))  // a placeholder, in memory
            container = context.container
            for _ in 0..<60 where old != nil {
                try? await Task.sleep(for: .seconds(1))
            }
            guard old == nil else { return false }
            try? await Task.sleep(for: .seconds(3))   // let its activities unregister
            reopened += 1
            container = try Persistence.makeSplitContainer(userData: url, local: nil, sync: .privateDatabase)
            context = container.mainContext
            context.author = IndigoApp.writerAuthor
            start()
            return true
        }

        /// What the store's history holds, as counts: who wrote, and what kind
        /// of change to which entity. No row content.
        func historyReport() -> String {
            let transactions = (try? context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())) ?? []
            var authors: [String: Int] = [:], kinds: [String: Int] = [:], entities: [String: Int] = [:]
            for transaction in transactions {
                authors[transaction.author ?? "nil", default: 0] += 1
                for change in transaction.changes {
                    switch change {
                    case .insert(let insert):
                        kinds["insert", default: 0] += 1
                        entities[insert.changedPersistentIdentifier.entityName, default: 0] += 1
                    case .update: kinds["update", default: 0] += 1
                    case .delete: kinds["delete", default: 0] += 1
                    default: kinds["other", default: 0] += 1
                    }
                }
            }
            return "\(transactions.count) transactions; authors \(authors.sorted { $0.key < $1.key }); changes \(kinds.sorted { $0.key < $1.key }); inserts by entity \(entities.sorted { $0.key < $1.key })"
        }

        /// Whether the history's token filter returns what it should, and
        /// whether a pass that has no stored token finds and merges the
        /// duplicates. The second one merges rows, as the product would.
        func probe() -> String {
            let all = (try? context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())) ?? []
            guard all.count > 4 else { return "history too short to probe" }
            let middle = all.count / 2
            let token = all[middle].token
            var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
            descriptor.predicate = #Predicate { $0.token > token }
            let after = (try? context.fetchHistory(descriptor))?.count ?? -1
            // The observer keeps its token as JSON and reads it back.
            var viaJSON = -2
            if let data = try? JSONEncoder().encode(token), let decoded = try? JSONDecoder().decode(DefaultHistoryToken.self, from: data) {
                var d = HistoryDescriptor<DefaultHistoryTransaction>()
                d.predicate = #Predicate { $0.token > decoded }
                viaJSON = (try? context.fetchHistory(d))?.count ?? -1
            }
            let suite = "indigo.twodevice.\(name).probe"
            let fresh = UserDefaults(suiteName: suite)!
            fresh.removePersistentDomain(forName: suite)
            let report = HistoryObserver(context: context, defaults: fresh, ownAuthor: IndigoApp.writerAuthor).process()
            return "predicate token > transaction \(middle) of \(all.count) returns \(after) (expected \(all.count - middle - 1)); the same token after a JSON round trip returns \(viaJSON); a pass with no stored token merged: visits \(report.visitsMerged), steps \(report.stepsMerged), crate \(report.crateMerged), events \(report.eventsMerged)"
        }

        private func count(_ report: UserDataDedupe.Report) {
            passes += 1
            merged += report.crateMerged + report.eventsMerged + report.visitsMerged + report.stepsMerged
        }

        func stop() { watcher?.cancel(); watcher = nil }

        var crate: CrateService { CrateService(context: context, writable: true) }
        var log: ListeningLog { ListeningLog(context: context, writable: true) }
        // Each stands in for a device of its own, so each writes its own counter
        // components; sharing this Mac's id would make them one writer.
        var dig: DigHistory { DigHistory(context: context, writable: true, deviceID: "harness-\(name)") }

        func snapshot() -> SyncRehearsalRunner.Snapshot { (try? SyncRehearsalRunner.snapshot(container)) ?? .init(ids: [:]) }

        func markerRows() -> (crate: [CrateItem], events: [ListeningEvent], visits: [DigVisit], steps: [DigStep], counters: [DigCounter]) {
            return (
                ((try? context.fetch(FetchDescriptor<CrateItem>())) ?? []).filter { TwoDeviceSyncRunner.isMarker($0.providerID ?? "") },
                ((try? context.fetch(FetchDescriptor<ListeningEvent>())) ?? []).filter { TwoDeviceSyncRunner.isMarker($0.nodeKey) },
                ((try? context.fetch(FetchDescriptor<DigVisit>())) ?? []).filter { TwoDeviceSyncRunner.isMarker($0.nodeID) },
                ((try? context.fetch(FetchDescriptor<DigStep>())) ?? []).filter { TwoDeviceSyncRunner.isMarker($0.identity) },
                ((try? context.fetch(FetchDescriptor<DigCounter>())) ?? []).filter { TwoDeviceSyncRunner.isMarker($0.key) })
        }

        func removeMarkerRows() {
            let rows = markerRows()
            rows.crate.forEach(context.delete); rows.events.forEach(context.delete)
            rows.visits.forEach(context.delete); rows.steps.forEach(context.delete); rows.counters.forEach(context.delete)
            try? context.save()
        }
    }

    // MARK: - Settling

    private static let entities = SyncRehearsalRunner.entities

    /// Waits until both devices and CloudKit hold the same ids, and have for
    /// three looks in a row, ten seconds apart. Returns what it settled on.
    @discardableResult
    private static func settle(
        _ label: String, _ a: Device, _ b: Device, _ database: CKDatabase, within seconds: Double = 1800
    ) async -> SyncRehearsalRunner.Snapshot? {
        // Mirroring promises eventual agreement, not a time. Not agreeing at all
        // is a failure; how long agreeing took is measured and reported.
        let started = Date()
        let deadline = started.addingTimeInterval(seconds)
        var steady = 0
        var behind = 0
        var lastSeen: [String: SyncRehearsalRunner.Snapshot] = [:]
        var last: SyncRehearsalRunner.Snapshot?
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(10))
            let x = a.snapshot(), y = b.snapshot()
            guard let cloud = try? await SyncRehearsalRunner.cloudCounts(database) else { continue }
            let same = entities.allSatisfy { x.ids[$0] == y.ids[$0] && (cloud.ids[$0] ?? []).sorted() == x.ids[$0] }
            say("  [\(label)] A \(counts(x)) | B \(counts(y)) | CloudKit \(entities.map { "\(cloud.ids[$0]?.count ?? 0)" }.joined(separator: "/")) \(same ? "agree" : "differ")")
            if same, x == last { steady += 1 } else { steady = same ? 1 : 0 }
            last = same ? x : nil
            if steady >= 3 {
                let took = Int(Date().timeIntervalSince(started)) - 20   // less the two confirming looks
                latencies.append("\(label) \(took)s")
                return x
            }
            if !same {
                behind += 1
                // Three minutes apart, and never while a device is still moving:
                // a reopen in the middle of an import throws the import away.
                if behind >= 18 {
                    behind = 0
                    for device in [a, b] {
                        let have = device.snapshot()
                        guard have == lastSeen[device.name] else { continue }
                        if entities.contains(where: { (cloud.ids[$0] ?? []).sorted() != have.ids[$0] }) {
                            say("  [\(label)] \(device.name) is behind CloudKit and still; opening it again, as a relaunch would")
                            if (try? await device.reopen()) != true { say("  [\(label)] \(device.name)'s old container would not let go; not reopened") }
                        }
                    }
                }
                lastSeen = [a.name: a.snapshot(), b.name: b.snapshot()]
            } else { behind = 0 }
        }
        check("\(label): A, B and CloudKit eventually agree", false, "still apart after \(Int(seconds))s")
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
            devices = [a, b]
            defer { a.stop(); b.stop() }
            guard var baseline = await settle("import", a, b, database) else { return finish(log) }
            let leftovers = a.markerRows()
            let leftoverCount = leftovers.crate.count + leftovers.events.count + leftovers.visits.count + leftovers.steps.count + leftovers.counters.count
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
            let ea = a.log.record(node(run, "listened on A"), action: .played, seconds: 30, completion: 0.2)?.id
            let eb = b.log.record(node(run, "listened on B"), action: .played, seconds: 40, completion: 0.3)?.id
            if await settle("independent", a, b, database) != nil, let ea, let eb {
                for device in [a, b] {
                    let ids = Set(device.snapshot().ids["ListeningEvent"] ?? [])
                    check("listening: \(device.name) holds both events", ids.contains(ea.uuidString) && ids.contains(eb.uuidString))
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
            for device in [a, b] { say("  history \(device.name): \(device.historyReport())") }
            for device in [a, b] { say("  passes \(device.name): \(device.passKinds.sorted { $0.key < $1.key }) last \(device.recentPasses.suffix(4))") }
            for device in [a, b] { say("  probe \(device.name): \(device.probe())") }
            for _ in 0..<3 { a.dig.record(target, from: origin); b.dig.record(target, from: origin) }  // the same row, both
            if await settle("same row, both", a, b, database) != nil {
                for device in [a, b] {
                    let rows = UserDataDedupe(context: device.context).rows(forNodeID: target.id)
                    let total = rows.map(\.visits).reduce(0, +)
                    check("counter: \(device.name) still has one visit row", rows.count == 1, "rows \(rows.count)")
                    // Was a known failure (5) before counts were per-device components.
                    check("counter: \(device.name) keeps every concurrent increment", total == 8, "got \(total), not 8")
                }
            }

            if ProcessInfo.processInfo.arguments.contains(onlyCounterArgument) {
                say("\n(stopping after the counter stage: \(onlyCounterArgument))")
                a.removeMarkerRows()
                _ = await settle("cleanup", a, b, database)
                return finish(log)
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
            let t1 = a.log.record(twin, action: .played, at: Date(timeIntervalSince1970: 1_700_000_100), seconds: 7, completion: 0.2)?.id
            let t2 = b.log.record(twin, action: .played, at: Date(timeIntervalSince1970: 1_700_000_100), seconds: 7, completion: 0.2)?.id
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
                          t1 != nil && t2 != nil && events.contains(t1!.uuidString) && events.contains(t2!.uuidString))
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
                let left = a.markerRows(); let rest = left.crate.count + left.events.count + left.visits.count + left.steps.count + left.counters.count
                check("cleanup: no marker row remains", rest == 0, "\(rest)")
            }
            healthy("end", [a, b])
        } catch { problems.append("the run failed: \(error)"); say("the run failed: \(error)") }
        return finish(log)
    }

    private static var devices: [Device] = []

    private static func finish(_ log: ExportLog) -> Int32 {
        for d in devices {
            say("observer \(d.name): \(d.notifications) remote-change notifications, \(d.passes) passes, \(d.merged) rows merged, reopened \(d.reopened) times")
        }
        say("\nmirroring events: \(log.summary)")
        if log.hasFailures { problems.append("mirroring reported failed events") }
        say("time to agree, by stage: \(latencies.joined(separator: ", "))")
        for known in knownFailures { say("known failure: \(known)") }
        say(problems.isEmpty ? "RESULT: every required check held (\(knownFailures.count) known failure(s))" : "RESULT: \(problems.count) problem(s)")
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
        let ea = a.log.record(node(run, "offline listen A"), action: .played, seconds: 11, completion: 0.4)?.id
        let eb = b.log.record(node(run, "offline listen B"), action: .played, seconds: 12, completion: 0.5)?.id
        for _ in 0..<2 { a.dig.record(counter, from: origin) }
        for _ in 0..<3 { b.dig.record(counter, from: origin) }
        let fresh = node(run, "offline new key")
        a.dig.record(fresh); b.dig.record(fresh); b.dig.record(fresh)
        say("CHANGES_MADE")

        guard await waitFor(file: online) else { check("offline: told to reconnect", false, "no signal"); return }
        if await settle("reconnected", a, b, database) != nil {
            for device in [a, b] {
                let events = Set(device.snapshot().ids["ListeningEvent"] ?? [])
                check("offline: \(device.name) holds both offline events", ea != nil && eb != nil && events.contains(ea!.uuidString) && events.contains(eb!.uuidString))
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
