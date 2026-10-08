//
//  BackendKnowledgeTests.swift
//  IndigoTests
//
//  The backend's For You, in shadow, against a backend that is a function in
//  the test. What is pinned: answers are kept by entity and generation, asked
//  for in bounded calls and only when missing or stale; a failure leaves a gap
//  that is visible and is never filled from this device's caches; the app's
//  own cleaning applies to what the backend says; and the comparison counts
//  what it claims to.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class BackendKnowledgeTests: XCTestCase {
    private var directories: [URL] = []
    private let now = ExploreFixtures.asOf.addingTimeInterval(-3_600)

    override func tearDownWithError() throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    private func personal() throws -> (PersonalInputs, KnowledgeSnapshot) {
        let container = try ExploreFixtures.store(ExploreFixtures.walk(), seed: 1, directories: &directories)
        let context = ModelContext(container)
        let personal = PersonalInputs.read(context: context, asOf: ExploreFixtures.asOf)
        return (personal, LocalKnowledgeAdapter(context: context).snapshot(for: personal, scenes: true))
    }

    /// A backend that answers every entity it is asked about, and remembers
    /// what it was asked.
    private final class FakeBackend: @unchecked Sendable {
        var calls: [BackendKnowledgeFetcher.Params] = []
        var fail = false
        var generation = BackendKnowledgeCache.generation(at: ExploreFixtures.asOf.addingTimeInterval(-3_600))

        func call(_ params: BackendKnowledgeFetcher.Params) async throws -> Data {
            calls.append(params)
            if fail { throw URLError(.notConnectedToInternet) }
            var nodes: [String: Any] = [:]
            for node in params.pNodes {
                nodes[node.id] = node.kind == "artist" ? [
                    "status": "found",
                    "edges": [
                        ["kind": "sharedLabel", "reason": "Releases on Not On Label", "confidence": 0.88, "occurrences": 1,
                         "to": ["kind": "label", "name": "Not On Label (Self-released)"]],
                        ["kind": "sharedLabel", "reason": "Releases on Stroom", "confidence": 0.88, "occurrences": 1,
                         "to": ["kind": "label", "name": "Stroom (2)"]],
                        ["kind": "sharedLabel", "reason": "Both release on Stroom", "confidence": 0.8, "occurrences": 1,
                         "to": ["kind": "artist", "name": "Martyna Basta*"]],
                        ["kind": "frequentlyPlayedNearby", "reason": "Played next to each other on the radio", "confidence": 0.65,
                         "occurrences": 1, "to": ["kind": "artist", "name": "Various"]],
                    ],
                ] : ["status": node.kind == "station" ? "unsupported" : "unknown", "edges": []]
            }
            var artists: [String: Any] = [:]
            for key in params.pArtists {
                artists[key] = [
                    "status": "found",
                    "episodes": [["providerID": "nts", "showID": "hdb/hdb-backend", "title": "Hyperdub Backend",
                                  "image": "https://media.example/backend.jpg", "genres": ["Dubstep", "Ambient"]]],
                    "rosters": [["place": "London", "sound": "Dubstep", "members": 40]],
                    "genres": ["Ambient", "Dubstep"],
                ]
            }
            let body: [String: Any] = [
                "format": 1, "asOf": "2026-10-08T00:00:00Z", "generation": generation,
                "nextGenerationAt": "2026-10-08T03:23:00Z", "nodes": nodes, "artists": artists,
            ]
            return try JSONSerialization.data(withJSONObject: body)
        }
    }

    // MARK: Asking

    func testLargeAsksAreSplitWithinTheFunctionsBounds() async {
        let backend = FakeBackend()
        var cache = BackendKnowledgeCache()
        let nodes = (0..<13).map { MusicNode.artist("Artist \($0)") }
        let artists = (0..<120).map { "artist \($0)" }
        let report = await BackendKnowledgeFetcher.refresh(&cache, nodes: nodes, artists: artists, now: now, call: backend.call)
        XCTAssertEqual(backend.calls.count, 3)
        XCTAssertTrue(backend.calls.allSatisfy { $0.pNodes.count <= 12 && $0.pArtists.count <= 50 })
        XCTAssertEqual(backend.calls.map(\.pNodes.count).reduce(0, +), 13)
        XCTAssertEqual(backend.calls.map(\.pArtists.count).reduce(0, +), 120)
        XCTAssertEqual(report.calls, 3)
        XCTAssertEqual(cache.nodes.count, 13)
        XCTAssertEqual(cache.artists.count, 120)
    }

    /// The point of keeping answers by entity: a second look in the same
    /// generation asks for nothing, and a play that does not change the
    /// starting points asks for nothing either.
    func testKeptAnswersAreNotAskedForAgainInTheSameGeneration() async throws {
        let (personal, local) = try personal()
        let backend = FakeBackend()
        var cache = BackendKnowledgeCache()
        let origins = ExploreRanker.startingPoints(personal)
        let artists = BackendKnowledgeAdapter.artistsWanted(personal, deviceLocal: local.deviceLocal)
        _ = await BackendKnowledgeFetcher.refresh(&cache, nodes: origins, artists: artists, now: now, call: backend.call)
        let first = backend.calls.count
        XCTAssertGreaterThan(first, 0)

        let again = await BackendKnowledgeFetcher.refresh(&cache, nodes: origins, artists: artists, now: now, call: backend.call)
        XCTAssertEqual(backend.calls.count, first)
        XCTAssertEqual(again.calls, 0)
        XCTAssertEqual(again.nodesKept, origins.count)

        // The next edge generation: everything is asked for again.
        let later = now.addingTimeInterval(3 * 60 * 60)
        backend.generation = BackendKnowledgeCache.generation(at: later)
        let next = await BackendKnowledgeFetcher.refresh(&cache, nodes: origins, artists: artists, now: later, call: backend.call)
        XCTAssertGreaterThan(next.calls, 0)
        XCTAssertEqual(next.nodesAsked, origins.count)
    }

    // MARK: The snapshot

    func testTheAppsOwnCleaningAppliesToWhatTheBackendSays() async throws {
        let (personal, local) = try personal()
        let backend = FakeBackend()
        var cache = BackendKnowledgeCache()
        _ = await BackendKnowledgeFetcher.refresh(
            &cache, nodes: ExploreRanker.startingPoints(personal),
            artists: BackendKnowledgeAdapter.artistsWanted(personal, deviceLocal: local.deviceLocal), now: now, call: backend.call)
        let (snapshot, coverage) = BackendKnowledgeAdapter.snapshot(personal: personal, deviceLocal: local.deviceLocal, cache: cache, now: now)

        let titles = Set(snapshot.shared.nodes.map(\.title))
        XCTAssertTrue(titles.contains("Stroom"), "the disambiguator is stripped")
        XCTAssertFalse(titles.contains { $0.hasPrefix("Not On Label") }, "a placeholder is not a label")
        XCTAssertTrue(titles.contains("Martyna Basta"), "the asterisk is stripped")
        XCTAssertFalse(titles.contains("Various"), "a placeholder is not an artist")

        // Shows from the kept artists' broadcasts, named by the listener's own
        // spelling, tagged with the broadcasts' genres.
        let show = try XCTUnwrap(snapshot.shared.shows.first)
        XCTAssertEqual(show.title, "Hyperdub Backend")
        XCTAssertEqual(show.tags, ["ambient", "dubstep"])
        XCTAssertTrue(show.artists.contains("Burial"))
        // A scene from the footholds' rosters.
        XCTAssertEqual(snapshot.shared.scenes?.cities.first?.key, "london")
        XCTAssertEqual(snapshot.shared.scenes?.cities.first?.scenes.first?.artistCount, 40)
        // The device's own part is the visible ranking's, untouched.
        XCTAssertEqual(snapshot.deviceLocal, local.deviceLocal)
        XCTAssertEqual(coverage.artistsMissing, 0)
        XCTAssertTrue(coverage.startingPoints.values.contains("found"))
    }

    /// Offline, nothing is filled in from this device's caches: the starting
    /// points are missing, and the snapshot has no neighbourhoods for them.
    func testAFailedCallLeavesAVisibleGapRatherThanTheDevicesKnowledge() async throws {
        let (personal, local) = try personal()
        let backend = FakeBackend()
        backend.fail = true
        var cache = BackendKnowledgeCache()
        let report = await BackendKnowledgeFetcher.refresh(
            &cache, nodes: ExploreRanker.startingPoints(personal),
            artists: BackendKnowledgeAdapter.artistsWanted(personal, deviceLocal: local.deviceLocal), now: now, call: backend.call)
        XCTAssertFalse(report.errors.isEmpty)
        let (snapshot, coverage) = BackendKnowledgeAdapter.snapshot(personal: personal, deviceLocal: local.deviceLocal, cache: cache, now: now)
        XCTAssertTrue(coverage.startingPoints.values.allSatisfy { $0 == "missing" })
        XCTAssertTrue(snapshot.shared.neighbourhoods.allSatisfy(\.edges.isEmpty))
        XCTAssertTrue(snapshot.shared.shows.isEmpty)
        XCTAssertNotEqual(CanonicalDigest.of(snapshot.shared), CanonicalDigest.of(local.shared))
    }

    /// An answer from an older generation is used, and said to be stale.
    func testAStaleAnswerIsUsedAndSaidToBeStale() async throws {
        let (personal, local) = try personal()
        let backend = FakeBackend()
        var cache = BackendKnowledgeCache()
        let origins = ExploreRanker.startingPoints(personal)
        let artists = BackendKnowledgeAdapter.artistsWanted(personal, deviceLocal: local.deviceLocal)
        _ = await BackendKnowledgeFetcher.refresh(&cache, nodes: origins, artists: artists, now: now, call: backend.call)

        let later = now.addingTimeInterval(3 * 60 * 60)
        backend.fail = true
        _ = await BackendKnowledgeFetcher.refresh(&cache, nodes: origins, artists: artists, now: later, call: backend.call)
        let (snapshot, coverage) = BackendKnowledgeAdapter.snapshot(personal: personal, deviceLocal: local.deviceLocal, cache: cache, now: later)
        XCTAssertGreaterThan(coverage.staleAnswers, 0)
        XCTAssertTrue(coverage.startingPoints.values.contains { $0.hasSuffix("stale") })
        XCTAssertFalse(snapshot.shared.shows.isEmpty, "stale knowledge is still knowledge")
    }

    func testTheCacheSurvivesBeingWrittenDown() async throws {
        let backend = FakeBackend()
        var cache = BackendKnowledgeCache()
        _ = await BackendKnowledgeFetcher.refresh(&cache, nodes: [.artist("Burial")], artists: ["burial"], now: now, call: backend.call)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backend-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        cache.save(to: url)
        XCTAssertEqual(BackendKnowledgeCache.load(from: url), cache)
    }

    // MARK: Comparing

    func testTheComparisonCountsWhatItSays() async throws {
        let (personal, local) = try personal()
        let backend = FakeBackend()
        var cache = BackendKnowledgeCache()
        _ = await BackendKnowledgeFetcher.refresh(
            &cache, nodes: ExploreRanker.startingPoints(personal),
            artists: BackendKnowledgeAdapter.artistsWanted(personal, deviceLocal: local.deviceLocal), now: now, call: backend.call)
        let (snapshot, _) = BackendKnowledgeAdapter.snapshot(personal: personal, deviceLocal: local.deviceLocal, cache: cache, now: now)
        let asOf = ExploreFixtures.asOf
        let visible = ShadowComparison.ranking(personal: personal, knowledge: local, asOf: asOf, turn: 0)
        let shadow = ShadowComparison.ranking(personal: personal, knowledge: snapshot, asOf: asOf, turn: 0)

        // Against itself: everything overlaps and nothing is missing.
        let same = ShadowComparison.compare(visible: visible, backend: visible, backendKnowledge: local)
        XCTAssertEqual(same.top12Overlap, min(12, visible.next.count))
        XCTAssertEqual(same.top20Overlap, min(20, visible.all.count))
        XCTAssertTrue(same.reworded.isEmpty)
        XCTAssertTrue(same.missingKinds.isEmpty)

        // Against the fake backend, which knows labels and radio but no
        // credits or styles: those are the missing kinds.
        let compared = ShadowComparison.compare(visible: visible, backend: shadow, backendKnowledge: snapshot)
        let visibleKinds = Set(visible.all.prefix(20).map(\.kind.rawValue))
        XCTAssertEqual(Set(compared.missingKinds), visibleKinds.subtracting(["sharedLabel", "playedInShow", "frequentlyPlayedNearby"]))
        XCTAssertEqual(compared.moves.count, Set(visible.all.prefix(20).map(\.id)).union(shadow.all.prefix(20).map(\.id)).count)
    }
}
