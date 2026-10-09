//
//  AliasDiscoveryTests.swift
//  IndigoTests
//
//  An empty alias finding its richest alias when nobody has opened any of
//  them: a bounded read of each alias's entry and the size of its shelf.
//
//  Reto A Ichi lists six aliases, in this order: Delarosa & Asora (1918),
//  Prefuse 73 (3722), Ahmad Szabo (104331), Piano Overlord, Scott Herren, The
//  Predicate Production Guild. Three are read.
//

import XCTest
import SwiftData
@testable import Indigo

private final class AliasTransport: DiscogsTransport, @unchecked Sendable {
    var routes: [String: String]
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
final class AliasDiscoveryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    private let reto = 6810891
    private let delarosa = #"{"id":1918,"name":"Delarosa & Asora","images":[],"aliases":[{"id":6810891,"name":"Reto A Ichi"}]}"#

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private func routes() -> [String: String] {
        [
            "artists/1918": delarosa,
            "artists/1918/releases": #"{"pagination":{"items":5},"releases":[]}"#,
            "artists/3722": ArtistIdentityFixtures.entries[3722]!,
            "artists/3722/releases": #"{"pagination":{"items":441},"releases":[]}"#
            // artists/104331 is refused.
        ]
    }

    /// Reto A Ichi's own record, read by DIG and empty.
    private func store(_ transport: AliasTransport) throws -> DigStore {
        ArtistIdentityStore(context: context).record(try ArtistIdentityFixtures.facts(reto))
        context.insert(DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Reto A Ichi"), discogsID: reto, name: "Reto A Ichi"))
        return DigStore(context: context, discogsClient: DiscogsClient(transport: transport, token: "t"))
    }

    func testAnEmptyAliasFindsItsRichestAliasWithinSixRequests() async throws {
        let transport = AliasTransport(routes: routes())
        let store = try store(transport)
        let reference = ArtistReference(name: "Reto A Ichi", discogsID: reto)
        XCTAssertNil(store.artistPage(reference).cameFrom, "Before: nothing known about any alias")

        await store.discoverRicherAlias(of: reto)
        store.bumpRevisionForTesting()

        XCTAssertLessThanOrEqual(transport.requests.count, 6)
        XCTAssertEqual(transport.requests.count, 5, "Two each for 1918 and 3722, one refused for 104331")
        XCTAssertFalse(transport.requests.contains { $0.contains("227795") }, "Three aliases, not six")
        let page = store.artistPage(reference)
        XCTAssertEqual(page.name, "Prefuse 73")
        XCTAssertEqual(page.discogsID, 3722)
        XCTAssertEqual(page.cameFrom, "Reto A Ichi")
    }

    /// The requested alias is still itself: its identity, and its own record
    /// to fill when Discogs has more on it.
    func testTheRequestedAliasKeepsItsIdentityAndItsRecord() async throws {
        let store = try store(AliasTransport(routes: routes()))
        await store.discoverRicherAlias(of: reto)
        store.bumpRevisionForTesting()

        let page = store.artistPage(ArtistReference(name: "Reto A Ichi", discogsID: reto))
        XCTAssertEqual(page.resolution.identity, .discogs(reto))
        let own = try context.fetch(FetchDescriptor<DiscogsArtist>()).filter { $0.discogsID == reto }
        XCTAssertEqual(own.map(\.name), ["Reto A Ichi"], "Nothing of Prefuse 73's was written onto it")
        XCTAssertTrue(own[0].releaseTitles.isEmpty)
    }

    /// A shelf that would not answer is a failed read — never an empty record.
    func testAFailedShelfIsNotAnEmptyRecord() async throws {
        var routes = routes()
        routes["artists/3722/releases"] = nil
        let store = try store(AliasTransport(routes: routes))

        await store.discoverRicherAlias(of: reto)
        store.bumpRevisionForTesting()

        XCTAssertNil(store.identityStore.summary(3722), "Unknown, not zero")
        XCTAssertFalse(store.identityStore.summaryIsDue(3722), "Not asked again within the day")
        XCTAssertEqual(store.identityStore.summary(1918)?.releases, 5)
        let page = store.artistPage(ArtistReference(name: "Reto A Ichi", discogsID: reto))
        XCTAssertEqual(page.name, "Delarosa & Asora", "The richest of what is known")
    }

    /// An alias that does not list the empty one back is read once and not
    /// preferred.
    func testAOneSidedAliasCostsOneRequestAndIsNotPreferred() async throws {
        var routes = routes()
        routes["artists/1918"] = #"{"id":1918,"name":"Delarosa & Asora","images":[],"aliases":[]}"#
        routes["artists/3722"] = nil
        let transport = AliasTransport(routes: routes)
        let store = try store(transport)

        await store.discoverRicherAlias(of: reto)
        store.bumpRevisionForTesting()

        XCTAssertFalse(transport.requests.contains { $0.contains("artists/1918/releases") })
        XCTAssertNil(store.artistPage(ArtistReference(name: "Reto A Ichi", discogsID: reto)).cameFrom)
    }

    func testWhatWasReadIsNotReadAgain() async throws {
        let transport = AliasTransport(routes: routes())
        let store = try store(transport)

        await store.discoverRicherAlias(of: reto)
        let first = transport.requests.count
        await store.discoverRicherAlias(of: reto)

        XCTAssertEqual(transport.requests.count - first, 0,
                       "Three reads per entry per session, already spent; what was read is kept")
    }

    /// The same inputs give the same choice, whatever order things arrive in.
    func testTheChoiceIsDeterministic() async throws {
        var answers: Set<String> = []
        for _ in 0..<3 {
            let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            container = try ModelContainer(for: Persistence.schema, configurations: configuration)
            context = ModelContext(container)
            let store = try store(AliasTransport(routes: routes()))
            await store.discoverRicherAlias(of: reto)
            store.bumpRevisionForTesting()
            answers.insert(store.artistPage(ArtistReference(name: "Reto A Ichi", discogsID: reto)).pageID)
        }
        XCTAssertEqual(answers.count, 1)
    }
}
