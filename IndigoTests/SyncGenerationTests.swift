//
//  SyncGenerationTests.swift
//  IndigoTests
//
//  A store written by a newer build is read and not written: it is not
//  mirrored at launch, and a row arriving that says so stops the merge.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class SyncGenerationTests: XCTestCase {
    private var directory: URL!
    private var layout: StoreLayout!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncGenerationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        layout = StoreLayout(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(generation: Int?, _ fill: (ModelContext) -> Void = { _ in }) throws {
        let container = try Persistence.makeSplitContainer(userData: layout.userData, local: layout.local)
        let context = ModelContext(container)
        if let generation {
            let row = DigCounter(kind: .generation, key: "counters", deviceID: CounterID.base)
            row.count = generation
            context.insert(row)
        }
        fill(context)
        try context.save()
    }

    // MARK: At launch

    func testTheUnderstoodGenerationIsSeven() {
        XCTAssertEqual(SyncGeneration.understood, 7)
        XCTAssertFalse(SyncGeneration.isNewer(nil))
        XCTAssertFalse(SyncGeneration.isNewer(7))
        XCTAssertTrue(SyncGeneration.isNewer(8))
    }

    func testTheGenerationIsReadFromTheFile() throws {
        XCTAssertNil(SyncGeneration.advertised(inStoreAt: layout.userData))
        try store(generation: nil)
        XCTAssertNil(SyncGeneration.advertised(inStoreAt: layout.userData))
        try store(generation: 7)
        XCTAssertEqual(SyncGeneration.advertised(inStoreAt: layout.userData), 7)
    }

    func testAStoreOfThisGenerationOpensAsUsual() throws {
        try store(generation: 7)
        let opened = try Persistence.openSplitStoresReporting(layout: layout)
        XCTAssertNil(opened.newerGeneration)
    }

    /// With sync off: a test never asks for mirroring, in case the guard is
    /// what is broken. The guard is ahead of the sync decision either way.
    func testAStoreFromANewerBuildIsNotMirrored() throws {
        try store(generation: 8)
        let opened = try Persistence.openSplitStoresReporting(layout: layout, sync: .off)
        XCTAssertEqual(opened.newerGeneration, 8)
        XCTAssertFalse(opened.syncing)
        XCTAssertEqual(try ModelContext(opened.container).fetchCount(FetchDescriptor<DigCounter>()), 1)
    }

    // MARK: While running

    func testANewerGenerationArrivingStopsTheMerge() throws {
        let container = try Persistence.makeSplitContainer(userData: layout.userData, local: layout.local)
        let local = ModelContext(container); local.author = "local"
        let remote = ModelContext(container); remote.author = "remote"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SyncGenerationTests-\(UUID().uuidString)"))

        let node = MusicNode.artist("Skee Mask")
        remote.insert(DigVisit(node: node)); remote.insert(DigVisit(node: node))
        let row = DigCounter(kind: .generation, key: "counters", deviceID: CounterID.base)
        row.count = 8
        remote.insert(row)
        try remote.save()

        var observer = HistoryObserver(context: local, defaults: defaults, ownAuthor: "local")
        var refused: Int?
        observer.onNewerGeneration = { refused = $0 }
        let report = observer.process()

        XCTAssertEqual(refused, 8)
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<DigVisit>()), 2, "a newer build's rows are left as it wrote them")
    }
}
