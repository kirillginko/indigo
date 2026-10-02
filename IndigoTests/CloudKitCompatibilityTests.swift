//
//  CloudKitCompatibilityTests.swift
//  IndigoTests
//
//  What CloudKit will not store, checked on the models that are going to be
//  synced: no unique constraints, and every property either optional or
//  carrying a default. Relationships are not allowed to cross into a synced
//  store, and exactly one remains.
//
//  `CrateItem.legacyRecording` is the named exception. It points at a
//  `Recording`, which stays on the device, so it cannot be synced and cannot
//  stay once `CrateItem` moves into the synced store. It is here because the
//  one-time backfill reads it, and step 7 removes it with the split. Do not
//  initialise the CloudKit schema while it is on this list: the test that
//  names it fails the moment the list is empty and the property is not, and is
//  meant to be edited then, not before.
//

import XCTest
import SwiftData
@testable import Indigo

final class CloudKitCompatibilityTests: XCTestCase {
    private let synced = ["CrateItem", "ListeningEvent", "DigVisit", "DigStep"]

    /// Relationships that are known not to be synced yet, by `Entity.property`.
    private let namedRelationshipExceptions: Set<String> = ["CrateItem.legacyRecording"]

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

    func testTheOnlyRelationshipOnASyncedModelIsTheNamedException() throws {
        var found = Set<String>()
        for name in synced {
            for relationship in try entity(name).relationships { found.insert("\(name).\(relationship.name)") }
        }
        XCTAssertEqual(found, namedRelationshipExceptions,
                       "A synced model gained or lost a relationship; step 7 empties this list")
    }

    func testTheModelsThatStayOnTheDeviceAreNotHeldToIt() throws {
        // Recording keeps its relationships and its unique id: it is not synced.
        let recording = try entity("Recording")
        XCTAssertFalse(recording.relationships.isEmpty)
    }
}
