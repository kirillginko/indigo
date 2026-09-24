//
//  SpacerImageTests.swift
//  IndigoTests
//
//  Discogs answers "there is no picture" with a picture.
//
//  An artist or record with no image comes back carrying `spacer.gif` on what
//  looks like its own address — `st.discogs.com/<hash>/images/spacer.gif` — so
//  two artists with no photograph get two different-looking URLs. It is a
//  transparent one-pixel image and it loads perfectly, which is exactly the
//  problem: a tile holding one is not empty, so it never reaches its
//  placeholder, and the listener gets a blank grey square where a portrait or
//  a mosaic belongs.
//
//  Found by reading the live store, where 22 artists shared one such address
//  and 15 another. `DiscogsClient.usableImage` could always spot them; it was
//  simply not asked on the paths that mattered.
//

import XCTest
import SwiftData
@testable import Indigo

final class SpacerImageTests: XCTestCase {
    private let spacer = "https://st.discogs.com/be5e3ab96f7a7387ef5f7d4ecf66094c0cd5dc60/images/spacer.gif"
    private let real = "https://i.discogs.com/abc/rx-300-600.jpeg"

    func testAnArtistHoldingASpacerHasNoPicture() {
        let artist = DiscogsArtist(nameKey: "snkls", discogsID: 1, name: "SNKLS")
        artist.imageURLString = spacer
        artist.thumbnailURLString = spacer
        XCTAssertNil(artist.imageURL, "A spacer is not a photograph")
        XCTAssertNil(artist.thumbnailURL)
    }

    func testARealPictureStillComesThrough() {
        let artist = DiscogsArtist(nameKey: "kate-nv", discogsID: 2, name: "Kate NV")
        artist.imageURLString = real
        artist.thumbnailURLString = real
        XCTAssertNotNil(artist.imageURL)
        XCTAssertNotNil(artist.thumbnailURL)
    }

    /// Rows written before the filter existed are still in everybody's store,
    /// so the read has to cope rather than relying on a migration.
    func testAPortraitRowWrittenBeforeTheFixReadsAsAMiss() {
        let portrait = ArtistPortrait(nameKey: "gordini", name: "Gordini")
        portrait.imageURLString = spacer
        XCTAssertNil(portrait.imageURL)
    }

    func testARecordHoldingASpacerHasNoSleeve() {
        let record = DiscogsReleaseRecord(discogsID: 99, title: "Crapy Toubab EP")
        record.imageURLString = spacer
        record.thumbnailURLString = spacer
        XCTAssertNil(record.imageURL)
        XCTAssertNil(record.thumbnailURL)
    }

    /// SNKLS, on the For You page: a label neighbour with no photograph was
    /// stored with its spacer, so the card drew an empty square.
    func testANeighbourHoldingASpacerFallsThroughToTheNextList() {
        let artist = DiscogsArtist(nameKey: "kate-nv", discogsID: 2, name: "Kate NV")
        artist.labelNeighbourNames = ["SNKLS"]
        artist.labelNeighbourImageURLStrings = [spacer]
        XCTAssertNil(artist.neighbourImageURL(for: "SNKLS"))
        artist.styleNeighbourNames = ["SNKLS"]
        artist.styleNeighbourImageURLStrings = [real]
        XCTAssertEqual(artist.neighbourImageURL(for: "SNKLS")?.absoluteString, real)
    }

    /// The last line: whatever path hands a tile a spacer, it is not loaded.
    @MainActor
    func testATileRefusesASpacer() {
        XCTAssertNil(ArtworkView.usable(URL(string: spacer)))
        XCTAssertNotNil(ArtworkView.usable(URL(string: real)))
    }

    /// Two crated tracks in the live store held one, and the crate row drew
    /// nothing at all where the mosaic belongs.
    func testACrateRowHoldingASpacerHasNoPicture() {
        let kept = CrateItem(
            digKind: .release, providerID: "dig.release.discogs", entityID: "1",
            title: "Untitled", subtitle: nil, artworkURL: URL(string: spacer)
        )
        XCTAssertNil(kept.artworkURL)
        kept.artworkURLString = real
        XCTAssertNotNil(kept.artworkURL)
    }

    /// Every spacer seen in the live store, so a change to the matching rule
    /// has to keep clearing all of them.
    func testEveryShapeOfSpacerSeenInTheStoreIsRejected() {
        let seen = [
            "https://st.discogs.com/be5e3ab96f7a7387ef5f7d4ecf66094c0cd5dc60/images/spacer.gif",
            "https://st.discogs.com/78792c02e02592289e1013a65802bc8f2fce8609/images/spacer.gif",
            "https://st.discogs.com/f0c99392dcec9ca00ad4a8800250dbc3a9c923d9/images/spacer.gif",
            "https://st.discogs.com/756ebacba9192eeea95bf8e7f87f401565ee469a/images/spacer.gif"
        ]
        for address in seen {
            XCTAssertNil(DiscogsClient.usableImage(address), "Still letting through \(address)")
        }
    }
}
