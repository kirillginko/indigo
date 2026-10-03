//
//  SplitStateTests.swift
//  IndigoTests
//
//  The rules for what a launch does about the move from one store to two, and
//  which file may be destroyed: tested on their own, with files in a temporary
//  directory, before anything is wired to the real ones.
//

import XCTest
import SwiftData
@testable import Indigo

final class SplitStateTests: XCTestCase {
    private var directory: URL!
    private var layout: StoreLayout!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        layout = StoreLayout(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func touch(_ url: URL) throws { try Data("x".utf8).write(to: url) }

    private func decide(_ state: SplitStateStore.Loaded) -> LaunchDecision {
        LaunchDecision.decide(layout: layout, state: state, exists: { FileManager.default.fileExists(atPath: $0.path) })
    }

    // MARK: Which file may be destroyed

    func testOnlyTheLocalStoreIsACache() {
        for file in layout.files(of: layout.local) { XCTAssertEqual(layout.role(of: file), .cache) }
        for file in layout.files(of: layout.legacy) + layout.files(of: layout.archive) {
            XCTAssertEqual(layout.role(of: file), .legacy)
        }
        for file in layout.files(of: layout.userData) { XCTAssertEqual(layout.role(of: file), .userData) }
        XCTAssertEqual(layout.role(of: directory.appendingPathComponent("something-else.store")), .userData,
                       "a path nobody knows is kept")
    }

    func testDestroyingRefusesEveryFileButTheCache() throws {
        for base in [layout.legacy, layout.userData, layout.archive, layout.local] {
            for file in layout.files(of: base) { try touch(file) }
        }

        for base in [layout.legacy, layout.userData, layout.archive] {
            Persistence.destroyCache(at: base, layout: layout)
            for file in layout.files(of: base) {
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)")
            }
        }
        Persistence.destroyCache(at: layout.local, layout: layout)
        for file in layout.files(of: layout.local) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.legacy.path))
    }

    func testOnlyACacheRoleMayBeDestroyed() {
        XCTAssertTrue(StoreRole.cache.mayBeDestroyed)
        XCTAssertFalse(StoreRole.userData.mayBeDestroyed)
        XCTAssertFalse(StoreRole.legacy.mayBeDestroyed)
    }

    // MARK: The state file

    func testAStateIsWrittenAndReadBack() throws {
        let store = SplitStateStore(url: layout.sidecar)
        XCTAssertEqual(store.load(), .missing)

        var state = SplitState(phase: .migratingUserData)
        state.legacyCounts = ["CrateItem": 91]
        try store.save(state)

        guard case .valid(let read) = store.load() else { return XCTFail("not valid") }
        XCTAssertEqual(read.phase, .migratingUserData)
        XCTAssertEqual(read.legacyCounts, ["CrateItem": 91])

        try store.save(SplitState(phase: .splitComplete))
        guard case .valid(let again) = store.load() else { return XCTFail("not valid") }
        XCTAssertEqual(again.phase, .splitComplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.sidecar.path + ".tmp"))
    }

    func testAnUnreadableStateIsNotTheSameAsAMissingOne() throws {
        try Data("not json".utf8).write(to: layout.sidecar)
        XCTAssertEqual(SplitStateStore(url: layout.sidecar).load(), .unreadable)
    }

    // MARK: What a launch does

    func testNothingAtAllIsAFreshInstall() {
        XCTAssertEqual(decide(.missing), .fresh)
    }

    func testAnOldStoreAndNoRecordStartsTheMove() throws {
        try touch(layout.legacy)
        XCTAssertEqual(decide(.missing), .migrate(from: .legacy))
    }

    func testAnInterruptedMoveResumesFromWhereItGot() throws {
        try touch(layout.legacy)
        for phase in [SplitPhase.legacy, .copyingLocal, .migratingUserData, .verifying] {
            XCTAssertEqual(decide(.valid(SplitState(phase: phase))), .migrate(from: phase))
        }
    }

    func testACompleteSplitOpensTheNewStoresAndIgnoresTheOldOne() throws {
        try touch(layout.legacy)
        try touch(layout.userData)
        XCTAssertEqual(decide(.valid(SplitState(phase: .splitComplete))), .split)
    }

    func testAfterTheSplitAMissingDataStoreIsNeverAnExcuseToGoBackToTheOldOne() throws {
        try touch(layout.legacy)
        guard case .safeMode = decide(.valid(SplitState(phase: .splitComplete))) else {
            return XCTFail("fell back")
        }
    }

    func testAnUnreadableRecordIsSafeModeWhateverElseExists() throws {
        try touch(layout.legacy)
        try touch(layout.userData)
        guard case .safeMode = decide(.unreadable) else { return XCTFail() }
    }

    func testADataStoreWithNoRecordOfHowItGotThereIsNotGuessedAbout() throws {
        try touch(layout.userData)
        guard case .safeMode = decide(.missing) else { return XCTFail() }
        try touch(layout.legacy)
        guard case .safeMode = decide(.missing) else { return XCTFail() }
    }

    func testTheOldStoreVanishingMidMoveIsSafeMode() {
        guard case .safeMode = decide(.valid(SplitState(phase: .migratingUserData))) else { return XCTFail() }
    }
}
