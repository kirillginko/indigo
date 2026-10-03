//
//  CloudKitEnvironmentTests.swift
//  IndigoTests
//
//  One store, one CloudKit environment: a Debug build never opens the store a
//  Production build mirrors.
//

import SQLite3
import XCTest
@testable import Indigo

final class CloudKitEnvironmentTests: XCTestCase {
    func testProductionKeepsTheStoresEveryInstallAlreadyHas() {
        XCTAssertEqual(StoreLayout.forEnvironment(.production), StoreLayout.standard)
    }

    func testDevelopmentHasAFolderOfItsOwn() {
        let development = StoreLayout.forEnvironment(.development)
        XCTAssertEqual(development.directory.deletingLastPathComponent().standardizedFileURL,
                       StoreLayout.standard.directory.standardizedFileURL)
        XCTAssertEqual(development.directory.lastPathComponent, "Development")
        XCTAssertNotEqual(development.userData, StoreLayout.standard.userData)
        XCTAssertNotEqual(development.legacy, StoreLayout.standard.legacy)
    }

    /// The test host is a Debug build, signed for development.
    func testADebugBuildOpensTheDevelopmentStores() {
        XCTAssertEqual(CloudKitEnvironment.current, .development)
        XCTAssertEqual(Persistence.layout, StoreLayout.forEnvironment(.development))
    }
}

/// A new Development folder starts with a copy of the real cache.
final class CacheSeedTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CacheSeedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func cache(at url: URL, rows: Int) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE ZTHING (Z_PK INTEGER PRIMARY KEY)", nil, nil, nil)
        for _ in 0..<rows { sqlite3_exec(db, "INSERT INTO ZTHING DEFAULT VALUES", nil, nil, nil) }
    }

    func testANewFolderStartsFromACopyOfTheRealCache() throws {
        let source = StoreLayout(directory: root)
        let development = StoreLayout(directory: root.appendingPathComponent("Development", isDirectory: true))
        try FileManager.default.createDirectory(at: development.directory, withIntermediateDirectories: true)
        try cache(at: source.local, rows: 3)

        development.seedCache(from: source)

        XCTAssertEqual(SQLiteFiles.count("ZTHING", in: development.local), 3)
        XCTAssertEqual(SQLiteFiles.count("ZTHING", in: source.local), 3)
    }

    func testAFolderThatHasACacheKeepsIt() throws {
        let source = StoreLayout(directory: root)
        let development = StoreLayout(directory: root.appendingPathComponent("Development", isDirectory: true))
        try FileManager.default.createDirectory(at: development.directory, withIntermediateDirectories: true)
        try cache(at: source.local, rows: 3)
        try cache(at: development.local, rows: 1)

        development.seedCache(from: source)

        XCTAssertEqual(SQLiteFiles.count("ZTHING", in: development.local), 1)
    }

    func testTheRealLayoutIsNeverSeededFromItself() throws {
        let source = StoreLayout(directory: root)
        source.seedCache(from: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.local.path))
    }
}
