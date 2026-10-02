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

    func testTheCurrentSchemaIsVersionThreeAfterTwoAndOne() {
        XCTAssertEqual(Persistence.schema.version, Schema.Version(3, 0, 0))
        XCTAssertEqual(IndigoMigrationPlan.schemas.count, 3)
        XCTAssertEqual(IndigoMigrationPlan.stages.count, 2)
    }

    func testEveryModelTheAppStoresIsInTheVersionedSchema() {
        let names = Set(IndigoSchemaV3.models.map { String(describing: $0) })
        XCTAssertEqual(names.count, 19)
        for model in ["CrateItem", "ListeningEvent", "DigVisit", "DigStep", "Recording"] {
            XCTAssertTrue(names.contains(model), "\(model) missing from SchemaV1")
        }
    }

    /// The store on a listener's disk was written with no version at all.
    func testAStoreWrittenWithoutAVersionOpensThroughThePlanWithItsRows() throws {
        let url = directory.appendingPathComponent("legacy.store")
        let unversioned = Schema(IndigoSchemaV3.models)

        do {
            let legacy = try ModelContainer(
                for: unversioned,
                configurations: ModelConfiguration(schema: unversioned, url: url))
            let context = ModelContext(legacy)
            let visit = DigVisit(node: MusicNode.label("Ilian Tape"))
            visit.visits = 3
            context.insert(visit)
            try context.save()
        }

        let versioned = try ModelContainer(
            for: Persistence.schema,
            migrationPlan: IndigoMigrationPlan.self,
            configurations: ModelConfiguration(schema: Persistence.schema, url: url))
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
                configurations: ModelConfiguration(schema: Persistence.schema, url: url))
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
    /// A crate row written when it still pointed at a `Recording`. It has to
    /// come through the plan with its relationship intact -- that is what the
    /// backfill reads -- and with the new fields empty until it has run.
    func testAV1CrateRowKeepsItsRecordingThroughTheMigration() throws {
        let url = directory.appendingPathComponent("v1-crate.store")
        let v1 = Schema(IndigoSchemaV1.models)

        try autoreleasepool {
            let container = try ModelContainer(
                for: v1, configurations: ModelConfiguration(schema: v1, url: url))
            let context = ModelContext(container)
            let recording = Recording(title: "Rev8617", artistName: "Skee Mask", status: .identified)
            context.insert(recording)
            context.insert(IndigoSchemaV1.CrateItem(recording: recording))
            try context.save()
        }

        let container = try ModelContainer(
            for: Persistence.schema, migrationPlan: IndigoMigrationPlan.self,
            configurations: ModelConfiguration(schema: Persistence.schema, url: url))
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<CrateItem>())

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.legacyRecording?.title, "Rev8617")
        XCTAssertEqual(rows.first?.kind, .recording)
        XCTAssertFalse(rows.first?.hasRecordingSnapshot ?? true, "nothing is filled until the backfill runs")

        let report = try CrateSnapshot.backfill(in: context)
        XCTAssertEqual(report, CrateSnapshot.BackfillReport(filled: 1, dangling: 0, repaired: 0, mismatches: 0, collisions: 0))
        XCTAssertEqual(rows.first?.artistName, "Skee Mask")
        XCTAssertEqual(rows.first?.matchKey, rows.first?.legacyRecording?.matchKey)
    }
}
