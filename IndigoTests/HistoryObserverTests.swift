//
//  HistoryObserverTests.swift
//  IndigoTests
//
//  The rows another writer made are found through the store's history and
//  merged by key. The other writer here is a second context on the same file,
//  with an author of its own -- which is what an import from CloudKit is.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class HistoryObserverTests: XCTestCase {
    private var directory: URL!
    private var container: ModelContainer!
    private var local: ModelContext!
    private var remote: ModelContext!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryObserverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try Persistence.makeSplitContainer(
            userData: directory.appendingPathComponent("UserData.store"),
            local: directory.appendingPathComponent("Local.store"))
        local = ModelContext(container)
        local.author = "local"
        remote = ModelContext(container)
        remote.author = "remote"
        defaults = UserDefaults(suiteName: "HistoryObserverTests-\(UUID().uuidString)")!
    }

    override func tearDownWithError() throws {
        local = nil; remote = nil; container = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func observer() -> HistoryObserver {
        HistoryObserver(context: local, defaults: defaults, ownAuthor: "local")
    }

    private func show(_ context: ModelContext, _ id: String, added: TimeInterval) {
        let item = CrateItem(
            providerID: "nts", showID: id, showTitle: "Show", showSubtitle: nil, artworkURL: nil,
            playbackURL: nil, embedProvider: nil, isLiveStream: false)
        item.addedAt = Date(timeIntervalSince1970: added)
        context.insert(item)
    }

    func testRowsAnotherWriterMadeForOneThingAreMerged() throws {
        show(remote, "nts.episode.a/b", added: 200)
        show(remote, "nts.episode.a/b", added: 100)
        show(remote, "nts.episode.c/d", added: 300)
        try remote.save()

        let report = observer().process()

        XCTAssertEqual(report.crateMerged, 1)
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<CrateItem>()), 2)
    }

    /// What a removal on another device looks like to this one: the history
    /// holds the insert, and the row is gone. Asking SwiftData for the model of
    /// a row that no longer exists and reading a property off it traps -- found
    /// by two devices that crated and removed something, where it ended the app.
    func testARowAnotherWriterInsertedAndThenDeletedIsSkippedNotRead() throws {
        show(remote, "gone", added: 1)
        remote.insert(DigVisit(node: MusicNode.artist("Gone Artist")))
        remote.insert(DigStep(from: "artist:a", to: "artist:b"))
        remote.insert(ListeningEvent(node: MusicNode.artist("Gone Artist"), action: .played, at: Date(), seconds: 1, completion: 0.1, tags: [], source: nil))
        try remote.save()
        for item in try remote.fetch(FetchDescriptor<CrateItem>()) { remote.delete(item) }
        for visit in try remote.fetch(FetchDescriptor<DigVisit>()) { remote.delete(visit) }
        for step in try remote.fetch(FetchDescriptor<DigStep>()) { remote.delete(step) }
        for event in try remote.fetch(FetchDescriptor<ListeningEvent>()) { remote.delete(event) }
        try remote.save()

        let report = observer().process()

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<CrateItem>()), 0)
    }

    /// The same, with a copy that survives: the row that was removed must not
    /// stop the one that is still there from being merged.
    func testADeletedRowDoesNotHideTheDuplicatesBesideIt() throws {
        show(remote, "kept", added: 100)
        show(remote, "kept", added: 200)
        show(remote, "removed", added: 300)
        try remote.save()
        for item in try remote.fetch(FetchDescriptor<CrateItem>()) where item.showID == "removed" { remote.delete(item) }
        try remote.save()

        let report = observer().process()

        XCTAssertEqual(report.crateMerged, 1)
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<CrateItem>()), 1)
    }

    /// A store made again at the same path -- restored, rebuilt after a
    /// failure, emptied and re-downloaded by iCloud -- starts a history of its
    /// own. A token kept from the old one compared as newer than everything in
    /// the new one, so every pass found nothing and nothing was ever merged
    /// again. Found by a sync harness whose stores were new each run.
    func testATokenFromAStoreThatWasMadeAgainIsNotTrusted() throws {
        show(remote, "first", added: 1)
        show(remote, "first", added: 2)
        try remote.save()
        XCTAssertEqual(observer().process().crateMerged, 1)

        // The same path, a new store.
        local = nil; remote = nil; container = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: directory.appendingPathComponent("UserData.store").path + suffix)
        }
        container = try Persistence.makeSplitContainer(
            userData: directory.appendingPathComponent("UserData.store"),
            local: directory.appendingPathComponent("Local.store"))
        local = ModelContext(container); local.author = "local"
        remote = ModelContext(container); remote.author = "remote"

        show(remote, "second", added: 1)
        show(remote, "second", added: 2)
        try remote.save()

        XCTAssertEqual(observer().process().crateMerged, 1, "the old store's token must not hide the new store's rows")
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<CrateItem>()), 1)
    }

    /// The container holds two stores, and the cache in `Local` is written far
    /// more often than the listener's data. The observer kept the newest
    /// transaction of *either* store as its place; when that was a cache write,
    /// the next pass asked for UserData transactions after a token that named
    /// only `Local`, got nothing, and imports went unmerged until a relaunch.
    /// Found on a real Mac whose token named the Local store at 46,016 while
    /// UserData had 49 transactions.
    func testCacheWritesBetweenImportsDoNotHideTheImports() throws {
        show(remote, "first", added: 1)
        show(remote, "first", added: 2)
        try remote.save()
        XCTAssertEqual(observer().process().crateMerged, 1)

        // The cache is written, often: the other store's transactions run far
        // ahead of UserData's, as they do in the app (46,016 against 49).
        for index in 0..<60 {
            local.insert(ArtistPortrait(nameKey: "artist \(index)", name: "Artist \(index)"))
            try local.save()
        }
        XCTAssertEqual(observer().process().crateMerged, 0)

        show(remote, "second", added: 1)
        show(remote, "second", added: 2)
        try remote.save()
        local.insert(ArtistPortrait(nameKey: "objekt", name: "Objekt"))
        try local.save()

        XCTAssertEqual(observer().process().crateMerged, 1, "an import after a cache write must still be seen")
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<CrateItem>()), 2)
    }

    /// After a pass, the place kept covers both stores: a pass with nothing new
    /// in either reads nothing, however many cache writes came before.
    func testAPassWithNothingNewReadsNothing() throws {
        show(remote, "a", added: 1)
        try remote.save()
        for index in 0..<40 {
            local.insert(ArtistPortrait(nameKey: "artist \(index)", name: "Artist \(index)"))
            try local.save()
        }
        observer().process()
        var seen: [Int] = []
        var again = observer()
        again.onPass = { seen.append($0.transactions) }
        again.process()
        XCTAssertEqual(seen, [0])
    }

    func testWhatItHasSeenIsNotLookedAtAgain() throws {
        show(remote, "s", added: 200)
        show(remote, "s", added: 100)
        try remote.save()
        XCTAssertEqual(observer().process().crateMerged, 1)

        XCTAssertTrue(observer().process().isEmpty)

        show(remote, "t", added: 1)
        show(remote, "t", added: 2)
        try remote.save()
        XCTAssertEqual(observer().process().crateMerged, 1, "only the new transaction")
    }

    /// Once it has a place. Before UserData has any history there is none: a
    /// pass reads no history and merges whatever the tables hold, whoever
    /// wrote it.
    func testItsOwnWritesAreLeftToTheCodeThatMadeThem() throws {
        show(remote, "r", added: 1)
        try remote.save()
        XCTAssertTrue(observer().process().isEmpty)
        show(local, "s", added: 200)
        show(local, "s", added: 100)
        try local.save()

        XCTAssertTrue(observer().process().isEmpty)
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<CrateItem>()), 3)
    }

    func testVisitsAndStepsAnotherWriterMadeAreMergedToo() throws {
        let node = MusicNode.artist("Skee Mask")
        for visits in [3, 4] {
            let visit = DigVisit(node: node)
            visit.visits = visits
            remote.insert(visit)
            let step = DigStep(from: "artist:a", to: node.id)
            step.count = visits
            remote.insert(step)
        }
        try remote.save()

        let report = observer().process()

        XCTAssertEqual(report.visitsMerged, 1)
        XCTAssertEqual(report.stepsMerged, 1)
        XCTAssertEqual(try local.fetch(FetchDescriptor<DigVisit>()).map(\.visits), [7])
        XCTAssertEqual(try local.fetch(FetchDescriptor<DigStep>()).map(\.count), [7])
    }

    func testACopyOfAnEventAnotherWriterReplayedIsCollapsed() throws {
        let node = MusicNode.artist("Skee Mask")
        let id = UUID()
        for _ in 0..<2 {
            let event = ListeningEvent(node: node, action: .played, seconds: 60)
            event.id = id
            remote.insert(event)
        }
        try remote.save()

        let report = observer().process()

        XCTAssertEqual(report.eventsMerged, 1)
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<ListeningEvent>()), 1)
    }

    // MARK: No place yet

    /// A new UserData beside a busy cache: the first pass read the whole
    /// history from its start, the cache's included, and held the main thread
    /// for 41 seconds. With no place it reads none, and merges from the tables.
    func testAFirstPassReadsNoHistoryAndStillMerges() throws {
        for index in 0..<40 {
            local.insert(ArtistPortrait(nameKey: "artist \(index)", name: "Artist \(index)"))
            try local.save()
        }
        show(remote, "s", added: 200)
        show(remote, "s", added: 100)
        try remote.save()

        var passes: [HistoryObserver.Pass] = []
        var first = observer()
        first.onPass = { passes.append($0) }
        XCTAssertEqual(first.process().crateMerged, 1)
        XCTAssertEqual(passes.map(\.transactions), [0], "no history read")
        XCTAssertEqual(passes.map(\.hadToken), [false])

        // And from then on, only what is new.
        show(remote, "t", added: 1)
        show(remote, "t", added: 2)
        try remote.save()
        passes = []
        var next = observer()
        next.onPass = { passes.append($0) }
        XCTAssertEqual(next.process().crateMerged, 1)
        XCTAssertEqual(passes.map(\.hadToken), [true])
        // The other writer's one, and the first pass's own merge, skipped.
        XCTAssertEqual(passes.first?.foreign, 1)
    }

    /// A store with no history of its own yet is not a reason to read the
    /// cache's from the start either.
    func testANewStoreBesideABusyCacheReadsNoHistory() throws {
        for index in 0..<40 {
            local.insert(ArtistPortrait(nameKey: "artist \(index)", name: "Artist \(index)"))
            try local.save()
        }
        var passes: [HistoryObserver.Pass] = []
        var first = observer()
        first.onPass = { passes.append($0) }
        XCTAssertTrue(first.process().isEmpty)
        XCTAssertEqual(passes.map(\.transactions), [0])
    }

    // MARK: One batch, the same answer

    /// Duplicates of every kind, and components that disagree with their rows.
    private func untidy(_ context: ModelContext) {
        show(context, "nts.episode.a/b", added: 200)
        show(context, "nts.episode.a/b", added: 100)
        let eventID = UUID(uuidString: "5F32F85D-75AE-4FF6-BBEB-E16C879E79AA")!
        for _ in 0..<2 {
            let event = ListeningEvent(node: .artist("Skee Mask"), action: .played, seconds: 60)
            event.id = eventID
            context.insert(event)
        }
        let a = MusicNode.artist("Skee Mask"), b = MusicNode.label("Ilian Tape")
        for visits in [3, 4] {
            let visit = DigVisit(node: a)
            visit.visits = visits
            visit.firstVisitedAt = Date(timeIntervalSince1970: Double(visits * 10))
            visit.lastVisitedAt = Date(timeIntervalSince1970: Double(visits * 100))
            context.insert(visit)
        }
        context.insert(DigVisit(node: b))
        for count in [2, 5] {
            let step = DigStep(from: a.id, to: b.id)
            step.count = count
            context.insert(step)
        }
        // Two devices' components for b, one of them twice; one for the step.
        for (device, count, last) in [("mac", 4, 300.0), ("mac", 6, 200.0), ("phone", 3, 400.0)] {
            let counter = DigCounter(kind: .visit, key: b.id, deviceID: device)
            counter.count = count
            counter.firstAt = Date(timeIntervalSince1970: 50)
            counter.lastAt = Date(timeIntervalSince1970: last)
            context.insert(counter)
        }
        let stepCounter = DigCounter(kind: .step, key: DigStep.canonicalIdentity(from: a.id, to: b.id), deviceID: "phone")
        stepCounter.count = 9
        stepCounter.lastAt = Date(timeIntervalSince1970: 500)
        context.insert(stepCounter)
    }

    private func snapshot(_ context: ModelContext) throws -> [String] {
        try context.fetch(FetchDescriptor<CrateItem>()).map { "crate \($0.showID ?? "") \($0.addedAt.timeIntervalSince1970)" }.sorted()
            + context.fetch(FetchDescriptor<ListeningEvent>()).map { "event \($0.id)" }.sorted()
            + context.fetch(FetchDescriptor<DigVisit>()).map {
                "visit \($0.nodeID) \($0.visits) \($0.firstVisitedAt.timeIntervalSince1970) \($0.lastVisitedAt.timeIntervalSince1970)" }.sorted()
            + context.fetch(FetchDescriptor<DigStep>()).map { "step \($0.identity) \($0.count) \($0.lastAt.timeIntervalSince1970)" }.sorted()
            + context.fetch(FetchDescriptor<DigCounter>()).map {
                "counter \($0.kindRaw) \($0.key) \($0.deviceID) \($0.count) \($0.lastAt.timeIntervalSince1970)" }.sorted()
    }

    /// The observer merges a batch with one query per table. What it leaves
    /// must be exactly what the calls for one thing at a time leave.
    func testABatchMergesExactlyAsOneThingAtATimeDoes() throws {
        untidy(remote)
        try remote.save()
        let report = observer().process()
        XCTAssertGreaterThan(report.crateMerged + report.eventsMerged + report.visitsMerged
                             + report.stepsMerged + report.countersMerged, 0)
        let batched = try snapshot(local)

        // The same rows in a second store, merged the old way.
        let other = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let container2 = try Persistence.makeSplitContainer(
            userData: other.appendingPathComponent("UserData.store"), local: other.appendingPathComponent("Local.store"))
        let context2 = ModelContext(container2)
        untidy(context2)
        try context2.save()
        let dedupe = UserDataDedupe(context: context2)
        dedupe.assignIDs()
        for id in Set(try context2.fetch(FetchDescriptor<ListeningEvent>()).map(\.id)) { dedupe.event(id: id) }
        let crate = try context2.fetch(FetchDescriptor<CrateItem>())
        for id in Set(crate.map(\.id)) { dedupe.crateRow(id: id) }
        for key in Set(crate.compactMap(UserDataDedupe.key(of:))) { dedupe.crate(key: key) }
        for nodeID in Set(try context2.fetch(FetchDescriptor<DigVisit>()).map(\.nodeID)) { dedupe.visit(nodeID: nodeID) }
        for identity in Set(try context2.fetch(FetchDescriptor<DigStep>()).map(\.identity)) { dedupe.step(identity: identity) }
        for counter in Set(try context2.fetch(FetchDescriptor<DigCounter>()).map { "\($0.kindRaw)\u{0}\($0.key)" }) {
            let parts = counter.split(separator: "\u{0}", maxSplits: 1).map(String.init)
            dedupe.counter(kind: DigCounterKind(rawValue: parts[0])!, key: parts[1])
        }
        try context2.save()

        XCTAssertEqual(batched, try snapshot(context2))
        XCTAssertEqual(UserDataInvariants.violations(in: local), [])
    }
}
