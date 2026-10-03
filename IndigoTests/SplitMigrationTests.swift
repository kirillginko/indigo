//
//  SplitMigrationTests.swift
//  IndigoTests
//
//  The move from one store to two, on a store shaped like the listener's. What
//  has to hold, in order of how much it matters:
//
//    * the old store is never changed -- not its bytes, not its schema;
//    * the move can be stopped at any point and run again, and ends in the same
//      place;
//    * what is in the new store is checked against what was in the old, and a
//      move that does not check out is not exposed;
//    * once the split is complete nothing goes back to the old store.
//

import XCTest
import SwiftData
@testable import Indigo

final class SplitMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func make(_ name: String = "layout") throws -> (StoreLayout, LegacyStoreFixture.Contents) {
        let layout = StoreLayout(directory: directory.appendingPathComponent(name, isDirectory: true))
        return (layout, try LegacyStoreFixture.make(in: layout))
    }

    private struct Held: Equatable {
        var crate: [CrateValue]
        var events: [EventValue]
        var visits: [VisitValue]
        var steps: [StepValue]
        var recordings: Int
        var discogs: Int
        var edges: Int
    }

    private func held(_ container: ModelContainer) throws -> Held {
        let c = ModelContext(container)
        return Held(
            crate: try c.fetch(FetchDescriptor<CrateItem>()).map(CrateValue.init).sorted { $0.id.uuidString < $1.id.uuidString },
            events: try c.fetch(FetchDescriptor<ListeningEvent>()).map(EventValue.init).sorted { $0.id.uuidString < $1.id.uuidString },
            visits: try c.fetch(FetchDescriptor<DigVisit>()).map(VisitValue.init).sorted { $0.nodeID < $1.nodeID },
            steps: try c.fetch(FetchDescriptor<DigStep>()).map(StepValue.init).sorted { $0.identity < $1.identity },
            recordings: try c.fetchCount(FetchDescriptor<Recording>()),
            discogs: try c.fetchCount(FetchDescriptor<DiscogsArtist>()),
            edges: try c.fetchCount(FetchDescriptor<StoredEdge>()))
    }

    private func state(_ layout: StoreLayout) -> SplitState? {
        if case .valid(let s) = SplitStateStore(url: layout.sidecar).load() { return s }
        return nil
    }

    // MARK: The move

    func testTheMoveGivesTheListenerTheirDataAndTheCacheAndLeavesTheOldStoreAlone() throws {
        let (layout, c) = try make()
        let before = LegacyStoreFixture.fingerprint(layout, layout.legacy)

        let container = try SplitMigration(layout: layout).run()
        let h = try held(container)

        XCTAssertEqual(LegacyStoreFixture.fingerprint(layout, layout.legacy), before, "not one byte of default.store")
        XCTAssertEqual(state(layout)?.phase, .splitComplete)
        XCTAssertEqual(h.crate.count, 5)
        XCTAssertEqual(h.events.count, 6)
        XCTAssertEqual(h.recordings, 8, "the cache came across whole")
        XCTAssertEqual(h.discogs, 2)
        XCTAssertEqual(h.edges, 3)

        // The crate rows kept their ids and gained their snapshots.
        let plain = try XCTUnwrap(h.crate.first { $0.id == c.crateIDs["plain"] })
        XCTAssertEqual(plain.matchKey, c.plainKey)
        XCTAssertEqual(plain.title, "Rev8617")
        XCTAssertEqual(plain.playbackURLString, "https://www.youtube.com/watch?v=abc")
        XCTAssertEqual(plain.artworkURLString, "https://art/plain", "what the listener kept is kept")
        let twin = try XCTUnwrap(h.crate.first { $0.id == c.crateIDs["twin"] })
        XCTAssertTrue(twin.unknownCode != nil, "a placeholder is told apart from its twins")
        XCTAssertEqual(twin.matchKey, c.sharedKey)
        let dangling = try XCTUnwrap(h.crate.first { $0.id == c.crateIDs["dangling"] })
        XCTAssertTrue(dangling.matchKey.isEmpty && dangling.unknownCode == nil, "no recording behind it, left as it was")
        XCTAssertEqual(h.crate.count, Set(h.crate.map(\.id)).count)

        // Events keep their ids; the ones that named a local recording name its identity.
        let sharedEvent = try XCTUnwrap(h.events.first { $0.id == c.eventIDs["twin"] })
        XCTAssertTrue(sharedEvent.nodeKey.hasPrefix(c.sharedKey + "#"), sharedEvent.nodeKey)
        XCTAssertEqual(h.events.first { $0.id == c.eventIDs["gone"] }?.nodeKey, "gone gone", "history is never deleted")
        XCTAssertEqual(h.events.first { $0.id == c.eventIDs["artist"] }?.nodeID, "artist:skee mask")

        // The 3-hit visit is filed under the placeholder it was to, with its hits.
        let hits = try XCTUnwrap(h.visits.first { $0.visits == 3 })
        XCTAssertEqual(hits.nodeID, "recording:" + sharedEvent.nodeKey)
        XCTAssertEqual(h.visits.count, 3)

        // Steps follow the node that meant one thing, and leave the one that meant two.
        let moved = try XCTUnwrap(h.steps.first { $0.count == 2 })
        XCTAssertEqual(moved.toNodeID, hits.nodeID)
        XCTAssertEqual(h.steps.first { $0.count == 4 }?.toNodeID, "recording:" + c.otherKey)
        XCTAssertTrue(h.steps.allSatisfy { $0.id != nil })
    }

    func testTheListenersRowsAreNotInTheCacheAndTheCacheIsNotInTheirStore() throws {
        let (layout, _) = try make()
        _ = try SplitMigration(layout: layout).run()

        for table in ["ZCRATEITEM", "ZLISTENINGEVENT", "ZDIGVISIT", "ZDIGSTEP"] {
            XCTAssertEqual(SQLiteFiles.count(table, in: layout.local), 0, table)
            XCTAssertGreaterThan(SQLiteFiles.count(table, in: layout.userData) ?? 0, 0, table)
        }
        for table in ["ZRECORDING", "ZDISCOGSARTIST", "ZSTOREDEDGE"] {
            XCTAssertEqual(SQLiteFiles.count(table, in: layout.userData), 0, table)
        }
    }

    // MARK: Stopping and starting again

    func testTheMoveCanBeStoppedAtEveryPointAndRunAgainToTheSameResult() throws {
        let (baseLayout, _) = try make("baseline")
        let baseline = try held(SplitMigration(layout: baseLayout).run())

        for checkpoint in SplitMigration.Checkpoint.allCases {
            let (layout, _) = try make("crash-\(checkpoint.rawValue)")
            let before = LegacyStoreFixture.fingerprint(layout, layout.legacy)

            XCTAssertThrowsError(try SplitMigration(layout: layout, crashAt: checkpoint).run(), "\(checkpoint)")
            XCTAssertNotEqual(state(layout)?.phase, .splitComplete, "stopped at \(checkpoint) is not finished")
            XCTAssertEqual(LegacyStoreFixture.fingerprint(layout, layout.legacy), before, "\(checkpoint)")

            let resumed = try held(SplitMigration(layout: layout).run())

            XCTAssertEqual(resumed.crate.count, baseline.crate.count, "\(checkpoint)")
            XCTAssertEqual(resumed.events, baseline.events, "\(checkpoint)")
            XCTAssertEqual(resumed.visits, baseline.visits, "\(checkpoint)")
            XCTAssertEqual(resumed.steps, baseline.steps, "\(checkpoint)")
            XCTAssertEqual(resumed.crate.map(\.id), baseline.crate.map(\.id), "\(checkpoint)")
            XCTAssertEqual(resumed.recordings, baseline.recordings, "\(checkpoint)")
            XCTAssertEqual(state(layout)?.phase, .splitComplete, "\(checkpoint)")
            XCTAssertEqual(LegacyStoreFixture.fingerprint(layout, layout.legacy), before, "\(checkpoint)")
        }
    }

    func testAMoveThatIsAlreadyCompleteIsLeftAlone() throws {
        let (layout, _) = try make()
        let first = try held(SplitMigration(layout: layout).run())
        let userBefore = try Data(contentsOf: layout.userData)

        let again = try held(SplitMigration(layout: layout).run())

        XCTAssertEqual(again, first)
        XCTAssertEqual(try Data(contentsOf: layout.userData).count, userBefore.count)
    }

    // MARK: What is not exposed

    func testNewDataThatDoesNotMatchTheOldIsCaughtAndNotExposed() throws {
        let (layout, _) = try make()
        XCTAssertThrowsError(try SplitMigration(layout: layout, crashAt: .userDataSaved).run())
        // Something alters the new store between the save and the check.
        try autoreleasepool {
            let container = try Persistence.openSplitStores(layout: layout)
            let context = ModelContext(container)
            try XCTUnwrap(try context.fetch(FetchDescriptor<DigVisit>()).first).visits += 1
            try context.save()
        }

        XCTAssertThrowsError(try SplitMigration(layout: layout).run()) { error in
            guard case SplitMigrationError.verificationFailed = error else { return XCTFail("\(error)") }
        }

        XCTAssertEqual(state(layout)?.phase, .verifying, "not complete, so never exposed")
    }

    func testACacheThatWasLostMidMoveIsRebuiltBeforeAnyRowIsRewrittenAgainstIt() throws {
        let (layout, _) = try make()
        XCTAssertThrowsError(try SplitMigration(layout: layout, crashAt: .markedMigrating).run())
        try Data("gone".utf8).write(to: layout.local)     // the cache is destroyed

        XCTAssertThrowsError(try SplitMigration(layout: layout).run()) { error in
            guard case SplitMigrationError.localCopyIncomplete = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(state(layout)?.phase, .copyingLocal, "back to rebuilding the cache")

        let finished = try held(SplitMigration(layout: layout).run())
        XCTAssertEqual(finished.recordings, 8)
        XCTAssertTrue(finished.events.contains { $0.nodeKey.contains("#") }, "and it rewrote against the rebuilt one")
    }

    // MARK: After the door

    func testALaunchRunsTheMoveThenOpensTheSplitStoresAndNeverGoesBack() throws {
        let (layout, _) = try make()
        let before = LegacyStoreFixture.fingerprint(layout, layout.legacy)

        let first = SplitLaunch.open(layout: layout)
        XCTAssertNil(first.failure)
        XCTAssertEqual(try held(first.container).events.count, 6)

        // However many launches there are, the old store stays where it is.
        for _ in 1...6 {
            let opened = SplitLaunch.open(layout: layout)
            XCTAssertNil(opened.failure)
            XCTAssertEqual(try held(opened.container).crate.count, 5)
        }
        XCTAssertEqual(LegacyStoreFixture.fingerprint(layout, layout.legacy), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.archive.path))
        XCTAssertEqual(state(layout)?.splitLaunches, 6)
        XCTAssertEqual(state(layout)?.finalized, false)
    }

    func testTheOldStoreIsArchivedOnlyAfterTheSplitIsDeliberatelyFinalized() throws {
        let (layout, _) = try make()
        let before = LegacyStoreFixture.fingerprint(layout, layout.legacy)
        _ = SplitLaunch.open(layout: layout)

        XCTAssertTrue(SplitLaunch.finalize(layout: layout))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.legacy.path), "finalizing renames nothing by itself")

        let opened = SplitLaunch.open(layout: layout)

        XCTAssertNil(opened.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.legacy.path))
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.legacy.path + suffix), suffix)
        }
        XCTAssertEqual(LegacyStoreFixture.fingerprint(layout, layout.archive)["pre-split-v5.store"],
                       before["default.store"], "the archive is the old store, byte for byte")
        XCTAssertEqual(state(layout)?.archived, true)
        XCTAssertEqual(try held(SplitLaunch.open(layout: layout).container).crate.count, 5)
    }

    func testFinalizingBeforeTheSplitIsCompleteDoesNothing() throws {
        let (layout, _) = try make()
        XCTAssertFalse(SplitLaunch.finalize(layout: layout))
    }

    func testAfterTheSplitAMissingDataStoreIsSafeModeAndNotAFallbackToTheOldOne() throws {
        let (layout, _) = try make()
        _ = SplitLaunch.open(layout: layout)
        try FileManager.default.removeItem(at: layout.userData)

        let opened = SplitLaunch.open(layout: layout)

        XCTAssertNotNil(opened.failure)
        XCTAssertTrue(opened.container.configurations.allSatisfy(\.isStoredInMemoryOnly), "nothing is written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.legacy.path), "and the old one is left exactly where it is")
    }

    func testAFreshInstallMakesBothStoresAndRecordsTheSplit() throws {
        let layout = StoreLayout(directory: directory.appendingPathComponent("fresh", isDirectory: true))
        try FileManager.default.createDirectory(at: layout.directory, withIntermediateDirectories: true)

        let opened = SplitLaunch.open(layout: layout)

        XCTAssertNil(opened.failure)
        XCTAssertEqual(state(layout)?.phase, .splitComplete)
        XCTAssertEqual(state(layout)?.fresh, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.userData.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.local.path))
    }

    // MARK: The rewrite, on its own

    func testTheTransformGivesTheSameRowsEveryTime() throws {
        let (layout, _) = try make()
        let container = try SplitMigration(layout: layout).run()
        let old = try LegacyReader.read(copy: try copyOfLegacy(layout))
        let context = ModelContext(container)
        let store = RecordingStore(context: context)

        func run() -> MigratedUserData {
            UserDataTransform.transform(
                old, recording: { (try? store.recording(id: $0)) ?? nil },
                snapshot: { CrateSnapshot.capture($0, context: context) })
        }

        XCTAssertEqual(run(), run())
        XCTAssertEqual(UserDataTransform.stableID("x"), UserDataTransform.stableID("x"))
        XCTAssertNotEqual(UserDataTransform.stableID("x"), UserDataTransform.stableID("y"))
    }

    private func copyOfLegacy(_ layout: StoreLayout) throws -> URL {
        let scratch = directory.appendingPathComponent("legacy-copy-\(UUID().uuidString)", isDirectory: true)
        let url = scratch.appendingPathComponent("copy.store")
        try SQLiteFiles.snapshot(of: layout.legacy, to: url, scratch: scratch.appendingPathComponent("s"))
        return url
    }

    // MARK: The cache is a cache

    func testTheCrateStillShowsEverythingWhenTheCacheIsGoneAndViewingItDoesNotRefillTheCache() throws {
        let (layout, c) = try make()
        _ = SplitLaunch.open(layout: layout)
        for file in layout.files(of: layout.local) { try? FileManager.default.removeItem(at: file) }

        let opened = SplitLaunch.open(layout: layout)

        XCTAssertNil(opened.failure)
        let context = ModelContext(opened.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CrateItem>()), 5, "the crate does not depend on the cache")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Recording>()), 0)

        // Drawing the crate looks recordings up and makes none, and still has
        // something to show and play for a row with no recording behind it.
        let crate = CrateService(context: context)
        crate.refreshRowCache(digRevision: 0, digDestination: { _ in nil })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Recording>()), 0, "viewing the crate fills nothing")
        let plain = try XCTUnwrap(crate.items().first { $0.id == c.crateIDs["plain"] })
        XCTAssertEqual(plain.displayTitle, "Rev8617")
        XCTAssertNotNil(crate.resolvedSources[plain.id], "it still plays from what it kept")

        // Opening something is what makes the recording it needs.
        XCTAssertNotNil(CrateRecordings(context: context).resolve(plain))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Recording>()), 1)
    }
}
