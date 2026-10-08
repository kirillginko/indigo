//
//  ExploreSharedDataComparison.swift
//  IndigoTests
//
//  How much For You on this device rests on each kind of knowledge: the
//  ranking with each family of relationships left out in turn. Opt-in:
//  `TEST_RUNNER_INDIGO_COMPARE_SHARED=1`.
//
//  Works on a copy of this host's own Development stores. Writes, to the
//  host's temporary directory:
//  - `explore-seeds.json`: the starting points and kept artists;
//  - `explore-comparison.txt`: the baseline and each knowledge family left out
//    in turn, with how much of the top twenty survives.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ExploreSharedDataComparison: XCTestCase {
    private var out: [String] = []
    private let tmp = FileManager.default.temporaryDirectory

    func testCompareKnowledgeSources() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_COMPARE_SHARED"] == "1",
                          "Set INDIGO_COMPARE_SHARED=1 to compare knowledge sources on the real stores.")
        let container = try Self.copyOfRealStores()
        let worker = DigWorker(modelContainer: container)
        let period = ExplorePeriod.containing(Date())
        let asOf = ExplorePeriod.asOf(period)
        let run = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: true, rebuild: false, now: Date())
        let personal = run.personal
        let local = run.knowledge

        try exportSeeds(personal, knowledge: local)

        let baseline = Ranked(personal, local, asOf)
        out.append("BASELINE (this device's caches)")
        out.append(contentsOf: baseline.describe(limit: 30))
        out.append("")
        out.append("Route kinds in the baseline's top 20: " + baseline.kindCounts(20))
        out.append("")

        // Each family of knowledge left out in turn.
        out.append("LEAVE ONE OUT (overlap with the baseline)")
        for (name, variant) in ablations(local) {
            out.append(Ranked(personal, variant, asOf).compared(to: baseline, as: name))
        }
        out.append("")

        // The backend's own snapshot is compared by ExploreShadowMeasurement,
        // through the code the app runs.

        try out.joined(separator: "\n").write(to: tmp.appendingPathComponent("explore-comparison.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: The baseline and its variants

    private struct Ranked {
        let next: [ExploreSuggestion]
        let all: [ExploreSuggestion]
        let shows: [String]
        let toward: String

        init(_ personal: PersonalInputs, _ knowledge: KnowledgeSnapshot, _ asOf: Date) {
            let taste = ExploreRanker.taste(personal: personal, knowledge: knowledge, asOf: asOf)
            let offers = ExploreRanker.recommendations(personal: personal, knowledge: knowledge, taste: taste)
            next = offers.next
            shows = offers.shows.map(\.id)
            all = ExploreRanker.suggestions(personal: personal, knowledge: knowledge, taste: taste, limit: 1_000)
            toward = ExploreRanker.direction(personal: personal, knowledge: knowledge, taste: taste, turn: nil)
                .map { "\($0.city) \($0.sound)" } ?? "-"
        }

        func describe(limit: Int) -> [String] {
            all.prefix(limit).enumerated().map { index, s in
                "\(index + 1). \(s.id) — \(s.reason) — via \(s.via) — \(s.kind.rawValue) ×\(s.corroboration)"
            } + ["shows: \(shows.joined(separator: ", "))", "toward: \(toward)"]
        }

        func kindCounts(_ limit: Int) -> String {
            Dictionary(grouping: all.prefix(limit), by: \.kind.rawValue)
                .map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
        }

        func compared(to base: Ranked, as name: String) -> String {
            func overlap(_ a: [ExploreSuggestion], _ b: [ExploreSuggestion], _ n: Int) -> Int {
                Set(a.prefix(n).map(\.id)).intersection(b.prefix(n).map(\.id)).count
            }
            let baseByID = Dictionary(base.all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let kept = all.prefix(20).filter { baseByID[$0.id] != nil }
            let reworded = kept.filter { baseByID[$0.id]?.reason != $0.reason }.count
            let showOverlap = Set(shows).intersection(base.shows).count
            return "\(name): next \(overlap(next, base.next, 12))/12, top20 \(overlap(all, base.all, 20))/20 "
                + "(\(reworded) reworded), all \(all.count) vs \(base.all.count), "
                + "shows \(showOverlap)/\(max(shows.count, base.shows.count)), toward \(toward == base.toward ? "same" : "\(toward)")"
        }
    }

    private func ablations(_ local: KnowledgeSnapshot) -> [(String, KnowledgeSnapshot)] {
        func without(_ keep: (KnownEdge) -> Bool) -> KnowledgeSnapshot {
            var copy = local
            copy.shared.neighbourhoods = local.shared.neighbourhoods.map {
                Neighbourhood(origin: $0.origin, edges: $0.edges.filter(keep))
            }
            return copy
        }
        var variants: [(String, KnowledgeSnapshot)] = [
            ("no credits (collaborator/producer/personnel)", without { ![.collaborator, .producer, .personnel].contains($0.kind) }),
            ("no Discogs search peers (Also on / Also tagged)", without { !$0.reason.hasPrefix("Also on ") && !$0.reason.hasPrefix("Also tagged ") }),
            ("no style and era peers", without { ![.sharedStyle, .sameEra].contains($0.kind) }),
            ("no label links", without { $0.kind != .sharedLabel }),
            ("no local radio edges", without { ![.playedInShow, .sharedBroadcast].contains($0.kind) }),
            ("no releases", without { ![.appearsOnRelease, .sameRelease].contains($0.kind) }),
            ("no aliases", without { ![.sameAlias, .aliasOrProject].contains($0.kind) }),
        ]
        var noShows = local; noShows.shared.shows = []
        var noTags = local; noTags.shared.artistTags = [:]
        var noScenes = local; noScenes.shared.scenes = nil
        var noLocal = local; noLocal.deviceLocal = .empty
        variants += [("no tracklist shows", noShows), ("no artist tags (taste)", noTags),
                     ("no scenes", noScenes), ("no device-local", noLocal)]
        return variants
    }

    // MARK: Seeds for the backend query

    private func exportSeeds(_ personal: PersonalInputs, knowledge: KnowledgeSnapshot) throws {
        let known = ExploreRanker.knownGround(personal)
        let points = ExploreRanker.startingPoints(personal)
        var footholds = Set(personal.crate.compactMap(\.sceneArtistKey))
        footholds.formUnion(personal.artistPlays.keys)
        let seeds: [String: Any] = [
            "startingPoints": points.map { node -> [String: Any] in
                ["id": node.id, "kind": node.kind.rawValue, "key": node.key, "title": node.title,
                 "providerID": node.providerID ?? "", "handle": node.handle ?? ""]
            },
            "keptArtistKeys": known.compactMap { $0.node.kind == .artist ? $0.node.key : nil }.sorted(),
            "footholdArtistKeys": footholds.sorted(),
            "tasteArtistKeys": personal.tasteArtistKeys.sorted(),
        ]
        let data = try JSONSerialization.data(withJSONObject: seeds, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: tmp.appendingPathComponent("explore-seeds.json"))
        out.append("seeds: \(points.count) starting points, \(known.count) known, "
                   + "\((seeds["keptArtistKeys"] as? [String])?.count ?? 0) kept artists, \(footholds.count) foothold artists")
    }

    // MARK: The real stores, copied

    static func copyOfRealStores() throws -> ModelContainer {
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let source = support.appendingPathComponent("Development", isDirectory: true)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExploreComparison-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        for name in ["UserData.store", "Local.store"] {
            for suffix in ["", "-wal", "-shm"] {
                let from = source.appendingPathComponent(name + suffix)
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix))
            }
        }
        return try Persistence.makeSplitContainer(
            userData: copy.appendingPathComponent("UserData.store"),
            local: copy.appendingPathComponent("Local.store"))
    }
}
