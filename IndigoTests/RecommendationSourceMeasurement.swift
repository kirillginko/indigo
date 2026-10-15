//
//  RecommendationSourceMeasurement.swift
//  IndigoTests
//
//  Where For You's recommendations come from, and how the backend's reach of
//  the visible top twenty moves across three states (SHARED-KNOWLEDGE.md §19).
//  Opt-in: `TEST_RUNNER_INDIGO_MEASURE_SOURCES=1`. Measurement only.
//
//    published  the pinned 2026-10-11 generation, as published;
//    +bundles   with the eight Phase 3B bundles laid over it (§17);
//    +0076      and the two corrected starting points (§18), their answers
//               read live from explore_knowledge and laid over it too.
//
//  The overlays are never a generation: published knowledge only changes by
//  publishing a later one. Writes `recommendation-sources.json` to the host's
//  temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class RecommendationSourceMeasurement: XCTestCase {
    /// The knowledge source a kind of relationship comes from.
    static func source(_ kind: RelationshipKind) -> String {
        switch kind {
        case .sharedLabel: "labels"
        case .producer, .personnel: "release credits"
        case .playedInShow, .frequentlyPlayedNearby, .sharedBroadcast, .playedBySameSelector: "radio"
        case .collaborator, .sameRelease, .appearsOnRelease, .aliasOrProject, .sameAlias, .sameArtist: "artist relationships"
        case .sameScene, .sameCity: "scenes"
        case .sharedStyle, .sameEra: "styles and eras"
        case .inYourLibrary, .inYourCrate, .sharedCollection, .sameUserTrail, .sharedCratePattern, .manualRelation: "personal"
        @unknown default: "other"
        }
    }

    struct Row: Codable {
        var title = ""
        var id = ""
        var visibleRank = 0
        var visibleScore = 0.0
        var visibleKinds: [String] = []
        /// Per state: "rank score" by id, "≈rank score" by Discogs identity,
        /// "show-level" when only the episode's show is reached, or "—".
        var backend: [String: String] = [:]
        var reachedBy: [String: [String]] = [:]
    }
    struct State: Codable {
        var edges = 0
        var edgesBySource: [String: Int] = [:]
        var top20BySource: [String: Int] = [:]
        var visibleReachedByID = 0
        var visibleReachedByIdentity = 0
        var showLevelOnly = 0
        var top20Overlap = 0
        var bundles: [String: Int] = [:]
        var startingPoints: [String: String] = [:]
    }
    struct Report: Codable {
        var visibleTop20BySource: [String: Int] = [:]
        var visibleEdgesBySource: [String: Int] = [:]
        var states: [String: State] = [:]
        var rows: [Row] = []
    }

    func testWhereRecommendationsComeFrom() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_MEASURE_SOURCES"] == "1",
                          "Set TEST_RUNNER_INDIGO_MEASURE_SOURCES=1 to measure recommendation sources.")
        let now = Date()
        let period = ExplorePeriod.containing(now)
        let asOf = ExplorePeriod.asOf(period)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sources-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let (pinned, fetch) = await PinnedGenerationClient.resolve(period: period, store: PinnedGenerationStore(root: root), now: now)
        let published = try XCTUnwrap(pinned, fetch.errors.joined(separator: "; "))

        // +bundles: the eight references, each bundle checked against its digest.
        var objects = published.objects
        var pins: [Int: GenerationManifest.Bundle] = [:]
        for id in BundleCoverageMeasurement.built {
            let (status, refData) = try await PinnedGenerationClient.live("knowledge/v1/refs/artists/\(id).json")
            guard status == 200, let refData, let ref = try? JSONDecoder().decode(ArtistBundleRef.self, from: refData) else { continue }
            let (bundleStatus, data) = try await PinnedGenerationClient.live(GenerationKeys.bundle(ref.digest))
            guard bundleStatus == 200, let data, GenerationKeys.digest(data) == ref.digest,
                  let bundle = try? JSONDecoder().decode(ArtistBundle.self, from: data), bundle.artist.discogsID == id else { continue }
            let source = bundle.source ?? ref.source
            let complete = source.map { $0.complete && $0.documentsMissing == 0 } ?? false
            objects[ref.digest] = data
            pins[id] = .init(discogsID: id, status: complete ? "complete" : "partial", digest: ref.digest,
                             read: complete ? nil : source?.documentsRead, of: complete ? nil : source?.representativeReleases)
        }
        func overlay(_ nodes: [String: GenerationManifest.Entry], _ objects: [String: Data], _ tag: String) -> PinnedGeneration {
            let m = published.manifest
            return PinnedGeneration(date: published.date, manifestDigest: tag, manifest: GenerationManifest(
                format: m.format, id: m.id + tag, date: m.date, identity: m.identity, source: m.source,
                nodes: nodes, artists: m.artists, publication: m.publication), objects: objects)
        }
        var withBundles = published.manifest.nodes
        for (key, entry) in withBundles {
            var changed = entry
            changed.bundles = entry.bundles?.map { pins[$0.discogsID] ?? $0 }
            withBundles[key] = changed
        }

        // +0076: the corrected starting points' answers, live, and their bundles
        // re-pinned to the identities those answers now name.
        var corrected = withBundles
        var correctedObjects = objects
        let fixes = [MusicNode.artist("Hype Williams"), MusicNode.artist("Prefuse73")]
        let data = try await BackendKnowledgeFetcher.live(.init(
            pNodes: fixes.map { .init(id: $0.id, kind: $0.kind.rawValue, key: $0.key, provider: "", handle: "") }, pArtists: []))
        let live = try JSONDecoder().decode(BackendKnowledgeResponse.self, from: data)
        for node in fixes {
            guard let answer = live.nodes[node.id] else { continue }
            let wrapped = try JSONSerialization.data(withJSONObject: [
                "format": "indigo.knowledge-answer/1", "kind": "node", "id": node.id,
                "answer": JSONSerialization.jsonObject(with: JSONEncoder().encode(answer))], options: [.sortedKeys])
            let digest = GenerationKeys.digest(wrapped)
            correctedObjects[digest] = wrapped
            let bundles = answer.cataloguedDiscogsIDs.map { id in
                pins[id] ?? published.manifest.nodes.values.flatMap { $0.bundles ?? [] }.first { $0.discogsID == id }
                    ?? .init(discogsID: id, status: "missing")
            }
            corrected[node.id] = .init(status: answer.status, answer: digest, ambiguousName: nil, bundles: bundles)
        }

        let states: [(String, PinnedGeneration)] = [
            ("published", published), ("+bundles", overlay(withBundles, objects, "+3b")),
            ("+0076", overlay(corrected, correctedObjects, "+3b+0076")),
        ]

        let container = try ExploreSharedDataComparison.copyOfRealStores()
        let worker = DigWorker(modelContainer: container)
        let run = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: true, rebuild: false, now: now)
        let visible = ShadowComparison.ranking(personal: run.personal, knowledge: run.knowledge, asOf: asOf, turn: period)
        let visibleTop = Array(visible.all.prefix(20))
        var report = Report()

        func bySource(_ kinds: [String]) -> Set<String> {
            Set(kinds.compactMap(RelationshipKind.init(rawValue:)).map(Self.source))
        }
        let visibleDepth = CorroborationDepth.of(visibleTop.map(\.id), personal: run.personal, knowledge: run.knowledge)
        for depth in visibleDepth { for s in bySource(depth.kinds) { report.visibleTop20BySource[s, default: 0] += 1 } }
        for edge in run.knowledge.shared.neighbourhoods.flatMap(\.edges) + run.knowledge.deviceLocal.neighbourhoods.flatMap(\.edges) {
            report.visibleEdgesBySource[Self.source(edge.kind), default: 0] += 1
        }
        report.rows = visibleTop.enumerated().map { index, s in
            Row(title: s.node.title, id: s.id, visibleRank: index + 1, visibleScore: (s.score * 1000).rounded() / 1000,
                visibleKinds: visibleDepth[index].kinds)
        }

        for (name, generation) in states {
            let (snapshot, coverage, _) = PinnedKnowledgeAdapter.snapshot(
                personal: run.rows, deviceLocal: run.knowledge.deviceLocal, generation: generation, now: now)
            let ranking = ShadowComparison.ranking(personal: run.rows, knowledge: snapshot, asOf: asOf, turn: period)
            var state = State()
            let edges = snapshot.shared.neighbourhoods.flatMap(\.edges)
            state.edges = edges.count
            for e in edges { state.edgesBySource[Self.source(e.kind), default: 0] += 1 }
            let depth = CorroborationDepth.of(ranking.all.prefix(20).map(\.id), personal: run.rows, knowledge: snapshot)
            for d in depth { for s in bySource(d.kinds) { state.top20BySource[s, default: 0] += 1 } }
            state.bundles = coverage.bundles
            state.startingPoints = coverage.startingPoints
            state.top20Overlap = Set(ranking.all.prefix(20).map(\.id)).intersection(visibleTop.map(\.id)).count

            // Every reachable candidate, ranked, so a visible item's place is
            // known even below the top forty.
            let taste = ExploreRanker.taste(personal: run.rows, knowledge: snapshot, asOf: asOf)
            let everything = ExploreRanker.suggestions(personal: run.rows, knowledge: snapshot, taste: taste, limit: 2_000)
            let reach = CorroborationDepth.of(visibleTop.map(\.id), personal: run.rows, knowledge: snapshot)
            let sets = ExploreRanker.edgeSets(snapshot)
            for (index, s) in visibleTop.enumerated() {
                var cell = "—"
                if let at = everything.firstIndex(where: { $0.id == s.id }) {
                    cell = "\(at + 1) \(String(format: "%.3f", everything[at].score))"
                    state.visibleReachedByID += 1
                } else if let id = s.node.discogsID,
                          let at = everything.firstIndex(where: { $0.node.kind == s.node.kind && $0.node.discogsID == id }) {
                    cell = "≈\(at + 1) \(String(format: "%.3f", everything[at].score)) as \(everything[at].node.title)"
                    state.visibleReachedByIdentity += 1
                } else if reach[index].startingPoints > 0 {
                    cell = "reached, not offered"
                    state.visibleReachedByID += 1
                } else if s.node.kind == .broadcast, let show = s.node.handle?.split(separator: "/").first,
                          sets.values.contains(where: { $0.byDestination.contains { $0.node.kind == .broadcast && $0.node.handle == String(show) } }) {
                    cell = "show-level"
                    state.showLevelOnly += 1
                }
                report.rows[index].backend[name] = cell
                report.rows[index].reachedBy[name] = reach[index].kinds
            }
            report.states[name] = state
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let out = try encoder.encode(report)
        try out.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recommendation-sources.json"))
    }
}
