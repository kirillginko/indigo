//
//  DiscogsTests.swift
//  IndigoTests
//

import XCTest
import SwiftData
@testable import Indigo

/// Refuses the first `refusals` requests the way Discogs refuses an
/// over-budget one — a 429, answered instantly — then behaves.
private struct RefusingDiscogsTransport: DiscogsTransport {
    let refusals: Int
    let body: String
    let counter = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
        var count: Int { lock.withLock { value } }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let status = counter.next() < refusals ? 429 : 200
        return (Data(body.utf8), HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!)
    }
}

private struct StubDiscogsTransport: DiscogsTransport {
    let routes: [String: String]
    let recorder: Recorder

    final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recorder.requests.append(request)
        let url = request.url?.absoluteString ?? ""
        let route = routes.keys.filter(url.contains).max { $0.count < $1.count }
        guard let route, let body = routes[route] else {
            return (Data("{}".utf8), HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!)
        }
        return (Data(body.utf8), HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!)
    }
}

final class DiscogsTests: XCTestCase {
    private let search = """
    {"results":[
      {"id":2,"title":"Skee Mask Tribute","cover_image":"https://img.test/wrong.jpg"},
      {"id":1,"title":"Skee Mask","cover_image":"https://img.test/search.jpg"}
    ]}
    """
    private let detail = """
    {"id":1,"name":"Skee Mask","realname":"Bryan Müller","profile":"Producer from Munich.",
     "uri":"/artist/1-Skee-Mask",
     "images":[{"type":"primary","uri":"https://img.test/artist.jpg","uri150":"https://img.test/150.jpg"}],
     "aliases":[{"id":3,"name":"SCNTST"}],"members":[],"groups":[{"id":4,"name":"Zenker Brothers"}]}
    """
    private let releases = """
    {"releases":[
      {"id":10,"title":"Pool","year":2021,"role":"Main","type":"master","label":"Ilian Tape","artist":"Skee Mask"},
      {"id":11,"title":"Compro","year":2018,"role":"Main","type":"master","label":"Ilian Tape","artist":"Skee Mask"},
      {"id":12,"title":"Remix","year":2020,"role":"Remix","type":"release","label":"Other","artist":"Someone"}
    ]}
    """
    private let catalogue = """
    {"results":[{"id":10,"title":"Skee Mask - Pool","year":"2021","label":["Ilian Tape"],
      "genre":["Electronic"],"style":["Ambient","Techno"],"cover_image":"https://img.test/pool.jpg"}]}
    """
    private let releaseDetail = """
    {"id":10,"title":"Pool","year":2021,"uri":"/release/10-Pool",
     "artists":[{"id":1,"name":"Skee Mask"}],
     "labels":[{"id":5,"name":"Ilian Tape","catno":"ITLP09"}],
     "genres":["Electronic"],"styles":["Ambient","Techno"],
     "images":[{"type":"primary","uri":"https://img.test/pool-large.jpg","uri150":"https://img.test/pool.jpg"}],
     "tracklist":[{"position":"A1","title":"Nvivo","duration":"6:04"},
                  {"position":"A2","title":"Stone Cold","duration":"5:20"}],
     "extraartists":[{"id":7,"name":"Rashad Becker","role":"Mastered By"},
                     {"id":8,"name":"Zenker Brothers","anv":"Zenkers","role":"Producer"},
                     {"id":9,"name":"Some Designer","role":"Artwork By"},
                     {"id":11,"name":"A Player","role":"Bass","tracks":"A1 to A2"}],
     "notes":"Recorded in Munich."}
    """

    /// What a search response costs to turn into values.
    ///
    /// `DiscogsClient` is a `nonisolated struct`, but this target is built
    /// with `SWIFT_APPROACHABLE_CONCURRENCY`, so its async methods run on the
    /// caller's actor — which is why the trace shows the same request as
    /// `[MAIN]` from `DigStore` and `[bg]` from `DigWorker`. The decode sits
    /// outside the traced region, so from `DigStore` it is unmeasured work on
    /// the thread that draws.
    func testWhatDecodingASearchCostsOnTheCallersActor() throws {
        let results = (0..<50).map { index in
            """
            {"id":\(index),"title":"Some Artist \(index) - A Record With A Long Enough Name",
             "thumb":"https://img.discogs.test/thumb-\(index).jpg",
             "cover_image":"https://img.discogs.test/cover-\(index).jpg",
             "genre":["Electronic","Rock"],
             "style":["Techno","Ambient","Deep House","Experimental"],
             "label":["Ilian Tape","Warp Records","Hessle Audio"],
             "year":"2018"}
            """
        }.joined(separator: ",")
        let payload = Data("{\"results\":[\(results)]}".utf8)

        let started = ContinuousClock.now
        var decoded = 0
        for _ in 0..<20 {
            decoded += (try JSONDecoder().decode(DiscogsSearchResponse.self, from: payload))
                .results?.count ?? 0
        }
        let parts = (ContinuousClock.now - started).components
        let each = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        XCTAssertEqual(decoded, 1000)
        XCTAssertLessThan(
            each / 20, 5,
            "One search decode costs \(each / 20)ms; a cold artist does two dozen of them"
        )
    }

    /// Being told to slow down is not being told there is nothing there.
    ///
    /// Discogs answers an over-budget request in a millisecond with a 429, and
    /// a cold artist issues nine requests. Throwing the first refusal straight
    /// through is how a page waits a long time and then comes back empty.
    func testARefusedRequestIsWaitedOutRatherThanReportedAsNothing() async throws {
        let transport = RefusingDiscogsTransport(refusals: 2, body: search)
        let client = DiscogsClient(transport: transport, token: "t")

        let head = try await client.artistHead(named: "Skee Mask")

        XCTAssertNotNil(head, "The data was there; the app was only asked to wait")
        XCTAssertEqual(transport.counter.count, 3, "Two refusals, then the answer")
    }

    /// But not forever: a page that has been blank for long enough is failing
    /// whatever the reason, and the caller has cached data to fall back on.
    func testAPersistentRefusalIsStillReported() async throws {
        let transport = RefusingDiscogsTransport(refusals: 99, body: search)
        let client = DiscogsClient(transport: transport, token: "t")

        do {
            _ = try await client.artistHead(named: "Skee Mask")
            XCTFail("A refusal that never lifts has to surface")
        } catch DiscogsError.rateLimited {
            XCTAssertEqual(transport.counter.count, 3, "Tried, twice more, then gave up")
        }
    }

    func testDiscogsArtistBundleUsesExactMatchAndAuthentication() async throws {
        let recorder = StubDiscogsTransport.Recorder()
        let client = DiscogsClient(transport: StubDiscogsTransport(routes: [
            "type=artist": search,
            "artists/1/releases": releases,
            "artists/1": detail,
            "type=release": catalogue
        ], recorder: recorder), token: "secret")

        let loadedBundle = try await client.artist(named: "Skee Mask")
        let bundle = try XCTUnwrap(loadedBundle)

        XCTAssertEqual(bundle.detail.id, 1)
        XCTAssertEqual(bundle.catalogue.first?.style, ["Ambient", "Techno"])
        XCTAssertEqual(recorder.requests.count, 4)
        XCTAssertTrue(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Discogs token=secret"
        })
    }

    func testDiscogsEnrichmentPersistsArtistDetailsAndReusesCache() async throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)
        let recorder = StubDiscogsTransport.Recorder()
        let client = DiscogsClient(transport: StubDiscogsTransport(routes: [
            "type=artist": search,
            "artists/1/releases": releases,
            "artists/1": detail,
            "type=release": catalogue
        ], recorder: recorder), token: "secret")
        let enricher = DiscogsEnricher(context: context, client: client)

        let loadedArtist = try await enricher.artist(named: "Skee Mask")
        let artist = try XCTUnwrap(loadedArtist)
        _ = try await enricher.artist(named: "skee mask")

        XCTAssertEqual(artist.realName, "Bryan Müller")
        XCTAssertEqual(artist.imageURL?.absoluteString, "https://img.test/artist.jpg")
        // Both records, from the artist's own releases rather than from a
        // search on their name. The search returns only Pool, and taking the
        // discography from it lost Compro entirely — the same fault that, read
        // the other way, filled a page for Anika with records by Anika (2),
        // Anika (6) and Anika (20). The remix is not here because the role
        // filter drops it, which is what that filter is for.
        XCTAssertEqual(artist.releaseTitles, ["Pool", "Compro"])
        XCTAssertEqual(artist.releaseDiscogsIDs, [10, 11])
        // Sleeves still come from the search, matched by id, because the
        // releases endpoint carries none. A record it did not return keeps an
        // empty slot rather than shifting every cover onto the wrong row.
        XCTAssertEqual(artist.releaseImageURLStrings, ["https://img.test/pool.jpg", ""])
        XCTAssertEqual(artist.labelNames, ["Ilian Tape"])
        XCTAssertEqual(artist.genres, ["Electronic"])
        XCTAssertEqual(artist.styles, ["Ambient", "Techno"])
        XCTAssertEqual(artist.aliasNames, ["SCNTST"])
        XCTAssertEqual(artist.groupNames, ["Zenker Brothers"])
        XCTAssertEqual(recorder.requests.count, 4, "The second lookup should use the six-hour cache")
    }

    func testReleaseEnrichmentPersistsBrowsableAlbumData() async throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)
        let recorder = StubDiscogsTransport.Recorder()
        let client = DiscogsClient(transport: StubDiscogsTransport(
            routes: ["releases/10": releaseDetail], recorder: recorder
        ), token: "secret")

        let release = try await DiscogsEnricher(context: context, client: client).release(id: 10)

        XCTAssertEqual(release.title, "Pool")
        XCTAssertEqual(release.artistNames, ["Skee Mask"])
        XCTAssertEqual(release.labelNames, ["Ilian Tape"])
        XCTAssertEqual(release.catalogNumbers, ["ITLP09"])
        XCTAssertEqual(release.imageURL?.absoluteString, "https://img.test/pool-large.jpg")
        XCTAssertEqual(release.styles, ["Ambient", "Techno"])
        XCTAssertEqual(release.trackPositions, ["A1", "A2"])
        XCTAssertEqual(release.trackTitles, ["Nvivo", "Stone Cold"])

        // The sleeve, minus the sleeve. Discogs lists whoever did the artwork
        // in the same array as the producer, and only one of those is a
        // musical connection — see `CreditRole`.
        XCTAssertEqual(release.creditNames, ["Rashad Becker", "Zenkers", "A Player"])
        XCTAssertEqual(release.creditRoles, ["Mastered By", "Producer", "Bass"])
        XCTAssertEqual(release.creditTracks, ["", "", "A1 to A2"])
        XCTAssertFalse(release.creditNames.contains("Some Designer"))
    }

    /// Discogs names the spelling a particular record used separately from the
    /// canonical one. The record's own spelling is what belongs on its page.
    func testACreditKeepsTheSpellingTheRecordUsed() async throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)
        let client = DiscogsClient(transport: StubDiscogsTransport(
            routes: ["releases/10": releaseDetail], recorder: StubDiscogsTransport.Recorder()
        ), token: "secret")

        let release = try await DiscogsEnricher(context: context, client: client).release(id: 10)
        XCTAssertTrue(release.creditNames.contains("Zenkers"))
        XCTAssertFalse(release.creditNames.contains("Zenker Brothers"))
    }

    func testDiscogsReferenceMarkupIsRemovedFromProfiles() {
        let raw = "Daughter of singer [a2268737] and actress. [l2200939] label owner with [a=Visible Artist]."
        XCTAssertEqual(
            DiscogsEnricher.cleanProfile(raw),
            "Daughter of singer and actress. label owner with Visible Artist."
        )
    }

    func testTextOnlyReleaseCanResolveToABrowsableID() async throws {
        let recorder = StubDiscogsTransport.Recorder()
        let body = """
        {"results":[{"id":44,"title":"Juana Molina - Rara","year":"1996"}]}
        """
        let client = DiscogsClient(
            transport: StubDiscogsTransport(routes: ["release_title=Rara": body], recorder: recorder),
            token: "secret"
        )

        let resolvedID = try await client.releaseID(title: "Rara", artist: "Juana Molina")
        XCTAssertEqual(resolvedID, 44)
        XCTAssertEqual(recorder.requests.count, 1)
    }
}

// MARK: - Whose records these are

/// A page for one musician offered four other people's records as things to
/// discover, and offered several of them twice. Both came from the same place:
/// the discography was a text search on the artist's *name*.
final class ArtistDiscographyTests: XCTestCase {
    private func release(
        _ title: String, id: Int, year: Int? = nil, type: String = "release", main: Int? = nil
    ) -> DiscogsArtistRelease {
        DiscogsArtistRelease(
            id: id, title: title, year: year, role: "Main", type: type,
            label: nil, artist: nil, mainRelease: main, format: "Vinyl, LP", thumbnail: nil
        )
    }

    /// Discogs files an album, its repress and its CD issue separately. They
    /// are three objects and one find.
    func testOneRowPerRecordHoweverManyPressings() {
        let found = DiscogsEnricher.discography([
            release("Change", id: 1),
            release("change", id: 2),
            release("Anika - Change", id: 3),
            release("Anika EP", id: 4)
        ], artist: "Anika")

        XCTAssertEqual(found.map(\.title), ["Change", "Anika EP"])
    }

    /// A row with no id would shift every sleeve after it onto the wrong
    /// record, because the arrays this feeds are read by index.
    func testNothingWithoutAnIdSurvives() {
        let found = DiscogsEnricher.discography([
            DiscogsArtistRelease(id: nil, title: "Untitled", year: nil, role: "Main",
                                 type: "release", label: nil, artist: nil, mainRelease: nil,
                                 format: "Vinyl, LP", thumbnail: nil),
            release("Change", id: 1)
        ], artist: "Anika")

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.title, "Change")
    }

    /// A master's own id is not a release id, and `releases/{id}` cannot
    /// answer for one.
    func testAMasterOpensThePressingItStandsFor() {
        let master = release("Change", id: 9_000, type: "master", main: 12_345)
        XCTAssertEqual(master.catalogueID, 12_345)
        XCTAssertEqual(release("Change", id: 555).catalogueID, 555)
    }
}

// MARK: - Whose labels these are

/// A page for Anika named FACT Magazine among her labels, because the list was
/// the first twelve labels in the order Discogs listed the records — newest
/// first — so one appearance on a magazine's compilation outranked the imprint
/// carrying half her catalogue.
final class ArtistImprintTests: XCTestCase {
    private func release(
        _ title: String, label: String, artist: String, format: String = "Vinyl, LP"
    ) -> DiscogsArtistRelease {
        DiscogsArtistRelease(
            id: Int.random(in: 1...100_000), title: title, year: nil, role: "Main",
            type: "release", label: label, artist: artist, mainRelease: nil, format: format, thumbnail: nil
        )
    }

    func testTheImprintCarryingTheCatalogueComesFirst() {
        let found = DiscogsEnricher.imprints(releasedBy: [
            release("Compilation", label: "FACT Magazine", artist: "Various"),
            release("Change", label: "Sacred Bones Records", artist: "Anika"),
            release("Anika", label: "Sacred Bones Records", artist: "Anika"),
            release("Anika EP", label: "Sacred Bones Records", artist: "Anika"),
            release("A Single", label: "Invada Records", artist: "Anika")
        ], artist: "Anika")

        XCTAssertEqual(found.first, "Sacred Bones Records")
        XCTAssertFalse(found.contains("FACT Magazine"),
                       "A record credited to Various is somebody else's release")
        XCTAssertTrue(found.contains("Invada Records"), "One record is still a record")
    }

    /// An artist is not one of their own imprints.
    func testAnArtistIsNotTheirOwnLabel() {
        let found = DiscogsEnricher.imprints(releasedBy: [
            release("Self Released", label: "Anika", artist: "Anika"),
            release("Change", label: "Sacred Bones Records", artist: "Anika")
        ], artist: "Anika")

        XCTAssertEqual(found, ["Sacred Bones Records"])
    }

    /// Discogs joins every company on a record into one field, and the
    /// pressing plant is not the label either.
    func testOneFieldNamingTwoImprintsIsTwo() {
        let found = DiscogsEnricher.imprints(releasedBy: [
            release("Change", label: "Sacred Bones Records, Invada Records", artist: "Anika")
        ], artist: "Anika")

        XCTAssertEqual(Set(found), ["Sacred Bones Records", "Invada Records"])
    }
}

// MARK: - Which of the people with this name

/// Discogs numbers everybody who shares a name, and `withoutDisambiguator`
/// folds the numbers away so that "Nirvana (2)" can be found at all. That
/// leaves a tie, and a tie used to be settled by whichever Discogs ranked
/// first — which for Hype Williams is the video director, not Dean Blunt and
/// Inga Copeland's duo.
final class ArtistNamesakeTests: XCTestCase {
    private func result(_ title: String, id: Int) -> DiscogsSearchResult {
        DiscogsSearchResult(
            id: id, title: title, coverImage: nil, thumbnail: nil,
            genre: nil, style: nil, label: nil, year: nil
        )
    }

    func testEveryNamesakeIsACandidate() {
        let found = DiscogsClient.artistMatches(name: "Hype Williams", results: [
            result("Hype Williams", id: 1),
            result("Hype Williams (2)", id: 2),
            result("Hype Williams Jr", id: 3)
        ])

        XCTAssertEqual(found.map(\.id), [1, 2], "Both of them, and not a different name")
    }

    /// The old behaviour, kept as the fallback: with one match there is
    /// nothing to disambiguate and nothing to ask Discogs about.
    func testOneMatchNeedsNoDeciding() {
        let found = DiscogsClient.artistMatches(name: "Skee Mask", results: [
            result("Skee Mask", id: 1),
            result("Skee Masks", id: 2)
        ])

        XCTAssertEqual(found.map(\.id), [1])
        XCTAssertEqual(
            DiscogsClient.bestArtistMatch(name: "Skee Mask", results: [
                result("Skee Mask", id: 1)
            ])?.id, 1
        )
    }

    /// An asterisk is Discogs saying a record credited them under a variant
    /// spelling. It is filing, not a different person.
    func testAVariantSpellingIsTheSamePerson() {
        let found = DiscogsClient.artistMatches(name: "Flowdan", results: [
            result("Flowdan*", id: 7)
        ])

        XCTAssertEqual(found.map(\.id), [7])
    }
}

// MARK: - Records, not films

/// Discogs files the video director Hype Williams and Dean Blunt and Inga
/// Copeland's duo under one name, and asking which of them has releases of
/// their own could not separate them: he is the main credit on his own videos.
/// The format is what does — and the same distinction is why a page for him
/// listed Palm Pictures, a film distributor, among his labels.
final class VideoReleaseTests: XCTestCase {
    private func release(_ title: String, format: String?) -> DiscogsArtistRelease {
        DiscogsArtistRelease(
            id: 1, title: title, year: nil, role: "Main", type: "release",
            label: "Palm Pictures", artist: "Hype Williams", mainRelease: nil, format: format, thumbnail: nil
        )
    }

    func testAFilmIsNotARecord() {
        XCTAssertTrue(release("Belly", format: "DVD, NTSC").isVideo)
        XCTAssertTrue(release("Videos", format: "VHS, Compilation").isVideo)
        XCTAssertTrue(release("Live", format: "Blu-ray").isVideo)
        XCTAssertFalse(release("One Nation", format: "Vinyl, LP, Album").isVideo)
        XCTAssertFalse(release("Find Out What Happens", format: "Cassette").isVideo)
        XCTAssertFalse(release("Untitled", format: nil).isVideo,
                       "Nothing said is not a claim that it is a film")
    }

    /// A film distributor is not an imprint an artist releases on; it is who
    /// put out the DVD.
    func testWhoeverReleasedTheDvdIsNotALabel() {
        let found = DiscogsEnricher.imprints(releasedBy: [
            DiscogsArtistRelease(
                id: 1, title: "Belly", year: nil, role: "Main", type: "release",
                label: "Palm Pictures", artist: "Hype Williams", mainRelease: nil,
                format: "DVD, NTSC", thumbnail: nil
            )
        ].filter { !$0.isVideo }, artist: "Hype Williams")

        XCTAssertTrue(found.isEmpty)
    }
}

// MARK: - Sleeves and who put it out

/// Three things the artist releases endpoint knows that nothing was reading,
/// and one thing the search says that should never have been believed.
final class ReleaseSleeveTests: XCTestCase {
    private func master(_ title: String, id: Int, label: String? = nil, thumb: String? = nil)
    -> DiscogsArtistRelease {
        DiscogsArtistRelease(
            id: id, title: title, year: nil, role: "Main", type: "master",
            label: label, artist: "Hype Williams", mainRelease: id, format: "Vinyl, LP",
            thumbnail: thumb
        )
    }

    private func searchHit(_ title: String, id: Int, label: [String]?, cover: String?)
    -> DiscogsSearchResult {
        DiscogsSearchResult(
            id: id, title: title, coverImage: cover, thumbnail: cover,
            genre: nil, style: nil, label: label, year: nil
        )
    }

    /// Discogs answers "no sleeve" with a real URL that loads a transparent
    /// pixel. Drawn, that is a blank tile on a record whose own page shows a
    /// perfectly good cover.
    func testTheNoImagePlaceholderIsNotAnImage() {
        XCTAssertNil(DiscogsClient.usableImage(
            "https://st.discogs.com/abc/images/spacer.gif"
        ))
        XCTAssertNil(DiscogsClient.usableImage(""))
        XCTAssertNil(DiscogsClient.usableImage(nil))
        XCTAssertEqual(
            DiscogsClient.usableImage("https://i.discogs.com/real.jpeg"),
            "https://i.discogs.com/real.jpeg"
        )
    }

    /// An artist's albums are filed as masters, and a master row carries no
    /// label — so reading only that field sampled their labels through the
    /// one-off releases at the edge of the catalogue.
    func testAMastersLabelComesFromTheSearchWhenItsOwnRowHasNone() {
        let sleeves = [10: searchHit("Hype Williams - One Nation", id: 10,
                                     label: ["Hyperdub"], cover: nil)]

        XCTAssertEqual(
            DiscogsEnricher.label(of: master("One Nation", id: 10), sleeves: sleeves),
            "Hyperdub"
        )
        // Its own row wins where it has one.
        XCTAssertEqual(
            DiscogsEnricher.label(of: master("Rise Up", id: 10, label: "Second Layer Records"),
                                  sleeves: sleeves),
            "Second Layer Records"
        )
    }

    /// With the masters counted, the imprint carrying the catalogue outranks
    /// a magazine that hosted one mix.
    func testTheMagazineStopsOutrankingTheLabel() {
        let sleeves = [
            10: searchHit("Hype Williams - One Nation", id: 10, label: ["Big Dada Recordings"], cover: nil),
            11: searchHit("Hype Williams - Black Is Beautiful", id: 11, label: ["Big Dada Recordings"], cover: nil)
        ]
        let found = DiscogsEnricher.imprints(releasedBy: [
            DiscogsArtistRelease(
                id: 99, title: "FACT Mix 216", year: nil, role: "Main", type: "release",
                label: "FACT Magazine", artist: "Hype Williams", mainRelease: nil,
                format: "File, MP3", thumbnail: nil
            ),
            master("One Nation", id: 10),
            master("Black Is Beautiful", id: 11)
        ], artist: "Hype Williams", sleeves: sleeves)

        XCTAssertEqual(found.first, "Big Dada Recordings")
    }
}

// MARK: - Discogs' filing is not a person

/// Discogs files the second person with a name as "Hype Williams (2)". Carried
/// into the app that becomes an artist in its own right: a duplicate page
/// under a spelling nothing is catalogued against, with no picture, no
/// discography and no way back to the artist it is a spelling of.
final class CreditSpellingTests: XCTestCase {
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

    /// Rows written before the boundary stripped these are still in the
    /// store, and they refetch only when they go stale.
    func testACachedCreditIsReadWithoutItsFilingNumber() {
        let record = DiscogsReleaseRecord(discogsID: 1, title: "One Nation")
        record.artistNames = ["Hype Williams (2)", "Dean Blunt"]
        context.insert(record)

        XCTAssertEqual(record.credits, ["Hype Williams", "Dean Blunt"])
    }

    /// The whole point: the stripped name opens the artist everything else is
    /// filed under, rather than a page of its own.
    func testAStrippedCreditIsTheSameNodeAsTheArtist() {
        let record = DiscogsReleaseRecord(discogsID: 1, title: "One Nation")
        record.artistNames = ["Hype Williams (2)"]
        context.insert(record)

        XCTAssertEqual(
            MusicNode.artist(try! XCTUnwrap(record.credits.first)).id,
            MusicNode.artist("Hype Williams").id
        )
    }

    /// A track line names who is on it when the record is credited to nobody,
    /// and it carries the same numbers.
    func testATrackCreditLosesItToo() {
        let line = DiscogsTrackLine(
            position: "A1", title: "Businessline", duration: "3:20",
            artists: [DiscogsArtistReference(id: 1, name: "Hype Williams (2)")]
        )

        XCTAssertEqual(line.artistName, "Hype Williams")
    }
}
