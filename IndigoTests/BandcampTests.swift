//
//  BandcampTests.swift
//  IndigoTests
//
//  Bandcamp has no public API and its robots.txt disallows `/api/` and
//  `/search` to everybody. So the first thing pinned here is the boundary:
//  Indigo never asks Bandcamp to find anything, and only reads pages it was
//  told about by a sanctioned source. The rest is the reason it is worth
//  doing at all — music that is on Bandcamp and in no catalogue.
//

import XCTest
import SwiftData
@testable import Indigo

private struct StubBandcampTransport: BandcampTransport {
    let pages: [String: String]
    let recorder: Recorder

    final class Recorder: @unchecked Sendable {
        var requested: [String] = []
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url?.absoluteString ?? ""
        recorder.requested.append(url)
        guard let body = pages[url] else {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404,
                                            httpVersion: nil, headerFields: nil)!)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil)!)
    }
}

private func albumPage(name: String, artist: String, image: String,
                       label: String, date: String, tracks: [String]) -> String {
    let items = tracks.enumerated().map { index, title in
        #"{"position":\#(index + 1),"item":{"name":"\#(title)"}}"#
    }.joined(separator: ",")
    return """
    <html><head>
    <script type="application/ld+json">
    {"@type":"MusicAlbum","name":"\(name)","datePublished":"\(date)",
     "image":"\(image)","byArtist":{"name":"\(artist)"},
     "publisher":{"name":"\(label)"},"keywords":["Electronic","Manchester"],
     "track":{"itemListElement":[\(items)]}}
    </script></head><body></body></html>
    """
}

final class BandcampTests: XCTestCase {
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

    // MARK: The boundary

    /// Bandcamp's robots.txt disallows these to every user agent. Encoding
    /// that here rather than in a comment means it cannot quietly stop being
    /// true.
    func testIndigoWillNotReadWhatBandcampAsksItNotTo() throws {
        for allowed in [
            "https://space-afrika.bandcamp.com/",
            "https://space-afrika.bandcamp.com/music",
            "https://space-afrika.bandcamp.com/album/quiet-storm",
            "https://space-afrika.bandcamp.com/track/mln"
        ] {
            XCTAssertTrue(BandcampClient.isReadable(try XCTUnwrap(URL(string: allowed))), allowed)
        }

        for refused in [
            "https://bandcamp.com/search?q=space+afrika",
            "https://bandcamp.com/api/fuzzysearch/1/autocomplete",
            "https://space-afrika.bandcamp.com/stream/abc",
            "https://space-afrika.bandcamp.com/cart/",
            "https://space-afrika.bandcamp.com/checkout"
        ] {
            XCTAssertFalse(BandcampClient.isReadable(try XCTUnwrap(URL(string: refused))), refused)
        }
    }

    func testOnlyBandcampItself() throws {
        XCTAssertFalse(BandcampClient.isReadable(try XCTUnwrap(URL(string: "https://evil.example/album/x"))))
        XCTAssertFalse(BandcampClient.isReadable(
            try XCTUnwrap(URL(string: "https://bandcamp.com.evil.example/album/x"))
        ), "A host that merely starts with the name is not the host")
    }

    /// The address has to come from somewhere sanctioned — here, the artist's
    /// own Discogs entry. Nothing searches Bandcamp for it.
    func testTheAddressComesFromTheArtistsOwnCatalogueEntry() {
        let artist = DiscogsArtist(nameKey: "space afrika", discogsID: 1, name: "Space Afrika")
        artist.externalURLStrings = [
            "https://www.instagram.com/spaceafrika",
            "https://space-afrika.bandcamp.com/"
        ]
        XCTAssertEqual(artist.bandcampURL?.absoluteString, "https://space-afrika.bandcamp.com/")

        let none = DiscogsArtist(nameKey: "x", discogsID: 2, name: "X")
        none.externalURLStrings = ["https://example.com"]
        XCTAssertNil(none.bandcampURL)
    }

    // MARK: Reading what Bandcamp publishes

    func testTheStructuredDescriptionIsReadAsPublished() throws {
        let html = albumPage(
            name: "Quiet Storm", artist: "Space Afrika",
            image: "https://f4.bcbits.com/img/a2279058220_10.jpg",
            label: "Space Afrika", date: "25 Sep 2026 00:00:00 GMT",
            tracks: ["Intro", "MLN ft. Tony Njoku"]
        )
        let json = try XCTUnwrap(BandcampClient.structuredData(in: html))
        let album = try JSONDecoder().decode(BandcampAlbumLD.self, from: Data(json.utf8))
        let release = try XCTUnwrap(album.asRelease(url: XCTUnwrap(URL(string: "https://x.bandcamp.com/album/q"))))

        XCTAssertEqual(release.title, "Quiet Storm")
        XCTAssertEqual(release.artistName, "Space Afrika")
        XCTAssertEqual(release.labelName, "Space Afrika")
        XCTAssertEqual(release.year, "2026")
        XCTAssertEqual(release.imageURL?.absoluteString, "https://f4.bcbits.com/img/a2279058220_10.jpg")
        XCTAssertEqual(release.trackTitles, ["Intro", "MLN ft. Tony Njoku"])
        XCTAssertEqual(release.keywords, ["Electronic", "Manchester"])
    }

    func testAPageThatDescribesNoReleaseIsNotOne() {
        XCTAssertNil(BandcampClient.structuredData(in: "<html><body>nothing</body></html>"))
        XCTAssertNil(BandcampDate.year(nil))
        XCTAssertNil(BandcampDate.year("no date here"))
    }

    /// Stations write the featured artist into the title and Bandcamp
    /// sometimes doesn't — and vice versa. Both spellings have to find the
    /// same record.
    func testATrackIsFoundHoweverTheCreditWasWritten() {
        let release = BandcampRelease(
            urlString: "https://x.bandcamp.com/album/quiet-storm",
            title: "Quiet Storm", artistName: "Space Afrika",
            trackTitles: ["Intro", "MLN ft. Tony Njoku"]
        )

        XCTAssertTrue(release.contains(track: "MLN ft. Tony Njoku"))
        XCTAssertTrue(release.contains(track: "MLN"), "Bandcamp has the tail; the station didn't")
        XCTAssertTrue(release.contains(track: "Intro"))
        XCTAssertFalse(release.contains(track: "Something Else"))
        XCTAssertFalse(release.contains(track: ""))
    }

    // MARK: Finding the record a track is on

    /// The case this whole thing exists for: a track in neither MusicBrainz
    /// nor Discogs, which Bandcamp knows is track two of Quiet Storm.
    func testATrackInNoCatalogueIsStillFound() async throws {
        let recorder = StubBandcampTransport.Recorder()
        let enricher = BandcampEnricher(context: context, client: BandcampClient(
            transport: StubBandcampTransport(pages: [
                "https://space-afrika.bandcamp.com/music": """
                <a href="/album/quiet-storm">Quiet Storm</a>
                <a href="/album/honest-labour">Honest Labour</a>
                """,
                "https://space-afrika.bandcamp.com/album/quiet-storm": albumPage(
                    name: "Quiet Storm", artist: "Space Afrika",
                    image: "https://f4.bcbits.com/img/quiet.jpg", label: "Space Afrika",
                    date: "25 Sep 2026 00:00:00 GMT", tracks: ["Intro", "MLN ft. Tony Njoku"]
                )
            ], recorder: recorder)
        ))

        let page = try XCTUnwrap(URL(string: "https://space-afrika.bandcamp.com/"))
        let found = await enricher.findRelease(
            containing: "MLN ft. Tony Njoku", byArtist: "Space Afrika", page: page
        )

        XCTAssertEqual(found?.title, "Quiet Storm")
        XCTAssertEqual(found?.imageURL?.absoluteString, "https://f4.bcbits.com/img/quiet.jpg")
        XCTAssertFalse(
            recorder.requested.contains { $0.contains("honest-labour") },
            "It stops at the record that names the track, rather than reading a whole discography"
        )
    }

    /// Asking twice must cost nothing. Every page is somebody else's server.
    func testTheSecondAskCostsNothing() async throws {
        let recorder = StubBandcampTransport.Recorder()
        let enricher = BandcampEnricher(context: context, client: BandcampClient(
            transport: StubBandcampTransport(pages: [
                "https://space-afrika.bandcamp.com/music": #"<a href="/album/quiet-storm">Q</a>"#,
                "https://space-afrika.bandcamp.com/album/quiet-storm": albumPage(
                    name: "Quiet Storm", artist: "Space Afrika", image: "https://img/q.jpg",
                    label: "Space Afrika", date: "25 Sep 2026 00:00:00 GMT",
                    tracks: ["MLN ft. Tony Njoku"]
                )
            ], recorder: recorder)
        ))
        let page = try XCTUnwrap(URL(string: "https://space-afrika.bandcamp.com/"))

        _ = await enricher.findRelease(containing: "MLN ft. Tony Njoku", byArtist: "Space Afrika", page: page)
        let first = recorder.requested.count
        _ = await enricher.findRelease(containing: "MLN ft. Tony Njoku", byArtist: "Space Afrika", page: page)

        XCTAssertEqual(recorder.requested.count, first, "The cache answered")
        XCTAssertNotNil(enricher.release(containing: "MLN", byArtist: "Space Afrika"))
    }

    // MARK: Deepness

    /// Being on Bandcamp and in no catalogue is not a lesser kind of release.
    /// It is often the opposite: nobody stumbles into it through a database.
    func testBandcampOnlyIsADeepnessSignalNotADemerit() {
        var catalogued = ObscuritySignals()
        catalogued.knownReleases = 4
        catalogued.releaseKind = .album

        var onlyThere = catalogued
        onlyThere.isBandcampOnly = true

        XCTAssertGreaterThan(onlyThere.score, catalogued.score)
    }
}
