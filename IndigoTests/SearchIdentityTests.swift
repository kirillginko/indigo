//
//  SearchIdentityTests.swift
//  IndigoTests
//
//  Search rows are one row exactly when they are one artist: the same
//  verified identity. Never because their names fold together.
//

import XCTest
import SwiftData
@testable import Indigo

private func artist(_ title: String, _ origin: DigSearchResult.Origin, discogsID: Int? = nil, detail: String? = nil) -> DigSearchResult {
    var row = DigSearchResult(
        kind: .artist, origin: origin, title: title, detail: detail, artworkURL: nil,
        destination: .digArtist(mbid: nil, name: title, discogsID: discogsID)
    )
    row.identity = discogsID.map { ArtistIdentity.discogs($0).rawValue }
    return row
}

private func releaseRow(_ title: String, _ origin: DigSearchResult.Origin) -> DigSearchResult {
    DigSearchResult(kind: .release, origin: origin, title: title, detail: nil, artworkURL: nil,
                    destination: .digReleaseNamed(title: title, artist: "x"))
}

/// Answers by the longest route the address contains, and counts requests.
private final class CountingTransport: DiscogsTransport, @unchecked Sendable {
    let routes: [String: String]
    private let lock = NSLock()
    private var seen: [String] = []
    var requests: [String] { lock.withLock { seen } }

    init(routes: [String: String]) { self.routes = routes }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url?.absoluteString ?? ""
        lock.withLock { seen.append(url) }
        let route = routes.keys.filter(url.contains).max { $0.count < $1.count }
        let body = route.flatMap { routes[$0] } ?? "{}"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: route == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class SearchIdentityTests: XCTestCase {
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

    private func recordPrefuse() throws {
        ArtistIdentityStore(context: context).record(DiscogsSpellingCheck(
            spelling: "Prefuse73", verdict: .variation(3722), resultCount: 15,
            results: [], facts: [try ArtistIdentityFixtures.facts(3722)]
        ))
    }

    /// The live case: the catalogue holds a row filed under the spelling, and
    /// Discogs holds Prefuse 73. One row, under his name, keeping the spelling
    /// that matched, where the first of them stood, opening by id.
    func testTwoSpellingsOfOneArtistAreOneRow() throws {
        try recordPrefuse()
        let store = DigStore(context: context)
        let results = store.resolvingIdentities(DigSearchResults(
            yours: [artist("Aphex Twin", .yours)],
            catalogue: [artist("Prefuse73", .catalogue), releaseRow("Zola Jesus & Prefuse73 Supports Finders Keepers", .catalogue)],
            discogs: [artist("Prefuse 73", .discogs, discogsID: 3722), artist("Savath & Savalas", .discogs, discogsID: 3838)]
        ))

        let merged = results.merged
        XCTAssertEqual(merged.map(\.title), [
            "Aphex Twin", "Prefuse 73", "Zola Jesus & Prefuse73 Supports Finders Keepers", "Savath & Savalas"
        ], "Unrelated rows keep their order")
        let prefuse = merged[1]
        XCTAssertEqual(prefuse.alsoCreditedAs, "Prefuse73")
        XCTAssertEqual(prefuse.origin, .catalogue, "It keeps the earliest source's place")
        XCTAssertEqual(prefuse.destination, .digArtist(mbid: nil, name: "Prefuse 73", discogsID: 3722))
    }

    func testAResolvedSpellingAloneIsShownUnderTheArtistsName() throws {
        try recordPrefuse()
        let row = DigStore(context: context).resolvingIdentities([artist("Prefuse73", .catalogue)])[0]

        XCTAssertEqual(row.title, "Prefuse 73")
        XCTAssertEqual(row.alsoCreditedAs, "Prefuse73")
        XCTAssertEqual(row.destination, .digArtist(mbid: nil, name: "Prefuse 73", discogsID: 3722))
    }

    /// Without evidence the two spellings are two rows. Spacing is not identity.
    func testWithoutEvidenceTwoSpellingsStayTwoRows() {
        let results = DigStore(context: context).resolvingIdentities(DigSearchResults(
            catalogue: [artist("Prefuse73", .catalogue), artist("Prefuse 73", .catalogue)]
        ))
        XCTAssertEqual(results.merged.map(\.title), ["Prefuse73", "Prefuse 73"])
    }

    func testLookalikesThatFoldTogetherAreNotMerged() {
        let results = DigSearchResults(
            yours: [artist("Twin S", .yours)],
            discogs: [artist("TWÏNS", .discogs, discogsID: 77)]
        )
        XCTAssertEqual(results.merged.count, 2)
    }

    /// "Anika" and "Anika (9)" read the same once Discogs' mark is gone, and
    /// are two entries. Both stay, and the filing name tells them apart.
    func testNamesakesAreNeverMerged() {
        let rows = DigSearchResult.rows(fromDiscogs: [
            DiscogsSearchResult(id: 555, title: "Anika", coverImage: nil, thumbnail: nil, genre: nil, style: nil, label: nil, year: nil),
            DiscogsSearchResult(id: 1982320, title: "Anika (9)", coverImage: nil, thumbnail: nil, genre: nil, style: nil, label: nil, year: nil)
        ], kind: .artist)
        let merged = DigSearchResults(discogs: rows).merged

        XCTAssertEqual(merged.map(\.title), ["Anika", "Anika"])
        XCTAssertEqual(merged.map(\.detail), [nil, "Anika (9)"])
        XCTAssertEqual(merged.map(\.identity), ["discogs:555", "discogs:1982320"])
    }

    /// A name-only row is only a name: it does not join an entry because it
    /// reads like one.
    func testANameOnlyRowDoesNotJoinAnEntryOnItsSpelling() {
        let results = DigStore(context: context).resolvingIdentities(DigSearchResults(
            yours: [artist("Anika", .yours)],
            discogs: [artist("Anika", .discogs, discogsID: 1982320)]
        ))
        XCTAssertEqual(results.merged.count, 2)
    }

    /// Two name-only rows that open the same page are the same row, as they
    /// always were.
    func testNameOnlyRowsForTheSamePageStillFold() {
        let results = DigSearchResults(
            yours: [artist("Skee Mask", .yours)],
            catalogue: [artist("Skee Mask", .catalogue)]
        )
        XCTAssertEqual(results.merged.count, 1)
        XCTAssertEqual(results.merged.first?.origin, .yours)
    }

    // MARK: The check a search runs

    private let check = #"{"pagination":{"items":1,"pages":1},"results":[{"id":3722,"title":"Prefuse 73"}]}"#

    func testTheAnsweringRowIsCheckedOnceAndLearnsItsArtist() async throws {
        let transport = CountingTransport(routes: [
            "q=Prefuse73&type=artist&per_page=50": check,
            "artists/3722": ArtistIdentityFixtures.entries[3722]!
        ])
        let store = DigStore(context: context, discogsClient: DiscogsClient(transport: transport, token: "t"))
        let rows = [artist("Prefuse73", .catalogue)]

        await store.checkAnsweringSpelling(in: rows, query: "Prefuse73")
        XCTAssertEqual(transport.requests.count, 2, "One search and one entry")
        XCTAssertEqual(store.resolvingIdentities(rows).first?.title, "Prefuse 73")

        await store.checkAnsweringSpelling(in: rows, query: "Prefuse73")
        XCTAssertEqual(transport.requests.count, 2, "Settled, so not asked again")
    }

    func testAnIncompleteCheckChangesNothing() async throws {
        let transport = CountingTransport(routes: [
            "q=Prefuse73&type=artist&per_page=50": check.replacingOccurrences(of: #""items":1"#, with: #""items":80"#)
        ])
        let store = DigStore(context: context, discogsClient: DiscogsClient(transport: transport, token: "t"))
        let rows = [artist("Prefuse73", .catalogue)]

        await store.checkAnsweringSpelling(in: rows, query: "Prefuse73")

        XCTAssertEqual(store.resolvingIdentities(rows).first?.title, "Prefuse73")
        XCTAssertTrue(store.identityStore.needsCheck("Prefuse73"), "Nothing was stored for a check that did not complete")
    }

    func testOnlyARowThatAnswersTheQueryIsChecked() async throws {
        let transport = CountingTransport(routes: [:])
        let store = DigStore(context: context, discogsClient: DiscogsClient(transport: transport, token: "t"))

        await store.checkAnsweringSpelling(in: [artist("Prefuse73", .catalogue)], query: "Savath")

        XCTAssertTrue(transport.requests.isEmpty)
    }
}
