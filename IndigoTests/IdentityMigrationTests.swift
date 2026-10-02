//
//  IdentityMigrationTests.swift
//  IndigoTests
//
//  Step 4. The listening log and the dig history stop keeping a local
//  `Recording.id`, and what recording an encounter was with is its node's key.
//
//  On disk throughout: the rewrites are fetches and the checks are fetches, and
//  a store in memory does not reproduce how a fetch sees an unsaved edit.
//

import XCTest
import SwiftData
@testable import Indigo

final class IdentityMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdentityMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func open(_ name: String = "identity.store") throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(
            for: Persistence.schema, migrationPlan: IndigoMigrationPlan.self,
            configurations: ModelConfiguration(
                schema: Persistence.schema, url: directory.appendingPathComponent(name), cloudKitDatabase: .none))
        return (container, ModelContext(container))
    }

    // MARK: Schema

    func testAV2StoreKeepsItsRecordingIdsUnderTheirNewNameThroughTheMigration() throws {
        let url = directory.appendingPathComponent("v2.store")
        let rid = UUID()
        let v2 = Schema(IndigoSchemaV2.models)
        try autoreleasepool {
            let container = try ModelContainer(
                for: v2, configurations: ModelConfiguration(schema: v2, url: url, cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.insert(IndigoSchemaV2.ListeningEvent(
                nodeKind: "recording", nodeKey: "boards of canadaaquarius", title: "Aquarius", recordingID: rid))
            context.insert(IndigoSchemaV2.DigVisit(
                kind: "recording", key: "boards of canadaaquarius", title: "Aquarius", visits: 3, recordingID: rid))
            context.insert(IndigoSchemaV2.StoredEdge(id: "e1", toKey: "x", toRecordingID: rid))
            try context.save()
        }

        let container = try ModelContainer(
            for: Persistence.schema, migrationPlan: IndigoMigrationPlan.self,
            configurations: ModelConfiguration(schema: Persistence.schema, url: url, cloudKitDatabase: .none))
        let context = ModelContext(container)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ListeningEvent>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DigVisit>()).first?.visits, 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredEdge>()), 1)
    }

    // MARK: The node is the identity

    func testANodeCarriesTheIdentityAndNeverALocalUUID() throws {
        let (_, context) = try open()
        let store = RecordingStore(context: context)
        let named = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let placeholder = Recording(
            title: "Unreleased", artistName: "Papo2oo4", status: .probable, unknownCode: "EAE1B")
        context.insert(placeholder)
        let unnamed = try store.createUnknown(
            providerID: "nts", showID: "a/b", heardAt: Date(), offsetSeconds: 5)
        let untitled = Recording(status: .unknown)
        context.insert(untitled)

        for recording in [named, placeholder, unnamed, untitled] {
            let node = MusicNode.recording(recording)
            XCTAssertEqual(RecordingIdentity(node: node), RecordingIdentity(recording))
            XCTAssertFalse(node.key.contains(recording.id.uuidString), "\(node.key)")
        }
        XCTAssertEqual(MusicNode.recording(placeholder).key, placeholder.matchKey + "#EAE1B")
        XCTAssertEqual(MusicNode.recording(placeholder).kind, .recording)
        XCTAssertEqual(MusicNode.recording(unnamed).kind, .unknownRecording)
        XCTAssertNotNil(untitled.unknownCode, "a recording with no key is given a code of its own")
    }

    func testANodeBuiltFromAnIdentityIsTheNodeBuiltFromTheRecording() throws {
        let (_, context) = try open()
        let rec = Recording(title: "Unreleased", artistName: "Papo2oo4", status: .probable, unknownCode: "EAE1B")
        context.insert(rec)
        let direct = MusicNode.recording(rec)
        let fromIdentity = MusicNode.recording(
            identity: RecordingIdentity(rec), title: rec.displayTitle, subtitle: rec.displayArtist)
        XCTAssertEqual(direct.id, fromIdentity.id)
        XCTAssertEqual(direct.kind, fromIdentity.kind)
    }
}
