//
//  BackendBundlesTests.swift
//  IndigoTests
//
//  R2's artist bundles in the backend's shadow For You, against an R2 that is
//  a function in the test. What is pinned: a bundle is read only once its
//  digest checks out, kept by digest, and its reference asked for once a
//  generation; its relationships keep their kinds and their records; an
//  artist's other names are never offered as somebody new; an artist without
//  a bundle is reported, not filled in; and the SQL-only stage is exactly the
//  snapshot the shadow made before bundles existed.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class BackendBundlesTests: XCTestCase {
    private var directories: [URL] = []
    private let now = ExploreFixtures.asOf.addingTimeInterval(-3_600)

    override func tearDownWithError() throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    // MARK: A bundle, as the worker writes one

    private static let bundleJSON = """
    {"format":"indigo.artist-knowledge/1",
     "artist":{"discogsID":1982320,"name":"Anika (9)","nameKey":"anika"},
     "coverage":{"shelfEntries":3},
     "releases":[
       {"id":100,"masterID":null,"title":"Change","year":2021,"relation":"main","compilation":false},
       {"id":200,"masterID":null,"title":"Anika","year":2010,"relation":"main","compilation":false},
       {"id":300,"masterID":null,"title":"Glass","year":2019,"relation":"joint","compilation":false},
       {"id":400,"masterID":null,"title":"Remixes","year":2015,"relation":"track","compilation":false}],
     "styles":[{"name":"Post-Punk","releases":2}],
     "genres":[{"name":"Electronic","releases":3}],
     "stylesAround":[{"name":"Techno","releases":1}],
     "years":{"first":2010,"last":2021},
     "labels":[
       {"discogsID":98317,"name":"Sacred Bones Records","display":"Sacred Bones Records","releases":2,"placeholder":false,"ownName":false},
       {"discogsID":1217,"name":"Stones Throw Records","display":"Stones Throw Records","releases":1,"placeholder":false,"ownName":false},
       {"discogsID":750,"name":"Not On Label","display":"Not On Label","releases":1,"placeholder":true,"ownName":false},
       {"discogsID":9,"name":"Anika","display":"Anika","releases":1,"placeholder":false,"ownName":true}],
     "collaborators":[
       {"artist":{"discogsID":1000,"name":"Dave Clarke"},"how":["Vocals","joint"],"releases":[300]},
       {"artist":{"discogsID":2000,"name":"Exploded View (2)"},"how":["Remix"],"releases":[400]},
       {"artist":{"discogsID":3999072,"name":"Annika Henderson"},"how":["joint"],"releases":[300]},
       {"artist":{"discogsID":4000,"name":"Ehua"},"how":["TrackAppearance"],"releases":[400]},
       {"artist":{"discogsID":5000,"name":"Kode9"},"how":["Appearance","Written-By"],"releases":[400]}],
     "credits":[
       {"artist":{"discogsID":3000,"name":"Geoff Barrow"},"roles":[
          {"role":"Producer","kind":"production","releases":[{"id":200,"tracks":[]},{"id":100,"tracks":[]}]},
          {"role":"Drums","kind":"performance","releases":[{"id":200,"tracks":["A1","B2"]}]},
          {"role":"Photography By","kind":null,"releases":[{"id":200,"tracks":[]}]}]},
       {"artist":{"discogsID":3999072,"name":"Annika Henderson"},"roles":[
          {"role":"Co-producer","kind":"production","releases":[{"id":100,"tracks":[]}]}]}],
     "source":{"identity":"backend","discography":"d1","complete":true,"truncated":false,"totalReported":3,
               "pagesReported":1,"pagesFetched":1,"entries":3,"representativeReleases":3,"documentsRead":3,
               "documentsMissing":0,"documentsTruncated":0}}
    """

    private static var bundleData: Data { Data(bundleJSON.utf8) }
    private static var bundle: ArtistBundle { try! JSONDecoder().decode(ArtistBundle.self, from: bundleData) }

    nonisolated private static func refData(digest: String, artist: Int = 1982320) -> Data {
        Data("""
        {"artist":\(artist),"digest":"\(digest)","key":"knowledge/v1/bundles/\(digest.prefix(2))/\(digest).json",
         "builtAt":"2026-10-09T01:40:33.524Z","bytes":1234,"buildMs":10,"format":"indigo.artist-knowledge/1"}
        """.utf8)
    }

    /// R2 as a dictionary, remembering what it was asked for.
    private final class FakeR2: @unchecked Sendable {
        var objects: [String: Data] = [:]
        var reads: [String] = []
        var fail = false

        func read(_ key: String) async throws -> (status: Int, data: Data?) {
            reads.append(key)
            if fail { throw URLError(.notConnectedToInternet) }
            guard let data = objects[key] else { return (404, nil) }
            return (200, data)
        }

        func publish(_ data: Data, artist: Int) {
            let digest = BundleFetcher.digest(data)
            objects["knowledge/v1/bundles/\(digest.prefix(2))/\(digest).json"] = data
            objects["knowledge/v1/refs/artists/\(artist).json"] = refData(digest: digest, artist: artist)
        }
    }

    // MARK: Edges

    func testRelationshipsKeepTheirKindsAndTheRecordTheyRestOn() {
        let origin = MusicNode.artist("Anika")
        let edges = BundleEdges.edges(from: origin, bundle: Self.bundle, ownIdentities: [1982320, 3999072], sqlTargets: [])
        func edge(_ to: String, _ kind: RelationshipKind) -> [MusicEdge] {
            edges.filter { $0.to.title == to && $0.kind == kind }
        }

        XCTAssertEqual(edge("Dave Clarke", .collaborator).map(\.reason), ["Made Glass together"])
        XCTAssertEqual(edge("Exploded View", .collaborator).map(\.reason), ["Remix on Remixes"],
                       "a job on somebody else's record says which job")
        XCTAssertEqual(edge("Exploded View", .collaborator).first?.to.discogsID, 2000)
        // Being on somebody's mix, or having written a song on it, is a
        // record both are on -- not one they made together.
        XCTAssertEqual(edge("Ehua", .sameRelease).map(\.reason), ["Appears on Remixes"])
        XCTAssertEqual(edge("Kode9", .sameRelease).map(\.reason), ["Appears on Remixes"])
        XCTAssertTrue(edge("Ehua", .collaborator).isEmpty && edge("Kode9", .collaborator).isEmpty)
        XCTAssertFalse(edges.contains { $0.reason.contains("Appearance") }, "Discogs' shelf words are not explanations")
        // Production and the rest of the sleeve stay apart, the latest record
        // tells the story, and a sleeve credit is no relationship at all.
        XCTAssertEqual(edge("Geoff Barrow", .producer).map(\.reason), ["Producer on Change"])
        XCTAssertEqual(edge("Geoff Barrow", .producer).first?.occurrences, 2)
        XCTAssertEqual(edge("Geoff Barrow", .personnel).map(\.reason), ["Drums on Anika (A1, B2)"])
        XCTAssertFalse(edges.contains { $0.reason.hasPrefix("Photography") })
        XCTAssertTrue(edges.allSatisfy { $0.source == .discogs && $0.from == origin })
    }

    func testAnArtistsOtherNamesAreNeverOfferedAsSomebodyNew() {
        let origin = MusicNode.artist("Anika")
        let edges = BundleEdges.edges(from: origin, bundle: Self.bundle, ownIdentities: [1982320, 3999072], sqlTargets: [])
        XCTAssertFalse(edges.contains { $0.to.title == "Annika Henderson" },
                       "MusicBrainz says Annika Henderson is Anika; her own name is not a discovery")

        // Without the identity the backend knows, the bundle cannot tell --
        // which is why the backend's identities are passed in.
        let unaware = BundleEdges.edges(from: origin, bundle: Self.bundle, ownIdentities: [], sqlTargets: [])
        XCTAssertTrue(unaware.contains { $0.to.title == "Annika Henderson" })
    }

    func testLabelsFollowTheAppsRulesAndAreNotCountedTwice() {
        let origin = MusicNode.artist("Anika")
        let sql: Set<String> = [MusicNode.label("Stones Throw Records").id]
        let labels = BundleEdges.edges(from: origin, bundle: Self.bundle, ownIdentities: [], sqlTargets: sql)
            .filter { $0.kind == .sharedLabel }
        XCTAssertEqual(labels.map(\.to.title), ["Sacred Bones Records"],
                       "a placeholder, an own-name imprint and a label SQL already reaches are left out")
        XCTAssertEqual(labels.first?.to.discogsID, 98317)
        XCTAssertEqual(labels.first?.reason, "Releases on Sacred Bones Records")
    }

    // MARK: Fetching

    func testABundleIsReadOnceItsDigestChecksOutAndKeptByDigest() async {
        let r2 = FakeR2()
        r2.publish(Self.bundleData, artist: 1982320)
        var cache = BundleCache()

        let first = await BundleFetcher.refresh(&cache, discogsIDs: [1982320, 1982320], now: now, read: r2.read)
        XCTAssertEqual(first.reads, 2, "one reference, one bundle")
        XCTAssertEqual(first.errors, [])
        XCTAssertEqual(cache.bundles.count, 1)

        let again = await BundleFetcher.refresh(&cache, discogsIDs: [1982320], now: now, read: r2.read)
        XCTAssertEqual(again.reads, 0, "nothing is asked again within a generation")

        let later = await BundleFetcher.refresh(&cache, discogsIDs: [1982320], now: now.addingTimeInterval(3 * 3_600), read: r2.read)
        XCTAssertEqual(later.reads, 1, "the next generation asks for the reference only: the bundle is kept by digest")
    }

    func testABundleThatDoesNotMatchItsDigestIsRefused() async {
        let r2 = FakeR2()
        r2.publish(Self.bundleData, artist: 1982320)
        let key = r2.objects.keys.first { $0.hasPrefix("knowledge/v1/bundles/") }!
        r2.objects[key] = Data(Self.bundleJSON.replacingOccurrences(of: "Geoff Barrow", with: "Someone Else").utf8)
        var cache = BundleCache()

        let report = await BundleFetcher.refresh(&cache, discogsIDs: [1982320], now: now, read: r2.read)
        XCTAssertEqual(report.errors, ["bundle 1982320: digest mismatch"])
        XCTAssertTrue(cache.bundles.isEmpty)
        let status = BundleEdges.status(node: "artist:anika", discogsID: 1982320, kept: cache.refs["1982320"], cache: cache,
                                        generation: BackendKnowledgeCache.generation(at: now))
        XCTAssertEqual(status.status, "failed")
    }

    func testStatusesSayWhatIsMissingStaleOrPartial() async {
        let r2 = FakeR2()
        r2.publish(Self.bundleData, artist: 1982320)
        let partial = Self.bundleJSON
            .replacingOccurrences(of: "\"documentsMissing\":0", with: "\"documentsMissing\":2")
            .replacingOccurrences(of: "\"complete\":true", with: "\"complete\":false")
        r2.publish(Data(partial.replacingOccurrences(of: "1982320", with: "5").utf8), artist: 5)
        var cache = BundleCache()
        _ = await BundleFetcher.refresh(&cache, discogsIDs: [1982320, 5, 6], now: now, read: r2.read)
        let generation = BackendKnowledgeCache.generation(at: now)
        func status(_ id: Int, at generation: String) -> String {
            BundleEdges.status(node: "n", discogsID: id, kept: cache.refs[String(id)], cache: cache, generation: generation).status
        }

        XCTAssertEqual(status(1982320, at: generation), "complete")
        XCTAssertEqual(status(5, at: generation), "partial")
        XCTAssertTrue(BundleEdges.status(node: "n", discogsID: 5, kept: cache.refs["5"], cache: cache, generation: generation)
            .detail.contains("2 documents missing"))
        XCTAssertEqual(status(6, at: generation), "missing")
        XCTAssertEqual(status(7, at: generation), "failed", "never fetched")

        // Offline the next generation: kept, used, and said to be stale.
        r2.fail = true
        let later = now.addingTimeInterval(3 * 3_600)
        let report = await BundleFetcher.refresh(&cache, discogsIDs: [1982320], now: later, read: r2.read)
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(status(1982320, at: BackendKnowledgeCache.generation(at: later)), "complete, stale")
    }

    func testTheCacheKeepsOnlyBundlesAReferenceStillNames() async throws {
        let r2 = FakeR2()
        r2.publish(Self.bundleData, artist: 1982320)
        var cache = BundleCache()
        _ = await BundleFetcher.refresh(&cache, discogsIDs: [1982320], now: now, read: r2.read)
        cache.bundles["orphan"] = Self.bundle

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let url = directory.appendingPathComponent("bundles.json")
        cache.save(to: url)
        let loaded = BundleCache.load(from: url)
        XCTAssertEqual(Set(loaded.bundles.keys), [BundleFetcher.digest(Self.bundleData)])
        XCTAssertEqual(loaded.refs, cache.refs)
    }

    // MARK: Asking the backend by identity

    func testNodesCarryTheirIdentitiesOnlyWhenKnown() throws {
        let params = BackendKnowledgeFetcher.Params(pNodes: [
            .init(id: "artist:anika", kind: "artist", key: "anika", provider: "", handle: "",
                  mbid: "15c0e62b-0000-0000-0000-000000000000", discogsID: "1982320"),
            .init(id: "label:x", kind: "label", key: "x", provider: "", handle: ""),
        ], pArtists: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any])
        let nodes = try XCTUnwrap(json["p_nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes[0]["discogsID"] as? String, "1982320")
        XCTAssertEqual(nodes[0]["mbid"] as? String, "15c0e62b-0000-0000-0000-000000000000")
        XCTAssertNil(nodes[1]["discogsID"], "unknown identities are left out, never sent empty")
        XCTAssertNil(nodes[1]["mbid"])
    }

    func testAnswersBeforeIdentitiesStillDecode() throws {
        let old = try JSONDecoder().decode(BackendNodeAnswer.self, from: Data(#"{"status":"found","edges":[]}"#.utf8))
        XCTAssertNil(old.identities)
        XCTAssertEqual(old.cataloguedDiscogsIDs, [])

        let new = try JSONDecoder().decode(BackendNodeAnswer.self, from: Data(#"""
        {"status":"found","edges":[],"identities":[
          {"discogsID":"3999072","via":"musicbrainz","catalogued":false},
          {"discogsID":"1982320","via":"musicbrainz","catalogued":true}]}
        """#.utf8))
        XCTAssertEqual(new.cataloguedDiscogsIDs, [1982320])
        XCTAssertEqual(new.discogsIDs, [1982320, 3999072])
    }

    // MARK: Stages

    func testTheSQLStageIsTheSnapshotTheShadowMadeBeforeBundles() async throws {
        let container = try ExploreFixtures.store(ExploreFixtures.walk(), seed: 1, directories: &directories)
        let context = ModelContext(container)
        let personal = PersonalInputs.read(context: context, asOf: ExploreFixtures.asOf)
        let local = LocalKnowledgeAdapter(context: context).snapshot(for: personal, scenes: true)
        let origin = try XCTUnwrap(ExploreRanker.startingPoints(personal).first { $0.kind == .artist })

        var cache = BackendKnowledgeCache()
        let generation = BackendKnowledgeCache.generation(at: now)
        for node in ExploreRanker.startingPoints(personal) {
            let answer = BackendNodeAnswer(
                status: "found",
                edges: [BackendEdge(kind: "sharedLabel", reason: "Releases on Stones Throw Records", confidence: 0.88,
                                    occurrences: 1, to: BackendTarget(kind: "label", name: "Stones Throw Records",
                                                                      discogsID: "1217", year: nil, providerID: nil, handle: nil))],
                identities: node == origin
                    ? [BackendIdentity(discogsID: "1982320", via: "musicbrainz", catalogued: true),
                       BackendIdentity(discogsID: "3999072", via: "musicbrainz", catalogued: false)]
                    : []
            )
            cache.nodes[node.id] = .init(answer: answer, generation: generation, fetchedAt: now)
        }
        let r2 = FakeR2()
        r2.publish(Self.bundleData, artist: 1982320)
        var bundles = BundleCache()
        _ = await BundleFetcher.refresh(&bundles, discogsIDs: [1982320], now: now, read: r2.read)

        let (before, _) = BackendKnowledgeAdapter.snapshot(
            personal: personal, deviceLocal: local.deviceLocal, cache: cache, now: now)
        let (sql, _, statuses) = BackendKnowledgeAdapter.snapshot(
            personal: personal, deviceLocal: local.deviceLocal, cache: cache, now: now, bundles: bundles, use: .sqlOnly)
        XCTAssertEqual(CanonicalDigest.of(sql.shared), CanonicalDigest.of(before.shared))
        XCTAssertEqual(statuses.first { $0.node == origin.id }?.status, "complete",
                       "the SQL stage still reports how the bundles stand")
        XCTAssertTrue(statuses.contains { $0.status == "no-identity" })

        let (withBundles, _, _) = BackendKnowledgeAdapter.snapshot(
            personal: personal, deviceLocal: local.deviceLocal, cache: cache, now: now, bundles: bundles, use: .relationships)
        /// Every edge out of the starting points, as (destination, kind).
        func edges(_ shared: SharedKnowledge) -> [(to: String, kind: RelationshipKind)] {
            shared.neighbourhoods.flatMap(\.edges).map { (shared.nodes[$0.to].title, $0.kind) }
        }
        let added = edges(withBundles.shared).filter { [.producer, .personnel, .collaborator].contains($0.kind) }
        XCTAssertEqual(Set(added.map(\.to)), ["Dave Clarke", "Exploded View", "Geoff Barrow"])
        XCTAssertTrue(edges(withBundles.shared).contains { $0.to == "Ehua" && $0.kind == .sameRelease })
        XCTAssertFalse(edges(withBundles.shared).contains { $0.to == "Annika Henderson" })
        XCTAssertEqual(edges(withBundles.shared).filter { $0.to == "Stones Throw Records" }.count,
                       edges(sql.shared).filter { $0.to == "Stones Throw Records" }.count,
                       "a label SQL already gives is not added a second time")
        XCTAssertTrue(edges(withBundles.shared).contains { $0.to == "Sacred Bones Records" && $0.kind == .sharedLabel })
        XCTAssertEqual(withBundles.shared.artistTags, sql.shared.artistTags, "styles stay out until their own stage")
        XCTAssertEqual(withBundles.deviceLocal, local.deviceLocal)
    }
}
