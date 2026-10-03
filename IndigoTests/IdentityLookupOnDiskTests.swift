//
//  IdentityLookupOnDiskTests.swift
//  IndigoTests
//
//  The lookups by identity, run against a store on disk, where a fetch is a
//  query and unsaved edits are merged in afterwards. An in-memory store has no
//  such two steps, and this is the difference that hid a failure: a copy of a
//  real store resolved 47 of its 48 crate rows, and the 48th was the one whose
//  recording a repair had just changed and not yet saved.
//

import XCTest
import SwiftData
@testable import Indigo

final class IdentityLookupOnDiskTests: XCTestCase {
    private var directory: URL!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdentityLookupOnDiskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try ModelContainer(
            for: Persistence.schema,
            configurations: ModelConfiguration(
                schema: Persistence.schema, url: directory.appendingPathComponent("lookup.store"), cloudKitDatabase: .none))
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func make(_ status: IdentificationStatus, code: String?) throws -> Recording {
        let rec = Recording(title: "Unreleased", artistName: "Papo2oo4", status: status, unknownCode: code)
        context.insert(rec)
        try context.save()
        return rec
    }

    func testACodedRecordingAndItsCrateRowFindEachOther() throws {
        let aggregate = try make(.identified, code: nil)
        let placeholder = try make(.probable, code: "EAE1B")
        let other = try make(.probable, code: "236A8")
        let crate = CrateService(context: context)
        let item = try XCTUnwrap(crate.add(recording: placeholder))
        try context.save()

        let resolver = CrateRecordings(context: context)
        XCTAssertEqual(resolver.recording(for: item)?.id, placeholder.id)
        XCTAssertEqual(resolver.crateItem(for: placeholder)?.id, item.id)
        XCTAssertEqual(crate.item(for: placeholder)?.id, item.id)
        XCTAssertEqual(resolver.recordings(for: [item])[item.id]?.id, placeholder.id)

        XCTAssertNil(crate.item(for: aggregate), "the key-only recording was not crated")
        XCTAssertNil(crate.item(for: other))
        XCTAssertTrue(crate.contains(recording: placeholder))
        XCTAssertFalse(crate.contains(recording: aggregate))
        XCTAssertFalse(crate.contains(recording: other))
    }

    func testAKeyOnlyRowFindsTheKeyOnlyRecordingNotAPlaceholder() throws {
        let placeholder = try make(.probable, code: "EAE1B")
        let aggregate = try make(.identified, code: nil)
        let crate = CrateService(context: context)
        let item = try XCTUnwrap(crate.add(recording: aggregate))
        try context.save()

        XCTAssertEqual(CrateRecordings(context: context).recording(for: item)?.id, aggregate.id)
        XCTAssertNil(crate.item(for: placeholder))
    }

    func testAnUpsertDoesNotHijackAPlaceholderOnDisk() throws {
        let placeholder = try make(.probable, code: "EAE1B")

        let made = try RecordingStore(context: context).upsert(title: "Unreleased", artistName: "Papo2oo4")

        XCTAssertNotEqual(made.id, placeholder.id)
        XCTAssertNil(made.unknownCode)
        XCTAssertEqual(placeholder.unknownCode, "EAE1B")
    }

    func testIdentityCollisionsAreFoundOnDisk() throws {
        _ = try make(.identified, code: "EAE1B")
        _ = try make(.probable, code: "EAE1B")
        XCTAssertEqual(RecordingStore(context: context).identityCollisions().count, 1)
        RecordingStore(context: context).repairIdentities()
        XCTAssertTrue(RecordingStore(context: context).identityCollisions().isEmpty)
    }

}
