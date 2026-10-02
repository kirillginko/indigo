//
//  SchemaPinTests.swift
//  IndigoTests
//
//  A past version of the schema is the shape that is on people's disks, and it
//  must never change. The way it changes without anyone editing it is a version
//  that lists a live model class: the class moves on and the version moves with
//  it. Unit tests do not notice, because they write their old stores with the
//  same drifted definition they then read them with. A copy of a real store did.
//
//  So each past version is pinned to a digest of the entity hashes Core Data
//  gives its store. V2 was checked against a real store's own hashes and was
//  identical. If one of these fails, a model changed without being frozen in
//  the versions before the change: copy its old shape into those versions as a
//  nested type (see `IndigoSchema.swift`) rather than updating the digest.
//
//  V4 is not pinned: it is the current version and still being built.
//

import XCTest
import SwiftData
import CoreData
import CryptoKit
@testable import Indigo

final class SchemaPinTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaPinTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func digest(of version: any VersionedSchema.Type, named name: String) throws -> String {
        let url = directory.appendingPathComponent("\(name).store")
        let schema = Schema(versionedSchema: version)
        try autoreleasepool {
            _ = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: url)
        let hashes = metadata["NSStoreModelVersionHashes"] as? [String: Data] ?? [:]
        let lines = hashes.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value.map { String(format: "%02x", $0) }.joined())" }
        let sha = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return sha.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    func testVersionOneIsStillTheShapeItWas() throws {
        XCTAssertEqual(try digest(of: IndigoSchemaV1.self, named: "v1"), "59ce71d9dadf0702")
    }

    func testVersionTwoIsStillTheShapeItWas() throws {
        XCTAssertEqual(try digest(of: IndigoSchemaV2.self, named: "v2"), "15af6a0a2bdd4221")
    }

    func testVersionThreeIsStillTheShapeItWas() throws {
        XCTAssertEqual(try digest(of: IndigoSchemaV3.self, named: "v3"), "d679da018d51b86e")
    }
}
