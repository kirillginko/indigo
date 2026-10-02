//
//  CloudKitSchemaManifestTests.swift
//  IndigoTests
//
//  The manifest is the contract for the deployed schema, so it has to name every
//  field of the four models and nothing else, and agree with the rule that says
//  what a Swift type is stored as.
//

import XCTest
import SwiftData
@testable import Indigo

final class CloudKitSchemaManifestTests: XCTestCase {
    private func entity(_ name: String) throws -> Schema.Entity {
        try XCTUnwrap(Persistence.schema.entities.first { $0.name == name }, name)
    }

    func testTheManifestNamesExactlyTheFieldsOfExactlyTheSyncedModels() throws {
        XCTAssertEqual(Set(CloudKitSchemaManifest.expected.keys), IndigoSchemaV6.userDataModelNames)
        for (name, fields) in CloudKitSchemaManifest.expected {
            XCTAssertEqual(Set(fields.keys), Set(try entity(name).attributes.map(\.name)), name)
        }
        XCTAssertEqual(CloudKitSchemaManifest.expected.values.reduce(0) { $0 + $1.count }, 56)
    }

    func testEveryTypeInTheManifestIsWhatTheRuleSaysItsSwiftTypeIs() throws {
        for (name, fields) in CloudKitSchemaManifest.expected {
            for attribute in try entity(name).attributes {
                XCTAssertEqual(CloudKitSchemaManifest.expectedType(of: attribute.valueType), fields[attribute.name],
                               "\(name).\(attribute.name): \(attribute.valueType)")
            }
        }
    }

    func testAValueReadFromARecordIsNamedInTheManifestsVocabulary() {
        XCTAssertEqual(CloudKitSchemaManifest.classify("x"), "STRING")
        XCTAssertEqual(CloudKitSchemaManifest.classify(Date()), "TIMESTAMP")
        XCTAssertEqual(CloudKitSchemaManifest.classify(Data()), "BYTES")
        XCTAssertEqual(CloudKitSchemaManifest.classify(NSNumber(value: 3 as Int64)), "INT64")
        XCTAssertEqual(CloudKitSchemaManifest.classify(NSNumber(value: 3.5)), "DOUBLE")
        XCTAssertEqual(CloudKitSchemaManifest.classify(NSNumber(value: true)), "INT64")
    }

    func testTheFieldNameIsPrefixed() {
        XCTAssertEqual(CloudKitSchemaManifest.fieldName("matchKey"), "CD_matchKey")
    }
}
