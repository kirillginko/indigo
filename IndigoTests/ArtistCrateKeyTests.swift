//
//  ArtistCrateKeyTests.swift
//  IndigoTests
//
//  An artist crated before MusicBrainz answered is kept by name; the page
//  that later knows their MBID must still say they are crated, and uncrating
//  must take that row away.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ArtistCrateKeyTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private func crateByName(_ name: String) {
        CrateService(context: context).toggle(
            dig: .artist, identifier: RecordingKey.normalizeArtist(name), providerID: "dig.artist.name",
            title: name, subtitle: "Artist", artworkURL: nil)
    }

    func testAnArtistCratedByNameIsCratedOnThePageThatKnowsTheirMBID() throws {
        let crate = CrateService(context: context)
        let before = ArtistProfile.placeholder(name: "Dean Blunt", mbid: nil)
        let byName = ArtistDigView.crateKeys(before, opened: "Dean Blunt", alsoCreditedAs: [])
        crate.toggle(dig: .artist, identifier: byName[0].identifier, providerID: byName[0].providerID,
                     title: "Dean Blunt", subtitle: "Artist", artworkURL: nil)

        let after = ArtistProfile.placeholder(name: "Dean Blunt", mbid: "1f3b0e58-0000-0000-0000-000000000000")
        let keys = ArtistDigView.crateKeys(after, opened: "Blunt", alsoCreditedAs: [])
        XCTAssertEqual(keys.first?.providerID, "dig.artist.mbid", "A new row would take the MBID")
        let kept = try XCTUnwrap(crate.keptKey(dig: .artist, among: keys), "Still crated")
        XCTAssertEqual(kept.identifier, "dean blunt")

        crate.toggle(dig: .artist, identifier: kept.identifier, providerID: kept.providerID,
                     title: "Dean Blunt", subtitle: "Artist", artworkURL: nil)
        XCTAssertNil(crate.keptKey(dig: .artist, among: keys), "Uncrating removes the row it was kept under")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CrateItem>()), 0)
    }

    /// Crated, long ago, under the tracklist's spelling. The page Prefuse73
    /// opens is Prefuse 73's, which answers to that spelling too: crated, and
    /// uncrating there removes the row that was kept.
    func testAHistoricalCrateRowUnderAVerifiedSpellingCountsOnTheEntrysPage() throws {
        crateByName("Prefuse73")
        let crate = CrateService(context: context)
        let page = ArtistProfile.placeholder(name: "Prefuse 73", mbid: "b3c7e3f9-0000-0000-0000-000000000000")
        let keys = ArtistDigView.crateKeys(page, opened: "Prefuse 73", alsoCreditedAs: ["Prefuse73"])

        let kept = try XCTUnwrap(crate.keptKey(dig: .artist, among: keys))
        XCTAssertEqual(kept.identifier, "prefuse73", "Found under the key it was written with")
        crate.toggle(dig: .artist, identifier: kept.identifier, providerID: kept.providerID,
                     title: "Prefuse 73", subtitle: "Artist", artworkURL: nil)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CrateItem>()), 0)
    }

    /// A name the page does not answer to is somebody else's crate row.
    func testANameThePageDoesNotAnswerToIsNotItsCrateRow() throws {
        crateByName("Blunt")
        let page = ArtistProfile.placeholder(name: "Dean Blunt", mbid: nil)
        let keys = ArtistDigView.crateKeys(page, opened: "Dean Blunt", alsoCreditedAs: [])
        XCTAssertNil(CrateService(context: context).keptKey(dig: .artist, among: keys))
    }

    /// Crating adds one row and leaves the history it found alone.
    func testCratingFromTheEntrysPageWritesOneRowUnderItsFirstKey() throws {
        let crate = CrateService(context: context)
        let page = ArtistProfile.placeholder(name: "Prefuse 73", mbid: "b3c7e3f9-0000-0000-0000-000000000000")
        let keys = ArtistDigView.crateKeys(page, opened: "Prefuse73", alsoCreditedAs: ["Prefuse73"])
        XCTAssertNil(crate.keptKey(dig: .artist, among: keys))
        crate.toggle(dig: .artist, identifier: keys[0].identifier, providerID: keys[0].providerID,
                     title: "Prefuse 73", subtitle: "Artist", artworkURL: nil)
        let rows = try context.fetch(FetchDescriptor<CrateItem>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(crate.keptKey(dig: .artist, among: keys)?.providerID, "dig.artist.mbid")
    }
}
