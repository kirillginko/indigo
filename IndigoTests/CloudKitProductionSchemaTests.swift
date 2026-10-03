//
//  CloudKitProductionSchemaTests.swift
//  IndigoTests
//
//  The Production schema as it was before any data reached it, exported by
//  `cktool` and checked in unedited, held to the manifest the code is held to.
//  Production can only be added to, so this is the shape every later build
//  has to stay compatible with: five record types, every field the manifest
//  names with the type it names, and nothing else of the app's.
//

import XCTest
@testable import Indigo

final class CloudKitProductionSchemaTests: XCTestCase {
    /// Record type -> field -> type, for the fields CloudKit gives the app's
    /// records. CloudKit's own (`___` and the `Users` type's) are left out.
    private func production() throws -> [String: [String: String]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Indigo/Persistence/CloudKitSchema.production.ckdb"), encoding: .utf8)
        var types: [String: [String: String]] = [:]
        var current: String?
        for line in text.components(separatedBy: .newlines) {
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if words.starts(with: ["RECORD", "TYPE"]), words.count >= 3 {
                current = words[2]; types[words[2]] = [:]
            } else if let current, let name = words.first, name.hasPrefix("CD_"), words.count >= 2 {
                types[current]?[name] = words[1].trimmingCharacters(in: CharacterSet(charactersIn: ","))
            }
        }
        return types
    }

    func testProductionHoldsTheFiveRecordTypesAndCloudKitsOwn() throws {
        XCTAssertEqual(Set(try production().keys),
                       ["CD_CrateItem", "CD_ListeningEvent", "CD_DigVisit", "CD_DigStep", "CD_DigCounter", "Users"])
    }

    func testEveryFieldIsTheTypeTheManifestSays() throws {
        let schema = try production()
        XCTAssertEqual(Set(CloudKitSchemaManifest.expected.keys), ["CrateItem", "ListeningEvent", "DigVisit", "DigStep", "DigCounter"])
        for (entity, fields) in CloudKitSchemaManifest.expected {
            var expected = Dictionary(uniqueKeysWithValues: fields.map { (CloudKitSchemaManifest.fieldName($0.key), $0.value) })
            expected["CD_entityName"] = "STRING"   // Core Data's, on every type
            XCTAssertEqual(schema["CD_" + entity], expected, entity)
        }
    }

    func testTheCounterTypeIsDeployed() throws {
        let counter = try XCTUnwrap(try production()["CD_DigCounter"])
        XCTAssertEqual(counter.count, 8)
        XCTAssertEqual(counter["CD_kindRaw"], "STRING")
        XCTAssertEqual(counter["CD_count"], "INT64")
        XCTAssertEqual(counter["CD_deviceID"], "STRING")
    }

    func testTheManifestHasSixtyThreeFields() {
        XCTAssertEqual(CloudKitSchemaManifest.expected.values.reduce(0) { $0 + $1.count }, 63)
    }
}
