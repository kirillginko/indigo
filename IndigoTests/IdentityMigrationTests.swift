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
                schema: Persistence.schema, url: directory.appendingPathComponent(name)))
        return (container, ModelContext(container))
    }

    // MARK: Schema

    func testAV2StoreKeepsItsRecordingIdsUnderTheirNewNameThroughTheMigration() throws {
        let url = directory.appendingPathComponent("v2.store")
        let rid = UUID()
        let v2 = Schema(IndigoSchemaV2.models)
        try autoreleasepool {
            let container = try ModelContainer(
                for: v2, configurations: ModelConfiguration(schema: v2, url: url))
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
            configurations: ModelConfiguration(schema: Persistence.schema, url: url))
        let context = ModelContext(container)

        XCTAssertEqual(try context.fetch(FetchDescriptor<ListeningEvent>()).first?.legacyRecordingID, rid)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DigVisit>()).first?.legacyRecordingID, rid)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DigVisit>()).first?.visits, 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredEdge>()), 1)
    }

    func testNewRowsDoNotRecordALocalRecordingId() throws {
        let (_, context) = try open()
        let recording = try RecordingStore(context: context).upsert(title: "Rev8617", artistName: "Skee Mask")
        let node = MusicNode.recording(recording)

        XCTAssertNil(ListeningEvent(node: node, action: .played).legacyRecordingID)
        XCTAssertNil(DigVisit(node: node).legacyRecordingID)
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

    // MARK: The backfill

    /// What the app wrote before: the key as the node id, and the recording id.
    private func legacyEvent(_ context: ModelContext, key: String, rid: UUID?) -> ListeningEvent {
        let event = ListeningEvent(
            node: MusicNode(kind: .recording, key: key, title: "Unreleased"), action: .played)
        event.legacyRecordingID = rid
        context.insert(event)
        return event
    }

    private func legacyVisit(_ context: ModelContext, key: String, visits: Int, rid: UUID?) -> DigVisit {
        let visit = DigVisit(node: MusicNode(kind: .recording, key: key, title: "Unreleased"))
        visit.visits = visits
        visit.legacyRecordingID = rid
        context.insert(visit)
        return visit
    }

    private func placeholders(_ context: ModelContext) -> (aggregate: Recording, twins: [Recording]) {
        let aggregate = Recording(title: "Unreleased", artistName: "Papo2oo4", status: .identified)
        context.insert(aggregate)
        let twins = [8.0, 278.0, 904.0].map { offset -> Recording in
            let rec = Recording(
                title: "Unreleased", artistName: "Papo2oo4", status: .probable,
                unknownCode: RecordingKey.unknownCode(
                    providerID: "nts", showID: "x/y", heardAt: Date(timeIntervalSince1970: 1_000 + offset),
                    offsetSeconds: offset))
            context.insert(rec)
            return rec
        }
        return (aggregate, twins)
    }

    func testAVisitToAPlaceholderIsFiledUnderThePlaceholdersIdentity() throws {
        let (_, context) = try open()
        let (aggregate, twins) = placeholders(context)
        let key = aggregate.matchKey
        let visit = legacyVisit(context, key: key, visits: 3, rid: twins[0].id)
        let event = legacyEvent(context, key: key, rid: twins[0].id)
        try context.save()

        let report = try IdentityBackfill.run(in: context)

        XCTAssertEqual(visit.nodeID, "recording:\(key)#\(twins[0].unknownCode!)")
        XCTAssertEqual(event.nodeID, visit.nodeID)
        XCTAssertEqual(report.visitsRewritten, 1)
        XCTAssertEqual(report.eventsRewritten, 1)
        XCTAssertEqual(report.mismatches, 0)
        XCTAssertEqual(visit.visits, 3, "the count is untouched")
        XCTAssertEqual(visit.legacyRecordingID, twins[0].id, "the evidence is kept")
    }

    func testARowAlreadyOnTheRightIdentityIsLeftAlone() throws {
        let (_, context) = try open()
        let rec = try RecordingStore(context: context).upsert(title: "Rev8617", artistName: "Skee Mask")
        let visit = legacyVisit(context, key: rec.matchKey, visits: 2, rid: rec.id)
        try context.save()

        let report = try IdentityBackfill.run(in: context)

        XCTAssertEqual(report.visitsRewritten, 0)
        XCTAssertEqual(visit.nodeID, "recording:\(rec.matchKey)")
    }

    func testStepsFollowTheirNodeAndTheBackfillIsRepeatable() throws {
        let (_, context) = try open()
        let (aggregate, twins) = placeholders(context)
        let key = aggregate.matchKey
        _ = legacyVisit(context, key: key, visits: 3, rid: twins[0].id)
        let step = DigStep(from: "artist:papo2oo4", to: "recording:\(key)")
        step.count = 2
        context.insert(step)
        try context.save()

        let first = try IdentityBackfill.run(in: context)

        XCTAssertEqual(first.stepsRewritten, 1)
        XCTAssertEqual(step.toNodeID, "recording:\(key)#\(twins[0].unknownCode!)")
        XCTAssertEqual(step.identity, "artist:papo2oo4→\(step.toNodeID)")
        XCTAssertEqual(try IdentityBackfill.run(in: context), IdentityBackfill.Report())
    }

    func testAStepWhoseNodeMeantSeveralThingsIsLeftAloneAndCounted() throws {
        let (_, context) = try open()
        let (aggregate, twins) = placeholders(context)
        let key = aggregate.matchKey
        _ = legacyEvent(context, key: key, rid: twins[0].id)
        _ = legacyEvent(context, key: key, rid: twins[1].id)
        let step = DigStep(from: "artist:papo2oo4", to: "recording:\(key)")
        context.insert(step)
        try context.save()

        let report = try IdentityBackfill.run(in: context)

        XCTAssertEqual(report.ambiguousSteps, 1)
        XCTAssertEqual(step.toNodeID, "recording:\(key)", "no guess")
    }

    func testARowWhoseRecordingIsGoneKeepsItsKeyAndIsCounted() throws {
        let (_, context) = try open()
        let visit = legacyVisit(context, key: "gone gone", visits: 5, rid: UUID())
        let event = legacyEvent(context, key: "gone gone", rid: UUID())
        try context.save()

        let report = try IdentityBackfill.run(in: context)

        XCTAssertEqual(report.unresolved, 2)
        XCTAssertEqual(visit.nodeID, "recording:gone gone")
        XCTAssertEqual(event.nodeKey, "gone gone")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DigVisit>()), 1, "history is never deleted")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ListeningEvent>()), 1)
    }

    func testTwoVisitsThatLandOnOneNodeAreFolded() throws {
        let (_, context) = try open()
        let (aggregate, twins) = placeholders(context)
        let key = aggregate.matchKey
        // One already under the identity, one still under the key.
        let node = MusicNode.recording(twins[0])
        let existing = DigVisit(node: node)
        existing.visits = 4
        context.insert(existing)
        _ = legacyVisit(context, key: key, visits: 3, rid: twins[0].id)
        try context.save()

        let report = try IdentityBackfill.run(in: context)

        XCTAssertEqual(report.merged, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DigVisit>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DigVisit>()).first?.visits, 7)
    }

    // MARK: The point of the step

    /// Erase every persisted recording id. The history has to open the same
    /// recordings from its nodes alone.
    func testTheHistoryOpensTheSameRecordingsWithEveryRecordingIdErased() throws {
        let (_, context) = try open()
        let store = RecordingStore(context: context)
        let (aggregate, twins) = placeholders(context)
        let plain = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let key = aggregate.matchKey

        var expected: [String: UUID] = [:]   // node id after the backfill -> recording
        // Events can repeat a key; a visit is one row per node id, so a shared
        // key held one visit, which is how the real store came to have one.
        for (rec, k) in [(twins[0], key), (twins[2], key), (plain, plain.matchKey)] {
            _ = legacyEvent(context, key: k, rid: rec.id)
        }
        _ = legacyVisit(context, key: key, visits: 3, rid: twins[0].id)
        _ = legacyVisit(context, key: plain.matchKey, visits: 1, rid: plain.id)
        try context.save()
        try IdentityBackfill.run(in: context)
        for event in try context.fetch(FetchDescriptor<ListeningEvent>()) {
            expected[event.nodeID] = event.legacyRecordingID
        }

        // Erase.
        for event in try context.fetch(FetchDescriptor<ListeningEvent>()) { event.legacyRecordingID = nil }
        for visit in try context.fetch(FetchDescriptor<DigVisit>()) { visit.legacyRecordingID = nil }
        try context.save()

        var opened = 0
        for visit in try context.fetch(FetchDescriptor<DigVisit>()) {
            let page = try XCTUnwrap(visit.node.destination)
            guard case .digRecording(let identity, _) = page else { return XCTFail("\(page)") }
            let recording = try XCTUnwrap(store.recording(identity: identity), visit.nodeID)
            XCTAssertEqual(recording.id, expected[visit.nodeID], visit.nodeID)
            opened += 1
        }
        XCTAssertEqual(opened, 2)
        XCTAssertEqual(Set(expected.values).count, 3, "the two placeholders and the plain one stayed three")

        // And every event, not only the visits.
        for event in try context.fetch(FetchDescriptor<ListeningEvent>()) {
            guard case .digRecording(let identity, _)? = event.node.destination else {
                return XCTFail(event.nodeID)
            }
            XCTAssertEqual(store.recording(identity: identity)?.id, expected[event.nodeID], event.nodeID)
        }
    }
}
