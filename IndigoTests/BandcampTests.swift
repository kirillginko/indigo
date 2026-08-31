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

    // MARK: Collaborations

    /// "Rainy Miller x Space Afrika" is a record by both of them. Filing it
    /// under the first name only is how a collaboration disappears from the
    /// other artist's page.
    func testACollaborationBelongsToEveryoneOnIt() {
        let credited = RecordingKey.creditedArtists("Rainy Miller x Space Afrika")
        XCTAssertEqual(credited, ["rainy miller", "space afrika"])

        XCTAssertEqual(RecordingKey.creditedArtists("Skee Mask"), ["skee mask"])
        XCTAssertEqual(RecordingKey.creditedArtists("A & B, C"), ["a", "b", "c"])
        XCTAssertTrue(RecordingKey.creditedArtists(nil).isEmpty)
    }

    func testACollaborationIsFoundFromEitherName() throws {
        let record = BandcampRelease(
            urlString: "https://x.bandcamp.com/album/a-grisaille-wedding",
            title: "A Grisaille Wedding", artistName: "Rainy Miller x Space Afrika"
        )
        context.insert(record)

        let enricher = BandcampEnricher(context: context)
        XCTAssertEqual(enricher.cachedReleases(forArtist: "Space Afrika").map(\.title),
                       ["A Grisaille Wedding"])
        XCTAssertEqual(enricher.cachedReleases(forArtist: "Rainy Miller").map(\.title),
                       ["A Grisaille Wedding"])
        XCTAssertTrue(enricher.cachedReleases(forArtist: "Somebody Else").isEmpty)
    }

    // MARK: As a source of data

    /// For a lot of this music Bandcamp is not a footnote to the Discogs
    /// entry — it is the only record of the work, so its tags and imprints
    /// belong beside the ones a catalogue knows.
    func testBandcampTagsAndLabelsReachTheArtistPage() throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Space Afrika"),
                                   discogsID: 1, name: "Space Afrika")
        artist.genres = ["Electronic"]
        context.insert(artist)

        let release = BandcampRelease(
            urlString: "https://x.bandcamp.com/album/quiet-storm",
            title: "Quiet Storm", artistName: "Space Afrika", labelName: "sferic",
            year: "2026", keywords: ["Electronic", "trip hop", "Manchester"]
        )
        context.insert(release)

        let profile = DigEngine(context: context).artistProfile(name: "Space Afrika", mbid: nil)
        XCTAssertTrue(profile.genres.contains("trip hop"), "A tag only Bandcamp knows")
        XCTAssertEqual(profile.genres.filter { $0.lowercased() == "electronic" }.count, 1,
                       "And nothing said twice")
        XCTAssertTrue(profile.labels.map(\.name).contains("sferic"))
        XCTAssertFalse(profile.genres.contains("Manchester"), "A city is not a genre")
        XCTAssertEqual(profile.bandcamp.map(\.title), ["Quiet Storm"])
    }

    /// A pressing plant is not an imprint. Discogs' release *search* carries a
    /// `label` array holding every company credited — the plant, the mastering
    /// house, the distributor — and reading that as an artist's labels put
    /// Space Afrika on GZ Media and Bonati Mastering alongside Dais.
    func testAnArtistsLabelsAreImprintsNotCompanies() throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Space Afrika"),
                                   discogsID: 1, name: "Space Afrika")
        // What the per-release listing gives, which is the label itself.
        artist.labelNames = ["Dais Records", "sferic"]
        context.insert(artist)

        let labels = DigEngine(context: context).artistProfile(name: "Space Afrika", mbid: nil)
            .labels.map(\.name)
        XCTAssertEqual(Set(labels), ["Dais Records", "sferic"])
    }

    /// Every Bandcamp row carries a sleeve, because for a lot of these records
    /// it is the only picture of them anywhere.
    func testEveryBandcampRowCarriesItsSleeve() throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Space Afrika"),
                                   discogsID: 1, name: "Space Afrika")
        context.insert(artist)

        let release = BandcampRelease(
            urlString: "https://x.bandcamp.com/album/quiet-storm",
            title: "Quiet Storm", artistName: "Space Afrika", labelName: "sferic",
            year: "2026", imageURLString: "https://f4.bcbits.com/img/quiet.jpg",
            keywords: ["ambient"]
        )
        context.insert(release)

        let row = try XCTUnwrap(
            DigEngine(context: context).artistProfile(name: "Space Afrika", mbid: nil).bandcamp.first
        )
        XCTAssertEqual(row.title, "Quiet Storm")
        XCTAssertEqual(row.label, "sferic")
        XCTAssertEqual(row.year, "2026")
        XCTAssertEqual(row.imageURL?.absoluteString, "https://f4.bcbits.com/img/quiet.jpg")
        XCTAssertEqual(row.pageURL.absoluteString, "https://x.bandcamp.com/album/quiet-storm")
    }
}

// MARK: - Image sizes

/// Bandcamp advertises the largest cut — 1200 pixels, well over half a
/// megabyte — and that is what gets stored. Rendering it into a 148-point tile
/// downloads roughly twenty-seven times more than the tile can show.
final class BandcampImageTests: XCTestCase {
    private func url(_ address: String) throws -> URL {
        try XCTUnwrap(URL(string: address))
    }

    func testTheRightCutIsAskedFor() throws {
        let stored = try url("https://f4.bcbits.com/img/a2279058220_10.jpg")

        XCTAssertEqual(
            BandcampImage.sized(stored, BandcampImage.thumbnail)?.absoluteString,
            "https://f4.bcbits.com/img/a2279058220_9.jpg"
        )
        XCTAssertEqual(
            BandcampImage.sized(stored, BandcampImage.cover)?.absoluteString,
            "https://f4.bcbits.com/img/a2279058220_16.jpg"
        )
    }

    /// Anything that is not one of their addresses is handed back untouched —
    /// a Discogs sleeve must not be rewritten into a URL that does not exist.
    func testOtherAddressesAreLeftAlone() throws {
        let discogs = try url("https://i.discogs.com/abc/R-12028123.jpeg")
        XCTAssertEqual(BandcampImage.sized(discogs, BandcampImage.cover), discogs)

        let odd = try url("https://f4.bcbits.com/img/nosize.jpg")
        XCTAssertEqual(BandcampImage.sized(odd, BandcampImage.cover), odd)
        XCTAssertNil(BandcampImage.sized(nil, BandcampImage.cover))
    }

    /// The small cut arrives first and stands in while the other loads, so a
    /// grid fills rather than staying empty.
    func testEveryTileHasSomethingToShowImmediately() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)

        context.insert(DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Space Afrika"),
                                     discogsID: 1, name: "Space Afrika"))
        let release = BandcampRelease(
            urlString: "https://x.bandcamp.com/album/quiet-storm",
            title: "Quiet Storm", artistName: "Space Afrika",
            imageURLString: "https://f4.bcbits.com/img/a2279058220_10.jpg"
        )
        context.insert(release)

        let row = try XCTUnwrap(
            DigEngine(context: context).artistProfile(name: "Space Afrika", mbid: nil).bandcamp.first
        )
        XCTAssertEqual(row.thumbnailURL?.absoluteString,
                       "https://f4.bcbits.com/img/a2279058220_9.jpg")
        XCTAssertEqual(row.imageURL?.absoluteString,
                       "https://f4.bcbits.com/img/a2279058220_16.jpg")
    }

    /// A record Discogs pictures with nothing, and the artist's own Bandcamp
    /// has a sleeve for. Already cached, so it costs no request at all.
    func testABandcampSleeveFillsInAReleaseDiscogsHasNoPictureFor() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)

        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Space Afrika"),
                                   discogsID: 1, name: "Space Afrika")
        artist.releaseTitles = ["Honest Labour"]
        artist.releaseImageURLStrings = [""]
        artist.releaseThumbnailURLStrings = [""]
        context.insert(artist)

        let release = BandcampRelease(
            urlString: "https://x.bandcamp.com/album/honest-labour",
            title: "Honest Labour", artistName: "Space Afrika",
            imageURLString: "https://f4.bcbits.com/img/a0599943016_10.jpg"
        )
        context.insert(release)

        let line = try XCTUnwrap(
            DigEngine(context: context).artistProfile(name: "Space Afrika", mbid: nil)
                .releases.first { $0.title == "Honest Labour" }
        )
        XCTAssertEqual(line.imageURL?.absoluteString,
                       "https://f4.bcbits.com/img/a0599943016_16.jpg")
        XCTAssertEqual(line.thumbnailURL?.absoluteString,
                       "https://f4.bcbits.com/img/a0599943016_9.jpg")
    }
}
