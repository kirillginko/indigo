//
//  ExploreSnapshotTests.swift
//  IndigoTests
//
//  For You split into three: the listener's rows, a knowledge snapshot, and a
//  ranker that reads nothing else. What is pinned here is what the split is
//  for -- that the ranker's answer is a function of two values that can be
//  written down, digested and compared between devices, and that the part of
//  them only one device can know is identifiable on its own.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ExploreSnapshotTests: XCTestCase {
    private var directories: [URL] = []
    private let asOf = ExploreFixtures.asOf

    override func tearDownWithError() throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    private func inputs(_ container: ModelContainer) -> (PersonalInputs, KnowledgeSnapshot) {
        let context = ModelContext(container)
        let personal = PersonalInputs.read(context: context, asOf: asOf)
        return (personal, LocalKnowledgeAdapter(context: context).snapshot(for: personal, scenes: true))
    }

    /// The page's offers and the raw ranking, every field.
    private func ranked(_ personal: PersonalInputs, _ knowledge: KnowledgeSnapshot) -> [String] {
        func line(_ suggestion: ExploreSuggestion) -> String {
            [suggestion.id, suggestion.node.title, suggestion.reason, suggestion.via, suggestion.kind.rawValue,
             String(suggestion.corroboration), String(suggestion.score.bitPattern),
             suggestion.node.artworkURL?.absoluteString ?? "-"].joined(separator: " | ")
        }
        let offers = ExploreRanker.offers(personal: personal, knowledge: knowledge, asOf: asOf)
        let taste = ExploreRanker.taste(personal: personal, knowledge: knowledge, asOf: asOf)
        return ExploreDiagnostics.Entry.ranked(offers)
            + ExploreRanker.suggestions(personal: personal, knowledge: knowledge, taste: taste, limit: 1_000).map(line)
            + ExploreRanker.directions(personal: personal, knowledge: knowledge, taste: taste).map(\.id)
    }

    // MARK: The ranker reads only its arguments

    /// Written out, read back, and ranked again with nothing behind the
    /// values -- no store, no cache -- the answer is the same to the bit. If
    /// the ranker read anything but its arguments, the copy could not know it.
    func testTheRankerNeedsNothingButItsArguments() throws {
        for writes in [ExploreFixtures.walk(), ExploreFixtures.scenes(), ExploreFixtures.library()] {
            let (personal, knowledge) = inputs(try ExploreFixtures.store(writes, seed: 5, directories: &directories))
            let expected = ranked(personal, knowledge)
            XCTAssertGreaterThan(expected.count, 1)

            let encoder = JSONEncoder()
            let copiedPersonal = try JSONDecoder().decode(PersonalInputs.self, from: encoder.encode(personal))
            let copiedKnowledge = try JSONDecoder().decode(KnowledgeSnapshot.self, from: encoder.encode(knowledge))
            XCTAssertEqual(copiedPersonal, personal)
            XCTAssertEqual(copiedKnowledge, knowledge)
            XCTAssertEqual(CanonicalDigest.of(copiedKnowledge), CanonicalDigest.of(knowledge))
            XCTAssertEqual(ranked(copiedPersonal, copiedKnowledge), expected)
        }
    }

    // MARK: Stamps

    /// The same collection filed in any order is the same stamp, part by
    /// part. A device that holds the same rows says so.
    func testTheSameCollectionFiledInAnyOrderHasTheSameStamp() throws {
        for writes in [ExploreFixtures.walk(), ExploreFixtures.scenes(), ExploreFixtures.library()] {
            var first: ExploreStamp?
            for seed in UInt64(1)...6 {
                let (personal, knowledge) = inputs(try ExploreFixtures.store(writes, seed: seed, directories: &directories))
                let stamp = ExploreStamp(period: ExplorePeriod.containing(asOf), personal: personal, knowledge: knowledge)
                if let first { XCTAssertEqual(stamp, first, "filing order \(seed) changed the stamp") } else { first = stamp }
            }
        }
    }

    /// The fixtures' digests, written down. The same on every platform the
    /// tests run on: this file runs unchanged on macOS and on an iOS
    /// simulator, and both must arrive at these strings.
    func testTheDigestsAreTheSameOnEveryPlatform() throws {
        let (personal, knowledge) = inputs(try ExploreFixtures.store(ExploreFixtures.library(), seed: 1, directories: &directories))
        let stamp = ExploreStamp(period: ExplorePeriod.containing(asOf), personal: personal, knowledge: knowledge)
        if let name = ProcessInfo.processInfo.environment["INDIGO_EXPLORE_STAMP_OUT"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try "\(stamp.personal)\n\(stamp.shared)\n\(stamp.deviceLocal)\n".write(to: url, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(stamp.personal, Self.libraryDigests.personal)
        XCTAssertEqual(stamp.shared, Self.libraryDigests.shared)
        XCTAssertEqual(stamp.deviceLocal, Self.libraryDigests.deviceLocal)
        // A value small enough to check by hand.
        XCTAssertEqual(CanonicalDigest.of(["b": 2, "a": 1]), Self.smallDigest)
    }

    /// Captured on macOS; the iOS simulator run must agree.
    static let libraryDigests = (
        personal: "8485f52fbaa6fe70cb3d041874e364dbb1cb69fd65bcbcdbad37753249bbf9e9",
        shared: "c4cdd6ecdf8bcd39d1a24eff96f2915c409bd26376d7fb1b2ff60192597df2c9",
        deviceLocal: "03ef90a5d05de2378177fbcff76511fdb827cf372e23d8e76bddae4cc4986336"
    )
    static let smallDigest = "cf9a8079e8486abf94cbe596355eca43d58566362a7340604b012da94bc9063f"

    // MARK: Canonical encoding

    func testDictionaryOrderDoesNotReachTheDigest() {
        var one: [String: Int] = [:]
        var two: [String: Int] = [:]
        for key in (0..<200).map({ "key\($0)" }) { one[key] = key.count }
        for key in (0..<200).map({ "key\($0)" }).reversed() { two[key] = key.count }
        XCTAssertEqual(CanonicalDigest.of(one), CanonicalDigest.of(two))
    }

    /// "Köln" typed one way and stored another is one name to Swift, and so
    /// one name to the digest.
    func testTheTwoSpellingsOfOneCharacterAreOneString() {
        let composed = "K\u{00F6}ln"
        let decomposed = "Ko\u{0308}ln"
        XCTAssertEqual(composed, decomposed)
        XCTAssertEqual(CanonicalDigest.of([composed]), CanonicalDigest.of([decomposed]))
        XCTAssertEqual(CanonicalDigest.of([composed: 1]), CanonicalDigest.of([decomposed: 1]))
    }

    func testZeroAndNotANumberHaveOneSpellingEach() {
        XCTAssertEqual(CanonicalDigest.of([0.0]), CanonicalDigest.of([-0.0]))
        XCTAssertEqual(CanonicalDigest.of([Double.nan]), CanonicalDigest.of([-Double.nan]))
        XCTAssertNotEqual(CanonicalDigest.of([0.1 + 0.2]), CanonicalDigest.of([0.3]), "doubles are their bits, not a rounding")
    }

    func testDifferentValuesHaveDifferentDigests() {
        XCTAssertNotEqual(CanonicalDigest.of(["a", "b"]), CanonicalDigest.of(["b", "a"]), "arrays keep their order")
        XCTAssertNotEqual(CanonicalDigest.of(["ab"]), CanonicalDigest.of(["a", "b"]), "lengths are written")
        XCTAssertNotEqual(CanonicalDigest.of([1]), CanonicalDigest.of([1.0]), "types are written")
        XCTAssertNotEqual(CanonicalDigest.of(PersonalInputs.empty), CanonicalDigest.of(KnowledgeSnapshot.empty.shared))
        let date = Date(timeIntervalSince1970: 1_000)
        XCTAssertNotEqual(CanonicalDigest.of([date]), CanonicalDigest.of([date.addingTimeInterval(0.001)]))
    }

    // MARK: What only this device knows

    /// Leaving the library out changes exactly the suggestions and scenes
    /// that rest on it -- here Arca and Ikonika, reached only through the
    /// files, and the Caracas scene the listener has a foot in only through
    /// them -- and nothing else, field for field and in the same order. Kode9
    /// is reached through the library too, but on a stronger shared route
    /// (Hyperdub) from the same starting point, so it does not change at all.
    func testLeavingTheDevicesOwnKnowledgeOutChangesOnlyWhatRestsOnIt() throws {
        let (personal, knowledge) = inputs(try ExploreFixtures.store(ExploreFixtures.library(), seed: 1, directories: &directories))
        var shared = knowledge
        shared.deviceLocal = .empty
        XCTAssertNotEqual(CanonicalDigest.of(knowledge.deviceLocal), CanonicalDigest.of(shared.deviceLocal))
        XCTAssertEqual(CanonicalDigest.of(knowledge.shared), CanonicalDigest.of(shared.shared), "the shared part is untouched")

        // What the library reaches: every destination of its edges.
        let local = knowledge.deviceLocal
        let reached = Set(local.neighbourhoods.flatMap(\.edges).map { local.nodes[$0.to].id })
        XCTAssertFalse(reached.isEmpty)

        let taste = ExploreRanker.taste(personal: personal, knowledge: knowledge, asOf: asOf)
        let all = ExploreRanker.suggestions(personal: personal, knowledge: knowledge, taste: taste, limit: 1_000)
        let without = ExploreRanker.suggestions(personal: personal, knowledge: shared, taste: taste, limit: 1_000)
        func lines(_ list: [ExploreSuggestion]) -> [String] {
            list.map { "\($0.id) | \($0.reason) | \($0.via) | \($0.corroboration) | \($0.score.bitPattern)" }
        }
        XCTAssertEqual(reached, ["artist:arca", "artist:ikonika", "artist:kode9"])
        // Nothing the library does not reach moves, in content or order.
        XCTAssertEqual(lines(without.filter { !reached.contains($0.id) }), lines(all.filter { !reached.contains($0.id) }))
        // What only the library reaches is gone, and was offered on its edge.
        let only = all.filter { ["artist:arca", "artist:ikonika"].contains($0.id) }
        XCTAssertEqual(only.count, 2)
        XCTAssertTrue(only.allSatisfy { $0.kind == .sharedCollection })
        XCTAssertFalse(without.contains { ["artist:arca", "artist:ikonika"].contains($0.id) })
        // And what the library reaches but does not decide is untouched.
        XCTAssertEqual(lines(without.filter { $0.id == "artist:kode9" }), lines(all.filter { $0.id == "artist:kode9" }))

        // Scenes: the ones with a foot in them only through the library go.
        let scenes = ExploreRanker.directions(personal: personal, knowledge: knowledge, taste: taste).map(\.id)
        let scenesWithout = ExploreRanker.directions(personal: personal, knowledge: shared, taste: taste).map(\.id)
        XCTAssertTrue(scenes.contains("caracas|"))
        XCTAssertEqual(scenesWithout, scenes.filter { $0 != "caracas|" })
    }

    /// A collection with no library has nothing device-local, so two devices
    /// without one agree on that part by construction.
    func testNoLibraryIsAnEmptyDeviceLocalPart() throws {
        let (_, knowledge) = inputs(try ExploreFixtures.store(ExploreFixtures.walk(), seed: 1, directories: &directories))
        XCTAssertEqual(knowledge.deviceLocal, .empty)
    }

    // MARK: Scope

    /// A play or an edit changes the listener's rows, not what is known about
    /// music. The neighbourhoods are kept for every starting point that is
    /// still one; only a new starting point is walked.
    func testKnowledgeIsKeptWhenOnlyTheListenersRowsChange() async throws {
        let container = try ExploreFixtures.store(ExploreFixtures.walk(), seed: 1, directories: &directories)
        let worker = DigWorker(modelContainer: container)
        let period = ExplorePeriod.containing(asOf)
        let now = Date()

        let first = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: true, rebuild: false, now: now)
        XCTAssertTrue(first.report.rebuilt.contains { $0.hasPrefix("neighbourhoods") })
        XCTAssertTrue(first.report.rebuilt.contains("scenes"))

        // The same rows again: nothing is worked out, and the stamp is the same.
        let again = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: true, rebuild: false, now: now)
        XCTAssertEqual(again.report.rebuilt, [])
        XCTAssertEqual(again.stamp, first.stamp)

        // An edit to a crated record: a new personal digest, the same knowledge.
        let context = ModelContext(container)
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<CrateItem>()).first)
        item.genreTagsRaw = "dub"
        try context.save()
        let edited = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: true, rebuild: false, now: now)
        XCTAssertEqual(edited.report.rebuilt, [])
        XCTAssertNotEqual(edited.stamp.personal, first.stamp.personal)
        XCTAssertEqual(edited.stamp.shared, first.stamp.shared)

        // A play of somebody new is a new starting point: that one is walked.
        context.insert(ListeningEvent(node: .artist("Tirzah"), action: .played, at: ExploreFixtures.base,
                                      seconds: 1_200, completion: 1, tags: [], source: nil))
        try context.save()
        let played = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: true, rebuild: false, now: now)
        XCTAssertEqual(played.report.rebuilt.filter { $0.hasPrefix("neighbourhoods") }, ["neighbourhoods 1/9"])
        XCTAssertFalse(played.report.rebuilt.contains("scenes"))

        // And a quarter of an hour later everything is worked out again.
        let later = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: true, rebuild: false,
                                            now: now.addingTimeInterval(DigWorker.knowledgeLifetime + 1))
        XCTAssertTrue(later.report.rebuilt.contains("scenes"))
    }

    // MARK: The comparison

    func testTwoCodesAreComparedPartByPart() {
        let here = "FY2.20369.aaaaaaaaaaaa.bbbbbbbbbbbb.cccccccccccc.iiiiiiiiiiii.kkkkkkkkkkkk.dddddddddddd"
        let there = "FY2.20369.aaaaaaaaaaaa.bbbbbbbbbbbb.cccccccccccc.jjjjjjjjjjjj.kkkkkkkkkkkk.ffffffffffff"
        let rows = ExploreDiagnostics.compare(here, there)
        XCTAssertEqual(rows?.map(\.input), ["Format", "Evaluation day", "Personal digest", "Shared knowledge digest",
                                           "Device-local digest", "Identity evidence digest", "Known artists digest",
                                           "Ranked recommendation IDs"])
        XCTAssertEqual(rows?.map(\.matches), [true, true, true, true, true, false, true, false],
                       "Same knowledge, different identity evidence: one device verified an artist the other has not")
        XCTAssertNil(ExploreDiagnostics.compare(here, "not a code"))
    }

    /// A device still on the build before identity reads as such.
    func testACodeFromBeforeIdentityIsComparedToo() {
        let old = "FY1.20369.aaaaaaaaaaaa.bbbbbbbbbbbb.cccccccccccc.dddddddddddd"
        let new = "FY2.20369.aaaaaaaaaaaa.bbbbbbbbbbbb.cccccccccccc.iiiiiiiiiiii.kkkkkkkkkkkk.dddddddddddd"
        let rows = try? XCTUnwrap(ExploreDiagnostics.compare(new, old))
        XCTAssertEqual(rows?.map(\.there), ["FY1", "20369", "aaaaaaaaaaaa", "bbbbbbbbbbbb", "cccccccccccc", "—", "—", "dddddddddddd"])
        XCTAssertEqual(rows?.first?.matches, false, "The format says which build each is on")
    }
}
