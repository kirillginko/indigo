//
//  CrateRecommendationsTests.swift
//  IndigoTests
//
//  The DIG landing page's recommendations: music one step out of the crate
//  that the listener does not already have. Pinned here is what makes that
//  worth reading — nothing they keep, and nobody who is only another name
//  for somebody they keep.
//

import XCTest
import SwiftData
@testable import Indigo

final class CrateRecommendationsTests: XCTestCase {
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

    private func artist(_ name: String, id: Int, labels: [String] = ["Warp"], aliases: [String] = []) {
        let record = DiscogsArtist(nameKey: RecordingKey.normalizeArtist(name), discogsID: id, name: name)
        record.labelNames = labels
        record.styles = ["IDM"]
        record.aliasNames = aliases
        context.insert(record)
    }

    private func seed(_ name: String, crated: Int = 2) -> CrateSeed {
        CrateSeed(name: name, mbid: nil, crateCount: crated, libraryCount: 0)
    }

    private func recommend(_ seeds: [CrateSeed]) -> CrateRecommendations {
        CrateRecommendations.build(
            seeds: seeds,
            known: Set(seeds.map { RecordingKey.normalizeArtist($0.name) }),
            graph: GraphStore(context: context)
        )
    }

    private func everyArtist(_ found: CrateRecommendations) -> [String] {
        (found.forYou + found.shelves.flatMap(\.picks)).map(\.node.title)
    }

    /// The whole point: somebody they do not have yet, next to somebody
    /// they do.
    func testRecommendsTheNeighboursOfWhatIsKept() {
        artist("Aphex Twin", id: 1)
        artist("Autechre", id: 2)
        artist("Boards of Canada", id: 3)

        let found = recommend([seed("Aphex Twin"), seed("Autechre")])

        let pick = found.forYou.first { $0.node.title == "Boards of Canada" }
        XCTAssertNotNil(pick)
        XCTAssertEqual(Set(pick?.because ?? []), ["Aphex Twin", "Autechre"],
                       "Next to both, and it should say so")
        XCTAssertFalse(pick?.reason.isEmpty ?? true, "Every pick says what it rests on")
    }

    /// A recommendation of something already in the crate is a mirror.
    func testNothingAlreadyKeptIsRecommended() {
        artist("Aphex Twin", id: 1)
        artist("Autechre", id: 2)
        artist("Boards of Canada", id: 3)

        let names = everyArtist(recommend([seed("Aphex Twin"), seed("Autechre")]))
        XCTAssertFalse(names.contains("Autechre"))
        XCTAssertFalse(names.contains("Aphex Twin"))
    }

    /// AFX is Aphex Twin. It must not come back through Aphex Twin's alias
    /// edge, nor through Autechre sharing a label with it.
    func testAnAliasOfSomebodyKeptIsNotARecommendation() {
        artist("Aphex Twin", id: 1, aliases: ["AFX"])
        artist("AFX", id: 4, aliases: ["Aphex Twin"])
        artist("Autechre", id: 2)
        artist("Boards of Canada", id: 3)

        let found = recommend([seed("Aphex Twin"), seed("Autechre")])
        XCTAssertFalse(everyArtist(found).contains("AFX"))
        XCTAssertTrue(everyArtist(found).contains("Boards of Canada"))
    }

    /// The labels they keep returning to without knowing it.
    func testLabelsBehindTheCrateSayWhoIsOnThem() throws {
        artist("Aphex Twin", id: 1)
        artist("Autechre", id: 2)

        let found = recommend([seed("Aphex Twin"), seed("Autechre")])
        let warp = try XCTUnwrap(found.labels.first { $0.node.title == "Warp" })
        XCTAssertEqual(warp.because.count, 2)
    }

    /// Last launch's shelves are what the page opens on, so they have to
    /// come back exactly — pictures and reasons included.
    func testTheShelvesSurviveARelaunch() throws {
        artist("Aphex Twin", id: 1)
        artist("Autechre", id: 2)
        artist("Boards of Canada", id: 3)
        let found = recommend([seed("Aphex Twin"), seed("Autechre")])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CrateRecommendationsTests"))
        defer { defaults.removePersistentDomain(forName: "CrateRecommendationsTests") }

        found.save(in: defaults)
        let restored = try XCTUnwrap(CrateRecommendations.saved(in: defaults))
        XCTAssertEqual(restored.forYou, found.forYou)
        XCTAssertEqual(restored.shelves, found.shelves)
        XCTAssertEqual(restored.labels, found.labels)
    }

    func testNoSeedsMeansNothing() {
        artist("Aphex Twin", id: 1)
        XCTAssertTrue(recommend([]).isEmpty)
    }
}
