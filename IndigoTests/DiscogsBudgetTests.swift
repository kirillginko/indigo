//
//  DiscogsBudgetTests.swift
//  IndigoTests
//
//  Discogs says how much of the minute is left on every response, and the app
//  used to read none of it — so it found the limit by being refused, and a
//  refusal arrives shaped exactly like an answer. These are the rules that
//  replace guessing.
//

import XCTest
@testable import Indigo

/// Answers with whatever rate-limit headers the test wants, or none at all.
private struct BudgetTransport: DiscogsTransport {
    var status = 200
    var remaining: Int?
    var total: Int?
    let counter = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        counter.bump()
        var headers: [String: String] = [:]
        if let remaining { headers["X-Discogs-Ratelimit-Remaining"] = String(remaining) }
        if let total { headers["X-Discogs-Ratelimit"] = String(total) }
        return (Data(#"{"results":[]}"#.utf8), HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers
        )!)
    }
}

final class DiscogsBudgetTests: XCTestCase {

    /// Nothing has been asked yet, so there is room for anything.
    func testAFreshBudgetHasRoomForBothKindsOfWork() async {
        let budget = DiscogsBudget()
        let foreground = await budget.hasRoom(for: .foreground)
        let background = await budget.hasRoom(for: .background)
        XCTAssertTrue(foreground)
        XCTAssertTrue(background)
    }

    /// The backlog stops before the budget does. What is left belongs to
    /// whatever the listener does next.
    func testTheBacklogStandsAsideBeforeTheForegroundDoes() async throws {
        let budget = DiscogsBudget()
        let client = DiscogsClient(
            transport: BudgetTransport(remaining: DiscogsBudget.reserve - 1, total: 60),
            token: "test",
            budget: budget
        )
        _ = try await client.search("skee mask", kind: .artist)

        let background = await budget.hasRoom(for: .background)
        let foreground = await budget.hasRoom(for: .foreground)
        XCTAssertFalse(background, "Below the reserve the fill waits")
        XCTAssertTrue(foreground, "The page still has the requests the fill gave up")
    }

    /// Nothing left means nothing left, for anybody.
    func testAnExhaustedBudgetStopsEverything() async throws {
        let budget = DiscogsBudget()
        let client = DiscogsClient(
            transport: BudgetTransport(remaining: 0, total: 60), token: "test", budget: budget)
        _ = try await client.search("skee mask", kind: .artist)

        let foreground = await budget.hasRoom(for: .foreground)
        XCTAssertFalse(foreground)
    }

    /// Several requests leave together and none of them has reported back yet.
    /// Counting on the way out is what keeps the estimate honest in between.
    func testRequestsInFlightAreCountedBeforeTheyAnswer() async {
        let budget = DiscogsBudget()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.discogs.com/database/search")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["X-Discogs-Ratelimit-Remaining": "3", "X-Discogs-Ratelimit": "60"]
        )!
        await budget.record(response)

        for _ in 0..<3 { await budget.willIssue() }
        let room = await budget.hasRoom(for: .foreground)
        XCTAssertFalse(room, "Three sent against three left is nothing left")
    }

    /// A refusal is the one reading that is certainly true, and it has to
    /// outlast the request that produced it.
    func testARefusalStandsTheAppDown() async throws {
        let budget = DiscogsBudget()
        let client = DiscogsClient(
            transport: BudgetTransport(status: 429), token: "test", budget: budget)

        _ = try? await client.search("purelink", kind: .artist)

        let foreground = await budget.hasRoom(for: .foreground)
        XCTAssertFalse(foreground, "Sending into a refusal only earns another one")
    }

    /// A reading describes the minute it was taken in. Held against a later
    /// one it would leave the app permanently convinced it had no budget after
    /// any quiet spell — which is the failure this whole type exists to avoid,
    /// arrived at from the other direction.
    func testAReadingOlderThanTheWindowIsNotUsed() async {
        let budget = DiscogsBudget()
        let stale = HTTPURLResponse(
            url: URL(string: "https://api.discogs.com/database/search")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["X-Discogs-Ratelimit-Remaining": "0", "X-Discogs-Ratelimit": "60"]
        )!
        await budget.record(stale)
        let whileFresh = await budget.hasRoom(for: .foreground)
        XCTAssertFalse(whileFresh, "A reading from this minute is the one to believe")

        // The same reading, taken ninety seconds ago. It describes a window
        // that has since rolled and says nothing about this one.
        await budget.record(stale, at: .now - .seconds(90))
        let afterTheWindow = await budget.hasRoom(for: .foreground)
        XCTAssertTrue(afterTheWindow)
    }

    /// The test transports answer without these headers, and silence must not
    /// read as a budget of zero.
    func testAResponseWithoutHeadersChangesNothing() async throws {
        let budget = DiscogsBudget()
        let client = DiscogsClient(
            transport: BudgetTransport(), token: "test", budget: budget)

        for _ in 0..<5 { _ = try await client.search("skee mask", kind: .artist) }

        let foreground = await budget.hasRoom(for: .foreground)
        XCTAssertTrue(foreground, "No header is no information, not bad news")
    }

    /// And the whole point: a search that would be refused is never sent.
    func testASearchIsNotSentIntoAnEmptyBudget() async throws {
        let budget = DiscogsBudget()
        let transport = BudgetTransport(status: 429)
        let client = DiscogsClient(transport: transport, token: "test", budget: budget)

        _ = try? await client.search("purelink", kind: .artist)
        XCTAssertEqual(transport.counter.count, 1)

        // The store asks before spending, so the second search costs nothing.
        let room = await client.hasRoom(for: .foreground)
        XCTAssertFalse(room)
        XCTAssertEqual(transport.counter.count, 1, "Nothing further should have been sent")
    }
}

// MARK: - Which route a search takes

/// Searches go to Indigo's backend even where this build carries a Discogs
/// credential of its own, because that is the only route that is cached across
/// listeners and the only one that files what it finds into the catalogue.
/// These pin the two hazards that came with moving them.
final class DiscogsSearchRouteTests: XCTestCase {

    /// The search field prefers the backend even where there is a credential
    /// to hand, and keeps Discogs as the way out if the backend cannot answer.
    ///
    /// Nothing else does — and *nothing else* is the point. This was keyed on
    /// the `database/search` path at first, which also caught `artistHead`,
    /// `artistThumbnail`, `recommendations` and both `releaseID` lookups. Nine
    /// of those run when an artist page opens, and the page took a second
    /// longer to cache work nobody was waiting on.
    func testOnlyTheSearchFieldPrefersTheBackend() {
        XCTAssertEqual(
            DiscogsClient.route(preferringBackend: true, hasToken: true, hasBackend: true),
            .backendThenDirect,
            "Cached across listeners, and the only route that fills the catalogue"
        )
        XCTAssertEqual(
            DiscogsClient.route(preferringBackend: false, hasToken: true, hasBackend: true),
            .direct,
            "A page somebody is watching takes the quick route"
        )
    }

    /// With no credential there is nothing to fall back to, so the backend's
    /// failure is the answer rather than a detour.
    func testWithoutACredentialTheBackendIsTheOnlyRoute() {
        XCTAssertEqual(
            DiscogsClient.route(preferringBackend: true, hasToken: false, hasBackend: true),
            .backend
        )
        XCTAssertEqual(
            DiscogsClient.route(preferringBackend: false, hasToken: false, hasBackend: true),
            .backend
        )
    }

    /// And with no backend a search goes the old way rather than not at all.
    func testWithoutABackendASearchStillGoesToDiscogs() {
        XCTAssertEqual(
            DiscogsClient.route(preferringBackend: true, hasToken: true, hasBackend: false),
            .direct
        )
        XCTAssertEqual(
            DiscogsClient.route(preferringBackend: true, hasToken: false, hasBackend: false),
            .unconfigured
        )
    }

    /// The fallback actually runs: a client whose backend cannot answer still
    /// asks Discogs rather than reporting an absence.
    func testTheFallbackReachesDiscogs() async throws {
        let transport = BudgetTransport()
        // No gateway object at all, which is how `viaBackend` fails without a
        // network: `.backendThenDirect` is unreachable here, so this pins the
        // simpler half — a search with a credential and no backend is asked.
        let client = DiscogsClient(transport: transport, token: "test")

        _ = try await client.search("purelink", kind: .artist)
        XCTAssertEqual(transport.counter.count, 1, "The search still has to be asked somewhere")
    }

    /// A search routed through the backend travels on the server's credential
    /// and is usually answered from a cache, so this app's budget has no
    /// bearing on it. Refusing a free request because the portrait fill
    /// drained a budget it was never going to touch would be the original bug
    /// wearing the fix as a disguise.
    func testAnExhaustedBudgetDoesNotStopABackendSearch() async {
        let budget = DiscogsBudget()
        let refused = HTTPURLResponse(
            url: URL(string: "https://api.discogs.com/database/search")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["X-Discogs-Ratelimit-Remaining": "0", "X-Discogs-Ratelimit": "60"]
        )!
        await budget.record(refused)

        let withBackend = DiscogsClient(
            transport: BudgetTransport(), token: "test", budget: budget,
            gateway: CatalogDiscogsGateway(isEnabled: true)
        )
        let withoutBackend = DiscogsClient(
            transport: BudgetTransport(), token: "test", budget: budget)

        let backed = await withBackend.canSearch()
        let direct = await withoutBackend.canSearch()
        XCTAssertTrue(backed, "Nothing of ours is spent, so nothing of ours can be short")
        XCTAssertFalse(direct, "Going direct, the budget is the whole story")
    }
}
