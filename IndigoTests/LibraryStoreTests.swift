//
//  LibraryStoreTests.swift
//  IndigoTests
//
//  Folder access is the one thing a user notices immediately when it breaks:
//  the library is there but nothing plays. These cover the bookmark round trip.
//

import SwiftData
import XCTest
@testable import Indigo

@MainActor
final class LibraryStoreBookmarkTests: XCTestCase {
    private var container: ModelContainer!
    private var folder: URL!
    private var secondFolder: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema([Track.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        secondFolder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        suiteName = "indigo.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: secondFolder)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    /// A URL straight from the open panel has no security scope to start —
    /// treating that as a denial silently loses the bookmark, and the folder
    /// has to be picked again after every launch.
    func testAdoptPersistsABookmark() async throws {
        let store = LibraryStore(container: container, defaults: defaults)
        store.adopt(folder)

        XCTAssertEqual(store.rootURL?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(
            defaults.array(forKey: "library.rootBookmarks")?.count,
            1,
            "Adopting a folder must persist a security-scoped bookmark. notice=\(store.notice ?? "nil")"
        )
        store.cancelScan()
    }

    func testRestoreWithoutABookmarkAsksForTheFolderAgain() async throws {
        defaults.set("/some/old/path", forKey: "library.rootDisplayPath")
        let store = LibraryStore(container: container, defaults: defaults)
        store.restore()
        XCTAssertNil(store.rootURL)
        XCTAssertNotNil(store.notice, "A library with no access must say so, not fail silently")
    }

    func testRestoreReopensTheAdoptedFolder() async throws {
        let first = LibraryStore(container: container, defaults: defaults)
        first.adopt(folder)
        first.cancelScan()

        let second = LibraryStore(container: container, defaults: defaults)
        XCTAssertNil(second.rootURL)
        second.restore()

        XCTAssertEqual(second.rootURL?.standardizedFileURL, folder.standardizedFileURL,
                       "notice=\(second.notice ?? "nil")")
        XCTAssertEqual(second.rootDisplayName, folder.lastPathComponent)
        second.cancelScan()
    }

    func testMultipleFoldersPersistRestoreAndRemove() async throws {
        let first = LibraryStore(container: container, defaults: defaults)
        first.adopt([folder, secondFolder])

        XCTAssertEqual(first.rootURLs.count, 2)
        XCTAssertEqual(defaults.array(forKey: "library.rootBookmarks")?.count, 2)
        first.cancelScan()

        let restored = LibraryStore(container: container, defaults: defaults)
        restored.restore()
        XCTAssertEqual(Set(restored.rootURLs.map(\.standardizedFileURL)),
                       Set([folder.standardizedFileURL, secondFolder.standardizedFileURL]),
                       "notice=\(restored.notice ?? "nil")")

        restored.removeFolder(folder)
        XCTAssertEqual(restored.rootURLs.map(\.standardizedFileURL),
                       [secondFolder.standardizedFileURL])
        XCTAssertEqual(defaults.array(forKey: "library.rootBookmarks")?.count, 1)
        restored.cancelScan()
    }
}
