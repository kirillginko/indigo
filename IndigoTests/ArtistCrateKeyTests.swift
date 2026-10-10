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
    func testAnArtistCratedByNameIsCratedOnThePageThatKnowsTheirMBID() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)
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
}
