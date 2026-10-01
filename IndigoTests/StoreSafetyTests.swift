//
//  StoreSafetyTests.swift
//  IndigoTests
//
//  Step 2 of the iCloud plan. A store that will not open is rebuilt only if
//  nothing in it was made by the listener, and that is decided by what the
//  store holds, not by how it failed.
//
//  The files here are real: a rebuild is a delete, and only a file can show
//  whether one happened.
//

import XCTest
import SwiftData
@testable import Indigo

final class StoreSafetyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A file SQLite will refuse, with the sidecars a live store has.
    private func brokenStore(named name: String) throws -> (url: URL, bytes: [String: Data]) {
        let url = directory.appendingPathComponent(name)
        var bytes: [String: Data] = [:]
        for suffix in ["", "-shm", "-wal"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            let data = Data("not a database \(suffix) \(UUID().uuidString)".utf8)
            try data.write(to: file)
            bytes[suffix] = data
        }
        return (url, bytes)
    }

    // MARK: Which store is which

    func testAStoreHoldingAnythingTheListenerMadeIsUserData() {
        for model in StoreRole.userOwnedModels {
            XCTAssertEqual(StoreRole.role(holding: [Track.self, model]), .userData,
                           "\(model) must make its store user data")
        }
        XCTAssertEqual(StoreRole.role(holding: IndigoSchemaV1.models), .userData)
    }

    func testAStoreOfOnlyCachesIsACache() {
        XCTAssertEqual(
            StoreRole.role(holding: [Track.self, Artist.self, StoredEdge.self, GraphSnapshot.self]),
            .cache)
    }

    func testOnlyACacheMayBeDestroyed() {
        XCTAssertTrue(StoreRole.cache.mayBeDestroyed)
        XCTAssertFalse(StoreRole.userData.mayBeDestroyed)
    }

    func testTheAppsStoreIsUserDataAndIsTheFileExistingInstallsHave() {
        XCTAssertEqual(Persistence.storeRole, .userData)
        XCTAssertEqual(Persistence.storeURL, ModelConfiguration(schema: Persistence.schema).url)
        XCTAssertEqual(Persistence.storeURL.lastPathComponent, "default.store")
    }

    func testTheUserOwnedModelsAreAllInTheSchema() {
        let names = Set(IndigoSchemaV1.models.map { String(describing: $0) })
        for model in StoreRole.userOwnedModels {
            XCTAssertTrue(names.contains(String(describing: model)))
        }
    }

    // MARK: A store that will not open

    func testAUserDataStoreThatWillNotOpenIsLeftExactlyAsItWas() throws {
        let (url, before) = try brokenStore(named: "user.store")

        XCTAssertThrowsError(try Persistence.openStore(
            role: .userData, schema: Persistence.schema, at: url)
        ) { error in
            let failure = error as? StoreOpenFailure
            XCTAssertEqual(failure?.role, .userData)
            XCTAssertEqual(failure?.url, url)
        }

        for (suffix, data) in before {
            let file = URL(fileURLWithPath: url.path + suffix)
            XCTAssertEqual(try? Data(contentsOf: file), data,
                           "\(file.lastPathComponent) was changed or removed")
        }
    }

    func testACacheStoreThatWillNotOpenIsRebuilt() throws {
        let (url, before) = try brokenStore(named: "cache.store")

        let container = try Persistence.openStore(
            role: .cache, schema: Persistence.schema, at: url)

        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Track>()), 0)
        XCTAssertNotEqual(try? Data(contentsOf: url), before[""], "the broken file is still there")
    }

    /// The same bytes, the same error, two roles: the role is what decides.
    func testTheRoleDecidesNotTheError() throws {
        let (user, _) = try brokenStore(named: "same-a.store")
        let (cache, _) = try brokenStore(named: "same-b.store")

        XCTAssertThrowsError(try Persistence.openStore(
            role: .userData, schema: Persistence.schema, at: user))
        XCTAssertNoThrow(try Persistence.openStore(
            role: .cache, schema: Persistence.schema, at: cache))
    }

    func testAHealthyUserDataStoreOpensAndKeepsItsRows() throws {
        let url = directory.appendingPathComponent("healthy.store")
        do {
            let container = try Persistence.openStore(
                role: .userData, schema: Persistence.schema, at: url)
            let context = ModelContext(container)
            context.insert(DigVisit(node: MusicNode.label("Ilian Tape")))
            try context.save()
        }

        let reopened = try Persistence.openStore(
            role: .userData, schema: Persistence.schema, at: url)
        XCTAssertEqual(try ModelContext(reopened).fetchCount(FetchDescriptor<DigVisit>()), 1)
    }
}
