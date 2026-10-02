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
