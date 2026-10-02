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

    func testItsOwnWritesAreLeftToTheCodeThatMadeThem() throws {
        show(local, "s", added: 200)
        show(local, "s", added: 100)
        try local.save()

        XCTAssertTrue(observer().process().isEmpty)
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<CrateItem>()), 2)
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
}
