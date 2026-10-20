//
//  CachedRecordEvidenceTests.swift
//  IndigoTests
//
//  An artist described before identity evidence was kept: a fresh cached
//  record with its Discogs id and nothing else. It must open as itself with
//  no network at all, and gain its evidence with one request when there is.
//

import XCTest
import SwiftData
@testable import Indigo

private final class RecordingTransport: DiscogsTransport, @unchecked Sendable {
    struct Refused: Error {}
    let routes: [String: String]
    let failing: Bool
    private let lock = NSLock()
    private var seen: [String] = []
    var requests: [String] { lock.withLock { seen } }

    init(routes: [String: String], failing: Bool = false) {
        self.routes = routes
        self.failing = failing
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url?.absoluteString ?? ""
        lock.withLock { seen.append(url) }
        if failing { throw Refused() }
        let route = routes.keys.filter(url.contains).max { $0.count < $1.count }
        let body = route.flatMap { routes[$0] } ?? "{}"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: route == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class CachedRecordEvidenceTests: XCTestCase {
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

    /// Prefuse 73 as a pre-V8 install holds him: described this morning, at
    /// the current cache version, with his aliases as names and no ids.
    private func cachedPrefuse() {
        let record = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Prefuse 73"), discogsID: 3722, name: "Prefuse 73")
        record.biography = "Music producer, who has been based in Atlanta, Barcelona and New York."
        record.aliasNames = ["Reto A Ichi", "Scott Herren"]
        record.releaseTitles = ["One Word Extinguisher", "Vocal Studies + Uprock Narratives"]
        record.releaseYears = ["2003", "2001"]
        record.releaseDiscogsIDs = [10, 11]
        record.releaseImageURLStrings = ["", ""]
        record.releaseLabels = ["Warp Records", "Warp Records"]
        record.cacheVersion = 14
        record.fetchedAt = Date()
        context.insert(record)
        try? context.save()
    }

    private let head = #"{"results":[{"id":3722,"title":"Prefuse 73"}]}"#

    func testACachedArtistGainsItsEvidenceWithOneRequest() async throws {
        cachedPrefuse()
        let transport = RecordingTransport(routes: [
            "type=artist&per_page=5": head,
            "artists/3722": ArtistIdentityFixtures.entries[3722]!
        ])
        let store = DigStore(context: context, discogsClient: DiscogsClient(transport: transport, token: "t"))
        XCTAssertNil(store.identityStore.facts(3722))

        await store.enrichArtist(name: "Prefuse 73", mbid: nil)

        let facts = try XCTUnwrap(store.identityStore.facts(3722), "Not after a day: now")
        XCTAssertTrue(facts.nameVariations.contains("Prefuse73"))
        XCTAssertTrue(facts.aliases.contains { $0.id == 6810891 && $0.name == "Reto A Ichi" })
        let entryReads = transport.requests.filter { $0.contains("artists/3722") && !$0.contains("releases") }
        XCTAssertEqual(entryReads.count, 1)
        XCTAssertFalse(transport.requests.contains { $0.contains("artists/3722/releases") },
                       "The record is fresh; only who it is was missing")
    }

    func testEvidenceAlreadyHeldIsNotReadAgain() async throws {
        cachedPrefuse()
        ArtistIdentityStore(context: context).record(try ArtistIdentityFixtures.facts(3722))
        let transport = RecordingTransport(routes: ["type=artist&per_page=5": head])
        let store = DigStore(context: context, discogsClient: DiscogsClient(transport: transport, token: "t"))

        await store.enrichArtist(name: "Prefuse 73", mbid: nil)

        XCTAssertFalse(transport.requests.contains { $0.contains("artists/3722") })
    }

    /// Offline, the cached record is the page: titled, populated, resolved to
    /// the entry it is filed as, and nothing written about who it is.
    func testOfflineTheCachedRecordStillOpensAsItself() async throws {
        cachedPrefuse()
        let transport = RecordingTransport(routes: [:], failing: true)
        let store = DigStore(context: context, discogsClient: DiscogsClient(transport: transport, token: "t"))

        await store.enrichArtist(name: "Prefuse 73", mbid: nil)
        store.bumpRevisionForTesting()
        let page = store.artistPage(ArtistReference(name: "Prefuse 73"))

        XCTAssertEqual(page.name, "Prefuse 73")
        XCTAssertEqual(page.discogsID, 3722)
        XCTAssertEqual(page.resolution.basis, .filedRecord)
        XCTAssertFalse(page.titlePending)
        XCTAssertNil(page.cameFrom)
        XCTAssertNil(store.identityStore.facts(3722), "A refusal is not evidence")
        let profile = DigEngine(context: context).artistProfile(name: page.name, mbid: nil, alsoCreditedAs: page.alsoCreditedAs)
        // The cached record's own discography is on the page. (The test host
        // can add Bandcamp releases it holds process-wide, so this checks for
        // the record's titles rather than a count.)
        XCTAssertTrue(Set(profile.releases.map(\.title)).isSuperset(of: ["One Word Extinguisher", "Vocal Studies + Uprock Narratives"]))
    }

    /// Opened by id with no network, the page is the cached record too.
    func testOfflineAnIDReferenceOpensTheCachedRecord() async {
        cachedPrefuse()
        let store = DigStore(context: context, discogsClient: DiscogsClient(
            transport: RecordingTransport(routes: [:], failing: true), token: "t"))

        await store.enrichArtist(name: "Prefuse 73", mbid: nil, discogsID: 3722)
        let page = store.artistPage(ArtistReference(name: "Prefuse 73", discogsID: 3722))

        XCTAssertEqual(page.name, "Prefuse 73")
        XCTAssertFalse(page.titlePending)
    }
}
