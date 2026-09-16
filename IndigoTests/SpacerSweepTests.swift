//
//  SpacerSweepTests.swift
//  IndigoTests
//
//  Clearing the Discogs "no picture" pictures out of rows already written.
//
//  Run against a real SQLite store rather than an in-memory one. The sweep
//  itself takes care to avoid `#Predicate` — see the comment in `SpacerSweep`
//  and `StorePredicateTests` — and a test on a store that answers predicates
//  in Swift would not notice if that care were removed.
//

import XCTest
import SwiftData
@testable import Indigo

final class SpacerSweepTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var directory: URL!

    private let spacer = "https://st.discogs.com/78792c02e02592289e1013a65802bc8f2fce8609/images/spacer.gif"
    private let real = "https://i.discogs.com/abc/rx-300-600.jpeg"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("indigo-spacer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(
            schema: Persistence.schema, url: directory.appendingPathComponent("store.sqlite")
        )
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func artist(_ name: String, image: String?, thumbnail: String? = nil) -> DiscogsArtist {
        let record = DiscogsArtist(nameKey: RecordingKey.normalizeArtist(name), discogsID: .random(in: 1...9999), name: name)
        record.imageURLString = image
        record.thumbnailURLString = thumbnail ?? image
        context.insert(record)
        return record
    }

    func testASpacerIsClearedAndARealPictureIsLeftAlone() async throws {
        let blank = artist("Gordini", image: spacer)
        let pictured = artist("Kate NV", image: real)
        try context.save()

        let swept = await SpacerSweep.run(in: container)
        XCTAssertEqual(swept.artists, 1)

        context = ModelContext(container)
        let all = try context.fetch(FetchDescriptor<DiscogsArtist>())
        let gordini = try XCTUnwrap(all.first { $0.name == "Gordini" })
        let kate = try XCTUnwrap(all.first { $0.name == "Kate NV" })
        XCTAssertNil(gordini.imageURLString, "The spacer should be gone from the row itself")
        XCTAssertNil(gordini.thumbnailURLString)
        XCTAssertEqual(kate.imageURLString, real, "A real picture must survive the sweep")
        _ = (blank, pictured)
    }

    /// A settled miss stays settled: turning these back into open questions
    /// would refill a queue paced at one request every second and a half.
    func testAPortraitLosesItsSpacerButKeepsItsVerdict() async throws {
        let portrait = ArtistPortrait(nameKey: "gordini", name: "Gordini")
        portrait.imageURLString = spacer
        portrait.lookupFailed = true
        context.insert(portrait)
        try context.save()

        let swept = await SpacerSweep.run(in: container)
        XCTAssertEqual(swept.portraits, 1)

        context = ModelContext(container)
        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<ArtistPortrait>()).first)
        XCTAssertNil(stored.imageURLString)
        XCTAssertTrue(stored.lookupFailed, "A spacer is Discogs saying it has no photograph")
    }

    /// It runs on every launch, so the second one must find nothing.
    func testASweptStoreIsNotSweptAgain() async throws {
        _ = artist("Gordini", image: spacer)
        try context.save()

        let first = await SpacerSweep.run(in: container)
        XCTAssertEqual(first.artists, 1)
        let again = await SpacerSweep.run(in: container)
        XCTAssertTrue(again.isEmpty, "A swept store must be left alone")
    }

    /// The functional half, and the one that actually mattered: an artist
    /// holding a spacer counted as somebody who already had a picture, so the
    /// background fill skipped them for good.
    func testAnArtistHoldingASpacerIsStillOfferedAPortraitLookup() async throws {
        let subject = artist("Kate NV", image: real)
        subject.collaboratorNames = ["Gordini"]
        _ = artist("Gordini", image: spacer)
        try context.save()

        let worker = DigWorker(modelContainer: container)
        let pending = await worker.pendingPortraits()
        // `pendingPortraits` hands back names as they are spelled, not keys.
        XCTAssertTrue(
            pending.contains("Gordini"),
            "An artist whose only picture is a spacer still needs looking up"
        )
    }
}
