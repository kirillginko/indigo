//
//  ForYouIdentityTests.swift
//  IndigoTests
//
//  For You on the identity graph DIG walks: one artist is one candidate, the
//  listener's known artists are kept out under identity and never by a name
//  namesakes share, and a starting point is walked again exactly when the
//  evidence its walk rested on changes — not when anything else does.
//

import XCTest
import SwiftData
@testable import Indigo

private let oneNation = #"""
{"id":1,"title":"One Nation","year":2010,"artists":[{"id":1874027,"name":"Hype Williams (2)"}],
 "extraartists":[{"id":2419343,"name":"Dean Blunt","anv":"Blunt","role":"Producer"}]}
"""#
private let blackMetal = #"""
{"id":3,"title":"Black Metal","year":2014,"artists":[{"id":2419343,"name":"Dean Blunt"}],
 "extraartists":[{"id":1053396,"name":"Joanne Robertson","role":"Vocals"}]}
"""#
private let tides = #"""
{"id":900,"title":"Tides","year":2021,"artists":[{"id":777,"name":"Ciro Vitiello"}],
 "extraartists":[{"id":1720124,"name":"Attilio Novellino","role":"Producer"}]}
"""#

@MainActor
final class ForYouIdentityTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let asOf = ExploreFixtures.asOf
    private var period: Int { ExplorePeriod.containing(asOf) }
    private let now = Date()

    override func setUpWithError() throws {
        IdentityChecks.shared.reset()
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        let enricher = DiscogsEnricher(context: context, client: DiscogsClient())
        for (json, id) in [(oneNation, 1), (blackMetal, 3), (tides, 900)] {
            enricher.store(try JSONDecoder().decode(DiscogsReleaseDetail.self, from: Data(json.utf8)), id: id)
        }
        func file(_ name: String, _ id: Int, releases: [(Int, String)]) {
            let record = DiscogsArtist(nameKey: RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(name)),
                                       discogsID: id, name: name)
            record.releaseTitles = releases.map(\.1); record.releaseDiscogsIDs = releases.map(\.0)
            record.releaseYears = releases.map { _ in "2015" }
            record.releaseImageURLStrings = releases.map { _ in "" }; record.releaseLabels = releases.map { _ in "" }
            context.insert(record)
        }
        file("Hype Williams (2)", 1874027, releases: [(1, "One Nation")])
        file("Dean Blunt", 2419343, releases: [(3, "Black Metal")])
        file("Ciro Vitiello", 777, releases: [(900, "Tides")])
        // What the listener has: two artists played, one crated.
        for (index, name) in ["Hype Williams", "Ciro Vitiello", "Dean Blunt"].enumerated() {
            context.insert(ListeningEvent(node: .artist(name), action: .played,
                                          at: ExploreFixtures.base.addingTimeInterval(Double(index) * 60),
                                          seconds: 1_200, completion: 1, tags: [], source: nil))
        }
        try context.save()
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private func run(_ worker: DigWorker, generation: Int) async -> ExploreRun {
        await worker.exploreRun(asOf: asOf, period: period, generation: generation, scenes: false, rebuild: false, now: now)
    }

    private func candidates(_ worker: DigWorker, _ run: ExploreRun) async -> [ExploreSuggestion] {
        let offers = await worker.exploreRecommendations(run, asOf: asOf)
        return offers.next + offers.artists + offers.shows
    }

    // MARK: Candidates

    func testAVerifiedArtistIsOneCandidateUnderTheirEntry() async throws {
        let worker = DigWorker(modelContainer: container)
        let first = await run(worker, generation: 0)
        let offered = await candidates(worker, first)

        let joanne = offered.filter { $0.node.title == "Joanne Robertson" }
        XCTAssertEqual(joanne.map(\.node.id), ["artist:discogs:1053396"], "Reached by a credit: offered as her entry, once")
        XCTAssertEqual(joanne.first?.node.destination, .digArtist(mbid: nil, name: "Joanne Robertson", discogsID: 1053396))
        var titles: [String: Int] = [:]
        for suggestion in offered where suggestion.node.kind == .artist { titles[suggestion.node.title, default: 0] += 1 }
        XCTAssertEqual(titles.filter { $0.value > 1 }, [:], "No artist offered twice")
    }

    /// Played as "Dean Blunt"; reached as "Blunt", his entry. Known either way.
    func testAnArtistTheListenerKnowsByNameIsNotOfferedUnderTheirEntry() async throws {
        let worker = DigWorker(modelContainer: container)
        let first = await run(worker, generation: 0)
        XCTAssertTrue(first.alsoKnown.contains("artist:discogs:2419343"))
        let offered = await candidates(worker, first)
        XCTAssertNil(offered.first { $0.node.discogsID == 2419343 || $0.node.title == "Dean Blunt" })
    }

    // MARK: When a walk is worked out again

    func testEvidenceAboutSomebodyElseKeepsEveryWalk() async throws {
        let worker = DigWorker(modelContainer: container)
        let first = await run(worker, generation: 0)

        ArtistIdentityStore(context: context).record(DiscogsSpellingCheck(
            spelling: "Somebody Else", verdict: .canonical([42]), resultCount: 1, results: [],
            facts: [DiscogsIdentityFacts(id: 42, name: "Somebody Else", realName: nil, nameVariations: [],
                                         aliases: [], groups: [], members: [])]))
        try context.save()
        let after = await run(worker, generation: 1)

        XCTAssertEqual(after.report.rebuilt, [], "Nothing walked again")
        XCTAssertEqual(after.stamp, first.stamp)
    }

    /// A check that places a name one walk reached, and then its removal: the
    /// walk is worked out again each time, and the stamp says so.
    func testEvidenceUnderAWalkWalksItAgainAndARemovalToo() async throws {
        let worker = DigWorker(modelContainer: container)
        let first = await run(worker, generation: 0)

        let identity = ArtistIdentityStore(context: context)
        identity.record(DiscogsSpellingCheck(
            spelling: "Attilio Novellino", verdict: .canonical([1720124]), resultCount: 1, results: [],
            facts: [DiscogsIdentityFacts(id: 1720124, name: "Attilio Novellino", realName: nil, nameVariations: [],
                                         aliases: [], groups: [], members: [])]))
        try context.save()
        let corrected = await run(worker, generation: 1)
        XCTAssertTrue(corrected.report.rebuilt.contains { $0.hasPrefix("identity") }, "\(corrected.report.rebuilt)")
        XCTAssertNotEqual(corrected.stamp.identity, first.stamp.identity)

        for record in try context.fetch(FetchDescriptor<ArtistSpellingRecord>()) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<DiscogsIdentityRecord>()) { context.delete(record) }
        try context.save()
        let removed = await run(worker, generation: 2)
        XCTAssertTrue(removed.report.rebuilt.contains { $0.hasPrefix("identity") })
        XCTAssertEqual(removed.stamp.identity, first.stamp.identity, "Back to the evidence it started from")
        XCTAssertEqual(removed.stamp.shared, first.stamp.shared)
    }

    /// Who the listener knows is its own part: the same walks, different
    /// history, a different known digest and the same identity one.
    func testKnownArtistsMoveWithoutTheGraph() async throws {
        let worker = DigWorker(modelContainer: container)
        let first = await run(worker, generation: 0)
        let identity = IdentityGraph(context: context)
        // Dean Blunt's walk reaches Joanne Robertson by her credit.
        let walks = [identity.neighbourhood(of: .artist("Dean Blunt", discogsID: 2419343))]

        var rows = first.rows
        rows.met.append(PersonalInputs.Met(node: .artist("Joanne Robertson"), weight: 1, lastAt: ExploreFixtures.base))
        let before = DigWorker.knownArtists(rows: first.rows, personal: identity.canonicalizer.canonical(first.rows),
                                            walks: walks, identity: identity)
        let after = DigWorker.knownArtists(rows: rows, personal: identity.canonicalizer.canonical(rows),
                                           walks: walks, identity: identity)
        XCTAssertFalse(before.alsoKnown.contains("artist:discogs:1053396"))
        XCTAssertTrue(after.alsoKnown.contains("artist:discogs:1053396"), "Heard by name, known as her entry")
        XCTAssertNotEqual(after.digest, before.digest)
    }

    // MARK: Determinism

    func testTheSameRowsAndEvidenceGiveTheSameStampAndOffers() async throws {
        let one = DigWorker(modelContainer: container)
        let two = DigWorker(modelContainer: container)
        let a = await run(one, generation: 0)
        let b = await run(two, generation: 7)
        XCTAssertEqual(a.stamp, b.stamp)
        let offeredA = await candidates(one, a)
        let offeredB = await candidates(two, b)
        XCTAssertEqual(offeredA.map(\.id), offeredB.map(\.id))
        XCTAssertEqual(offeredA.map(\.score.bitPattern), offeredB.map(\.score.bitPattern))
        XCTAssertEqual(a.stamp.format, 2)
    }

    /// The listener's rows are read under identity and never written.
    func testHistoryIsNotRewritten() async throws {
        let before = try context.fetch(FetchDescriptor<ListeningEvent>()).map(\.nodeKey).sorted()
        _ = await run(DigWorker(modelContainer: container), generation: 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ListeningEvent>()).map(\.nodeKey).sorted(), before)
    }
}
