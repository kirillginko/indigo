//
//  ArtistLookupTests.swift
//  IndigoTests
//
//  "Prefuse73" opened a page with nothing on it. Discogs' search returned
//  Prefuse 73 first, and the filing-name match threw him away — rightly, as a
//  match, and wrongly as an answer, because his entry lists "Prefuse73" among
//  the spellings his records were credited under.
//

import XCTest
import SwiftData
@testable import Indigo

/// Answers by the longest route the address contains, so "per_page=50" and
/// "per_page=5" are told apart. A route can be made to fail.
private struct RoutedTransport: DiscogsTransport {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        var paths: [String] { lock.withLock { seen } }
        func note(_ path: String) { lock.withLock { seen.append(path) } }
    }

    let routes: [String: String]
    var failing: Set<String> = []
    let recorder = Recorder()

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url?.absoluteString ?? ""
        recorder.note(url)
        let route = routes.keys.filter(url.contains).max { $0.count < $1.count }
        let failed = failing.contains { url.contains($0) }
        let body = failed ? "{}" : (route.flatMap { routes[$0] } ?? "{}")
        return (Data(body.utf8), HTTPURLResponse(
            url: request.url!, statusCode: failed ? 404 : 200, httpVersion: nil, headerFields: nil
        )!)
    }
}

private let prefuseHead = #"{"results":[{"id":3722,"title":"Prefuse 73"},{"id":111148,"title":"Soarse Spoken"}]}"#
private let prefuseCheck = #"{"pagination":{"page":1,"pages":1,"per_page":50,"items":2},"results":[{"id":3722,"title":"Prefuse 73"},{"id":111148,"title":"Soarse Spoken"}]}"#

private func prefuseRoutes() -> [String: String] {
    [
        "q=Prefuse73&type=artist&per_page=5": prefuseHead,
        "q=Prefuse73&type=artist&per_page=50": prefuseCheck,
        "artists/3722": ArtistIdentityFixtures.entries[3722]!,
        "artists/3722/releases": #"{"releases":[{"id":1,"title":"Vocal Studies + Uprock Narratives","role":"Main","type":"release","label":"Warp Records"}]}"#,
        "type=release": #"{"results":[]}"#
    ]
}

final class ArtistLookupTests: XCTestCase {
    func testPrefuse73FindsTheEntryHisRecordsAreCreditedUnder() async throws {
        let client = DiscogsClient(transport: RoutedTransport(routes: prefuseRoutes()), token: "t")

        let lookup = try await client.artistLookup(named: "Prefuse73")

        XCTAssertEqual(lookup.head?.id, 3722)
        XCTAssertTrue(lookup.isCreditedSpelling)
        XCTAssertEqual(lookup.spelling?.verdict, .variation(3722))
        XCTAssertEqual(lookup.spelling?.facts.map(\.id), [3722])
    }

    /// What it did before: the filing-name match alone, which finds nobody.
    func testTheFilingNameMatchAloneFindsNobody() {
        let results = [DiscogsSearchResult(
            id: 3722, title: "Prefuse 73", coverImage: nil, thumbnail: nil,
            genre: nil, style: nil, label: nil, year: nil
        )]
        XCTAssertTrue(DiscogsClient.artistMatches(name: "Prefuse73", results: results).isEmpty)
    }

    func testAnEntryThatWouldNotLoadEstablishesNothing() async throws {
        var transport = RoutedTransport(routes: prefuseRoutes())
        transport.failing = ["artists/3722"]
        let client = DiscogsClient(transport: transport, token: "t")

        let lookup = try await client.artistLookup(named: "Prefuse73")

        XCTAssertNil(lookup.head, "A refused entry is not evidence that it answers to the spelling")
        XCTAssertNil(lookup.spelling, "…nor that it does not: nothing is kept")
    }

    func testASearchWithMoreMatchesThanItReturnedEstablishesNothing() async throws {
        var routes = prefuseRoutes()
        routes["q=Prefuse73&type=artist&per_page=50"] = prefuseCheck.replacingOccurrences(
            of: #""items":2"#, with: #""items":120"#)
        let transport = RoutedTransport(routes: routes)
        let client = DiscogsClient(transport: transport, token: "t")

        let lookup = try await client.artistLookup(named: "Prefuse73")

        XCTAssertNil(lookup.head)
        XCTAssertNil(lookup.spelling)
        XCTAssertFalse(transport.recorder.paths.contains { $0.contains("artists/3722") },
                       "An incomplete search is given up on before any entry is read")
    }

    func testASearchWithoutPaginationIsNotComplete() async throws {
        var routes = prefuseRoutes()
        routes["q=Prefuse73&type=artist&per_page=50"] = prefuseHead
        let client = DiscogsClient(transport: RoutedTransport(routes: routes), token: "t")

        let lookup = try await client.artistLookup(named: "Prefuse73")

        XCTAssertNil(lookup.head)
        XCTAssertNil(lookup.spelling)
    }

    /// A filing name is answered the way it always was, without a check.
    func testAFiledNameNeedsNoCheck() async throws {
        let transport = RoutedTransport(routes: [
            "q=Arp&type=artist&per_page=5": #"{"results":[{"id":111,"title":"A.R.P."},{"id":222,"title":"Arp"}]}"#
        ])
        let client = DiscogsClient(transport: transport, token: "t")

        let lookup = try await client.artistLookup(named: "Arp")

        XCTAssertEqual(lookup.head?.id, 222)
        XCTAssertNil(lookup.spelling)
        XCTAssertEqual(transport.recorder.paths.count, 1)
    }
}

@MainActor
final class ArtistLookupStoreTests: XCTestCase {
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

    /// The acceptance case: open "Prefuse73", and the record is Prefuse 73's,
    /// kept under his name, with the evidence for it.
    func testOpeningPrefuse73FillsPrefuse73() async throws {
        let client = DiscogsClient(transport: RoutedTransport(routes: prefuseRoutes()), token: "t")
        let store = DigStore(context: context, discogsClient: client)

        await store.enrichArtist(name: "Prefuse73", mbid: nil)

        let enricher = DiscogsEnricher(context: context, client: client)
        let filed = try XCTUnwrap(enricher.cachedArtist(named: "Prefuse 73"))
        XCTAssertEqual(filed.discogsID, 3722)
        XCTAssertEqual(filed.releaseTitles, ["Vocal Studies + Uprock Narratives"])
        XCTAssertNil(enricher.cachedArtist(named: "Prefuse73"), "Not a second copy under the spelling")

        let joined = store.artistResolution(ArtistReference(name: "Prefuse73"))
        XCTAssertEqual(joined.identity, .discogs(3722))
        XCTAssertTrue(joined.isRedirect)
        XCTAssertEqual(joined.canonicalName, "Prefuse 73")

        let spaced = store.artistResolution(ArtistReference(name: "Prefuse 73"))
        XCTAssertEqual(spaced.identity, .discogs(3722))
        XCTAssertFalse(spaced.isRedirect)
        XCTAssertEqual(spaced.equivalentNames, ["Prefuse 73", "Prefuse73"],
                       "Opened directly, the page still reads what was credited to the other spelling")
    }

    /// A row filed under one name and holding somebody else is never a reason
    /// to open that somebody — the audit found "walton" holding Rik Walton.
    func testAMisfiledCacheRowIsNotEvidence() {
        let misfiled = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("walton"), discogsID: 77829, name: "Rik Walton")
        context.insert(misfiled)
        let store = DigStore(context: context)

        let resolution = store.artistResolution(ArtistReference(name: "walton"))

        XCTAssertEqual(resolution.identity, .name("walton"))
        XCTAssertFalse(resolution.isRedirect)
    }
}
