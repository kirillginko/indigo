//
//  CloudKitCompatibilityTests.swift
//  IndigoTests
//
//  What CloudKit will not store, checked on the models that are going to be
//  synced: no unique constraints, and every property either optional or
//  carrying a default. Relationships are not allowed to cross into a synced
//  store, and exactly one remains.
//
//  There are no exceptions. `CrateItem.legacyRecording` was the last, and it
//  went in V6: a relationship from a synced model to a `Recording` that stays on
//  the device does not fail when the two live in different stores, it silently
//  writes a copy of the `Recording` into the synced one. This test is what keeps
//  that from coming back, and it has to pass before the first two-store container
//  is created.
//

import XCTest
import SwiftData
@testable import Indigo

final class CloudKitCompatibilityTests: XCTestCase {
    private let synced = ["CrateItem", "ListeningEvent", "DigVisit", "DigStep"]

    private func entity(_ name: String) throws -> Schema.Entity {
        try XCTUnwrap(Persistence.schema.entities.first { $0.name == name }, name)
    }

    func testNoSyncedModelHasAUniquenessConstraint() throws {
        for name in synced {
            let entity = try entity(name)
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty, "\(name): \(entity.uniquenessConstraints)")
            for attribute in entity.attributes {
                XCTAssertFalse(attribute.isUnique, "\(name).\(attribute.name)")
            }
        }
    }

    func testEverySyncedPropertyIsOptionalOrHasADefault() throws {
        for name in synced {
            for attribute in try entity(name).attributes {
                let optional = attribute.isOptional
                let hasDefault = attribute.defaultValue != nil
                XCTAssertTrue(optional || hasDefault, "\(name).\(attribute.name) is neither optional nor defaulted")
            }
        }
    }

    func testNoSyncedModelHasARelationshipAtAll() throws {
        for name in synced {
            let relationships = try entity(name).relationships.map(\.name)
            XCTAssertTrue(relationships.isEmpty, "\(name) points at \(relationships)")
        }
    }

    func testNothingOnTheDeviceAndNothingSyncedPointAtEachOther() throws {
        let userNames = IndigoSchemaV6.userDataModelNames
        for entity in Persistence.schema.entities {
            for relationship in entity.relationships {
                let crosses = userNames.contains(entity.name) != userNames.contains(relationship.destination)
                XCTAssertFalse(crosses, "\(entity.name).\(relationship.name) -> \(relationship.destination)")
            }
        }
    }

    func testTheSplitMembershipCoversEveryModelExactlyOnce() {
        let all = IndigoSchemaV6.models.map { String(describing: $0) }
        let user = IndigoSchemaV6.userDataModels.map { String(describing: $0) }
        let local = IndigoSchemaV6.localModels.map { String(describing: $0) }
        XCTAssertEqual(Set(user), IndigoSchemaV6.userDataModelNames)
        XCTAssertEqual(user.count + local.count, all.count)
        XCTAssertTrue(Set(user).isDisjoint(with: Set(local)))
        XCTAssertEqual(local.count, 15)
    }

    func testTheModelsThatStayOnTheDeviceAreNotHeldToIt() throws {
        // Recording keeps its relationships and its unique id: it is not synced.
        let recording = try entity("Recording")
        XCTAssertFalse(recording.relationships.isEmpty)
    }
}
