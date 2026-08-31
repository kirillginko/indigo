//
//  DigArtworkTests.swift
//  IndigoTests
//
//  The same record had a sleeve in one view and a blank square in the next,
//  because every surface worked the answer out for itself.
//

import XCTest
import SwiftData
@testable import Indigo

final class DigArtworkTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    /// A record Discogs pictures with nothing, which the artist's own Bandcamp
    /// has a sleeve for — and which used to appear in the grid and vanish on
    /// its own page.
    func testAReleasePageFindsTheSleeveTheGridFound() throws {
        let record = DiscogsReleaseRecord(discogsID: 42, title: "Honest Labour")
        record.artistNames = ["Space Afrika"]
        record.imageURLString = nil
        context.insert(record)

        let bandcamp = BandcampRelease(
            urlString: "https://x.bandcamp.com/album/honest-labour",
            title: "Honest Labour", artistName: "Space Afrika",
            imageURLString: "https://f4.bcbits.com/img/a0599943016_10.jpg"
        )
        context.insert(bandcamp)

        let profile = try XCTUnwrap(DigEngine(context: context).releaseProfile(id: 42))
        XCTAssertEqual(profile.imageURL?.absoluteString,
                       "https://f4.bcbits.com/img/a0599943016_16.jpg")
    }

    /// A thumbnail from one source and a cover from another is still better
    /// than neither.
    func testHalvesFromDifferentSourcesAreBothKept() {
        let combined = DigArtwork.Pair.first([
            DigArtwork.Pair(full: URL(string: "https://a/full.jpg"), thumbnail: nil),
            DigArtwork.Pair(full: nil, thumbnail: URL(string: "https://b/thumb.jpg"))
        ])
        XCTAssertEqual(combined.full?.absoluteString, "https://a/full.jpg")
        XCTAssertEqual(combined.thumbnail?.absoluteString, "https://b/thumb.jpg")
        XCTAssertTrue(DigArtwork.Pair.first([]).isEmpty)
    }

    /// Two records sharing a title must not swap sleeves.
    func testTheArtistDecidesWhichRecordIsMeant() throws {
        for (name, slug) in [("Space Afrika", "aaa"), ("Somebody Else", "bbb")] {
            let release = BandcampRelease(
                urlString: "https://x.bandcamp.com/album/\(slug)",
                title: "Untitled", artistName: name,
                imageURLString: "https://f4.bcbits.com/img/\(slug)_10.jpg"
            )
            context.insert(release)
        }

        let found = DigArtwork(context: context).release(title: "Untitled", artist: "Space Afrika")
        XCTAssertEqual(found.full?.absoluteString, "https://f4.bcbits.com/img/aaa_16.jpg")
    }

    /// A discography is a discography. Keeping Bandcamp apart implied its
    /// records were a lesser kind of thing.
    func testBandcampOnlyRecordsTakeTheirPlaceInTheDiscography() throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Space Afrika"),
                                   discogsID: 1, name: "Space Afrika")
        artist.releaseTitles = ["Honest Labour"]
        artist.releaseYears = ["2021"]
        artist.releaseDiscogsIDs = [42]
        artist.releaseImageURLStrings = [""]
        context.insert(artist)

        for (title, year) in [("Quiet Storm", "2026"), ("Honest Labour", "2021")] {
            let release = BandcampRelease(
                urlString: "https://x.bandcamp.com/album/\(title.filter(\.isLetter))",
                title: title, artistName: "Space Afrika", year: year,
                imageURLString: "https://f4.bcbits.com/img/\(title.filter(\.isLetter))_10.jpg"
            )
            context.insert(release)
        }

        let releases = DigEngine(context: context)
            .artistProfile(name: "Space Afrika", mbid: nil).releases

        XCTAssertEqual(releases.map(\.title), ["Quiet Storm", "Honest Labour"],
                       "One list, newest first")
        XCTAssertEqual(releases.filter { $0.title == "Honest Labour" }.count, 1,
                       "And the record both sources have appears once")
    }
}
