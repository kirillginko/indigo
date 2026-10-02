//
//  SchemaVersioningTests.swift
//  IndigoTests
//
//  Step 1 of the iCloud plan. The schema is versioned and opens through a
//  migration plan; what is pinned here is that this changes nothing for the
//  store somebody already has.
//
//  On disk, not in memory: the store a listener has was written by an
//  unversioned container, and only a file can say whether the versioned one
//  reads it.
//

import XCTest
import SwiftData
@testable import Indigo

final class SchemaVersioningTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaVersioningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheCurrentSchemaIsVersionSeven() {
        XCTAssertEqual(Persistence.schema.version, Schema.Version(7, 0, 0))
        XCTAssertEqual(IndigoMigrationPlan.schemas.count, 7)
        XCTAssertEqual(IndigoMigrationPlan.stages.count, 6)
    }

    func testEveryModelTheAppStoresIsInTheVersionedSchema() {
        let names = Set(IndigoSchemaCurrent.models.map { String(describing: $0) })
        XCTAssertEqual(names.count, 20)
        for model in ["CrateItem", "ListeningEvent", "DigVisit", "DigStep", "Recording"] {
            XCTAssertTrue(names.contains(model), "\(model) missing from SchemaV1")
        }
    }

    /// The store on a listener's disk was written with no version at all.
    func testAStoreWrittenWithoutAVersionOpensThroughThePlanWithItsRows() throws {
        let url = directory.appendingPathComponent("legacy.store")
        let unversioned = Schema(IndigoSchemaCurrent.models)

        do {
            let legacy = try ModelContainer(
                for: unversioned,
                configurations: ModelConfiguration(schema: unversioned, url: url, cloudKitDatabase: .none))
            let context = ModelContext(legacy)
            let visit = DigVisit(node: MusicNode.label("Ilian Tape"))
            visit.visits = 3
            context.insert(visit)
            try context.save()
        }

        let versioned = try ModelContainer(
            for: Persistence.schema,
            migrationPlan: IndigoMigrationPlan.self,
            configurations: ModelConfiguration(schema: Persistence.schema, url: url, cloudKitDatabase: .none))
        let rows = try ModelContext(versioned).fetch(FetchDescriptor<DigVisit>())

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.visits, 3)
        XCTAssertEqual(rows.first?.title, "Ilian Tape")
    }

    /// And the versioned store reopens as itself, which is every launch after
    /// the first.
    func testAVersionedStoreReopensWithItsRows() throws {
        let url = directory.appendingPathComponent("versioned.store")

        func open() throws -> ModelContainer {
            try ModelContainer(
                for: Persistence.schema,
                migrationPlan: IndigoMigrationPlan.self,
                configurations: ModelConfiguration(schema: Persistence.schema, url: url, cloudKitDatabase: .none))
        }

        do {
            let context = ModelContext(try open())
            context.insert(DigVisit(node: MusicNode.label("Hessle Audio")))
            try context.save()
        }

        let rows = try ModelContext(try open()).fetch(FetchDescriptor<DigVisit>())
        XCTAssertEqual(rows.map(\.title), ["Hessle Audio"])
    }
}

// MARK: - V1 -> V2: the crate keeps its own snapshot

extension SchemaVersioningTests {
    /// A crate row written when it still pointed at a `Recording`. Read through
    /// the plan that stops at V5 -- how a copy of the old store is brought to
    /// the last shape that held the bridge -- it keeps the relationship. Through
    /// the plan to the current version it keeps the row and loses the bridge,
    /// which is why the old store itself is never opened that way.
    func testAV1CrateRowKeepsItsRecordingOnlyThroughTheLegacyPlan() throws {
        let url = directory.appendingPathComponent("v1-crate.store")
        let v1 = Schema(IndigoSchemaV1.models)
        try autoreleasepool {
            let container = try ModelContainer(
                for: v1, configurations: ModelConfiguration(schema: v1, url: url, cloudKitDatabase: .none))
            let context = ModelContext(container)
            let recording = IndigoLegacy.Recording(title: "Rev8617", artistName: "Skee Mask")
            context.insert(recording)
            context.insert(IndigoSchemaV1.CrateItem(recording: recording))
            try context.save()
        }
        let legacyCopy = directory.appendingPathComponent("v1-crate-legacy.store")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.copyItem(
                at: URL(fileURLWithPath: url.path + suffix), to: URL(fileURLWithPath: legacyCopy.path + suffix))
        }

        let v5 = Schema(versionedSchema: IndigoSchemaV5.self)
        let legacy = try ModelContainer(
            for: v5, migrationPlan: IndigoLegacyMigrationPlan.self,
            configurations: ModelConfiguration(schema: v5, url: legacyCopy, cloudKitDatabase: .none))
        let old = try ModelContext(legacy).fetch(FetchDescriptor<IndigoSchemaV5.CrateItem>())
        XCTAssertEqual(old.count, 1)
        XCTAssertEqual(old.first?.legacyRecording?.title, "Rev8617")

        let container = try ModelContainer(
            for: Persistence.schema, migrationPlan: IndigoMigrationPlan.self,
            configurations: ModelConfiguration(schema: Persistence.schema, url: url, cloudKitDatabase: .none))
        let rows = try ModelContext(container).fetch(FetchDescriptor<CrateItem>())
        XCTAssertEqual(rows.count, 1, "the row survives; the bridge does not")
        XCTAssertEqual(rows.first?.kind, .recording)
    }
}

// MARK: - V4 -> V5: nothing refuses a second row, and a row can arrive without a field

extension SchemaVersioningTests {
    func testAV4StoreKeepsEveryRowThroughTheMigrationAndThenAllowsACopy() throws {
        let url = directory.appendingPathComponent("v4.store")
        let v4 = Schema(IndigoSchemaV4.models)
        let id = UUID()
        try autoreleasepool {
            let container = try ModelContainer(for: v4, configurations: ModelConfiguration(schema: v4, url: url, cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.insert(IndigoSchemaV4.CrateItem(id: id, kindRaw: "broadcast", addedAt: Date(timeIntervalSince1970: 7)))
            context.insert(IndigoSchemaV4.ListeningEvent(id: id, nodeKey: "skee mask", seconds: 90))
            context.insert(IndigoSchemaV4.DigVisit(nodeID: "artist:skee mask", visits: 4))
            context.insert(IndigoSchemaV4.DigStep(identity: "artist:a→artist:b", count: 3))
            try context.save()
        }

        let container = try ModelContainer(
            for: Persistence.schema, migrationPlan: IndigoMigrationPlan.self,
            configurations: ModelConfiguration(schema: Persistence.schema, url: url, cloudKitDatabase: .none))
        let context = ModelContext(container)

        XCTAssertEqual(try context.fetch(FetchDescriptor<CrateItem>()).map(\.id), [id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ListeningEvent>()).first?.seconds, 90)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DigVisit>()).first?.visits, 4)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DigStep>()).first?.count, 3)

        // And the constraint is gone: a second row with the id is a second row.
        let copy = CrateItem(providerID: "nts", showID: "s", showTitle: "S", showSubtitle: nil, artworkURL: nil,
                             playbackURL: nil, embedProvider: nil, isLiveStream: false)
        copy.id = id
        context.insert(copy)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CrateItem>()), 2)
    }
}
