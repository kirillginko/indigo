//
//  ExploreGoldenTests.swift
//  IndigoTests
//
//  What For You offers for three fixed collections, pinned field by field and
//  score by score. Captured from the engine before it was split into inputs, a
//  knowledge snapshot and a pure ranker (b774467), so the split is required to
//  change nothing at all: every offer, show, artist, reason, route, score bit,
//  taste weight, scene direction and the order of each.
//
//  To capture again after a deliberate change, run with
//  `TEST_RUNNER_INDIGO_EXPLORE_GOLDEN_OUT=golden.swift` and copy the file the
//  test host writes into its temporary directory over `ExploreGolden.swift`.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ExploreGoldenTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDownWithError() throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    /// Everything For You draws or ranks on, for one store.
    static func lines(_ container: ModelContainer) -> [String] {
        let asOf = ExploreFixtures.asOf
        let context = ModelContext(container)
        func line(_ block: String, _ suggestion: ExploreSuggestion) -> String {
            let node = suggestion.node
            return [block, suggestion.id, node.title, node.subtitle ?? "-", suggestion.reason, suggestion.via,
                    suggestion.kind.rawValue, String(suggestion.corroboration),
                    String(suggestion.score.bitPattern), node.artworkURL?.absoluteString ?? "-",
                    node.mbid ?? "-", node.discogsID.map { String($0) } ?? "-",
                    node.providerID ?? "-", node.handle ?? "-"]
                .joined(separator: " | ")
        }
        let engine = ExploreSuggestionEngine(context: context)
        let offers = engine.offers(asOf: asOf)
        var out = offers.next.map { line("next", $0) }
            + offers.shows.map { line("show", $0) }
            + offers.artists.map { line("artist", $0) }
            + [offers.movingToward.map { "toward | \($0.city) | \($0.title) | \($0.sound) | \($0.size)" } ?? "toward | -"]
        out += engine.suggestions(limit: 1_000, asOf: asOf).map { line("all", $0) }

        let taste = TasteProfile.collected(context: context, now: asOf)
        out.append("evidence | \(taste.evidence.bitPattern)")
        out += taste.top(1_000).map { "taste | \($0.interest) | \($0.weight.bitPattern)" }

        let found = Self.directions(context, asOf: asOf)
        out += found.map { scene in
            ["scene", scene.id, scene.city, scene.title, scene.soundLabel, scene.sizeLine,
             scene.signature.joined(separator: ","), scene.tags.joined(separator: ","),
             "\(scene.artists.count)", "\(scene.crateCount + scene.libraryTrackCount)"]
                .joined(separator: " | ")
        }
        let period = ExplorePeriod.containing(asOf)
        out += (period..<(period + 7)).map {
            "day \($0 - period) | " + (SceneEngine.pickDirection(found, turn: $0)?.id ?? "-")
        }
        return out
    }

    /// The directions For You chooses from.
    static func directions(_ context: ModelContext, asOf: Date) -> [MusicScene] {
        SceneEngine(context: context).directions(taste: TasteProfile.collected(context: context, now: asOf))
    }

    /// The ranker's own directions, written as the golden lines write the
    /// store's: the ones For You names now, held to the ones it named before.
    static func rankerDirections(_ container: ModelContainer) -> [String] {
        let context = ModelContext(container)
        let asOf = ExploreFixtures.asOf
        let personal = PersonalInputs.read(context: context, asOf: asOf)
        let knowledge = LocalKnowledgeAdapter(context: context).snapshot(for: personal, scenes: true)
        let taste = ExploreRanker.taste(personal: personal, knowledge: knowledge, asOf: asOf)
        let found = ExploreRanker.scoredDirections(personal: personal, knowledge: knowledge, taste: taste)
        let period = ExplorePeriod.containing(asOf)
        return found.map { scene, foothold, _ in
            ["scene", scene.id, scene.city, scene.city.uppercased(), scene.soundLabel, scene.sizeLine,
             scene.signature.joined(separator: ","), scene.tags.joined(separator: ","),
             "\(scene.artistCount)", "\(foothold)"]
                .joined(separator: " | ")
        } + (period..<(period + 7)).map {
            "day \($0 - period) | " + (SceneEngine.pickDirection(found.map(\.scene), turn: $0)?.id ?? "-")
        }
    }

    private func check(_ name: String, _ writes: [ExploreFixtures.Write], against golden: [String]) throws {
        let container = try ExploreFixtures.store(writes, seed: 1, directories: &directories)
        let ranked = Self.rankerDirections(container)
        XCTAssertEqual(ranked, golden.filter { $0.hasPrefix("scene |") || $0.hasPrefix("day ") },
                       "\(name): the ranker's directions differ from the store's")
        let found = Self.lines(container)
        if let file = ProcessInfo.processInfo.environment["INDIGO_EXPLORE_GOLDEN_OUT"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(file)")
            let literal = found.map { "        " + String(reflecting: $0) + "," }.joined(separator: "\n")
            try "    static let \(name): [String] = [\n\(literal)\n    ]\n".write(to: url, atomically: true, encoding: .utf8)
        }
        XCTAssertFalse(found.isEmpty)
        XCTAssertEqual(found.count, golden.count, "\(name): a different number of lines")
        for (index, (got, want)) in zip(found, golden).enumerated() where got != want {
            XCTFail("\(name) line \(index):\n  got  \(got)\n  want \(want)")
        }
    }

    func testTheWalkIsExactlyAsItWas() throws {
        try check("walk", ExploreFixtures.walk(), against: ExploreGolden.walk)
    }

    func testTheScenesAreExactlyAsTheyWere() throws {
        try check("scenes", ExploreFixtures.scenes(), against: ExploreGolden.scenes)
    }

    func testTheLibraryIsExactlyAsItWas() throws {
        try check("library", ExploreFixtures.library(), against: ExploreGolden.library)
    }
}
