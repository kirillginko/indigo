//
//  BandcampRepairTests.swift
//  IndigoTests
//
//  Bandcamp's publisher is whoever owns the page, so an artist selling their
//  own music was stored as their own record label — most of Bandcamp. Reading
//  through `imprint` hides that; this is the pass that stops it being true.
//
//  On disk rather than in memory. The repair asks the store for rows that
//  still name a publisher, and an in-memory container answers a `#Predicate`
//  by running it as Swift — which is not the thing that has to survive. See
//  `StorePredicateTests`.
//

import XCTest
import SwiftData
@testable import Indigo

final class BandcampRepairTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("indigo-bandcamp-\(UUID().uuidString)")
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

    @discardableResult
    private func release(_ title: String, artist: String, label: String?) -> BandcampRelease {
        let record = BandcampRelease(
            urlString: "https://\(artist.filter { !$0.isWhitespace }).bandcamp.com/album/\(title)",
            title: title, artistName: artist, labelName: label
        )
        context.insert(record)
        return record
    }

    private func label(of title: String) throws -> String? {
        let all = try context.fetch(FetchDescriptor<BandcampRelease>())
        return all.first { $0.title == title }?.labelName
    }

    func testAnArtistStoredAsTheirOwnLabelIsMended() async throws {
        release("Quiet Storm", artist: "Space Afrika", label: "Space Afrika")
        release("The Nothings Of The North", artist: "Ametsub", label: "Ametsub")
        release("Untrue", artist: "Burial", label: "Hyperdub")
        try context.save()

        let mended = await BandcampEnricher.repairSelfPublishedLabels(in: container)
        XCTAssertEqual(mended, 2)

        XCTAssertNil(try label(of: "Quiet Storm"))
        XCTAssertNil(try label(of: "The Nothings Of The North"))
        // A real label is left exactly where it was.
        XCTAssertEqual(try label(of: "Untrue"), "Hyperdub")
    }

    func testRunningItAgainFindsNothingToDo() async throws {
        release("Quiet Storm", artist: "Space Afrika", label: "Space Afrika")
        try context.save()

        let first = await BandcampEnricher.repairSelfPublishedLabels(in: container)
        XCTAssertEqual(first, 1)
        // The whole reason it needs no "already done" marker: once the rows
        // are cleared they fall out of the query that finds them.
        let again = await BandcampEnricher.repairSelfPublishedLabels(in: container)
        XCTAssertEqual(again, 0)
    }

    func testAnEmptyCacheIsNotAnError() async throws {
        let mended = await BandcampEnricher.repairSelfPublishedLabels(in: container)
        XCTAssertEqual(mended, 0)
    }

    func testTheSpellingOnTheTwoHalvesOfAPageNeedNotMatch() async throws {
        release("Kaleidoscope", artist: "The Circling Sun", label: "THE CIRCLING SUN")
        try context.save()

        let mended = await BandcampEnricher.repairSelfPublishedLabels(in: container)
        XCTAssertEqual(mended, 1)
        XCTAssertNil(try label(of: "Kaleidoscope"))
    }

    func testARowWithNoPublisherIsNotTouched() async throws {
        release("Unsigned", artist: "Somebody", label: nil)
        try context.save()
        let mended = await BandcampEnricher.repairSelfPublishedLabels(in: container)
        XCTAssertEqual(mended, 0)
    }
}
