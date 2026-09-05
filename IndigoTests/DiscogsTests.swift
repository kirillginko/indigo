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
        XCTAssertEqual(artist.releaseTitles, ["Pool"])
        XCTAssertEqual(artist.releaseDiscogsIDs, [10])
        XCTAssertEqual(artist.releaseImageURLStrings, ["https://img.test/pool.jpg"])
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
