//
//  BundleCoverageMeasurement.swift
//  IndigoTests
//
//  What the Phase 3B bundles add (SHARED-KNOWLEDGE.md §17), in shadow and
//  nowhere else. Opt-in: `TEST_RUNNER_INDIGO_MEASURE_BUNDLES=1`.
//
//  Before: the pinned generation exactly as published. After: the same
//  generation with the new bundles laid over it in memory -- each read from
//  its R2 reference, checked against the reference's digest, and pinned the
//  way the publisher pins (complete only when discovery was complete and no
//  document is missing). The overlay is a measurement, never a generation:
//  new knowledge is published only as a later generation.
//
//  Ranked for the pilot listener and for copies of this Mac's Development
//  rows, whose visible For You (from this device's own knowledge) says which
//  relationships the backend was missing. Writes `bundle-coverage.json` to
//  the host's temporary directory, and to `INDIGO_MEASURE_OUT` when set.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class BundleCoverageMeasurement: XCTestCase {
    static let built: [Int] = [3999072, 1720124, 3328071, 1053396, 2576890, 1172814, 3722, 823]

    struct BundleCheck: Codable {
        var discogsID = 0
        var digest = ""
        var digestVerified = false
        var artistMatches = false
        var status = ""
        var source = ""
        var collaborators = 0
        var credits = 0
        var labels = 0
        var releases = 0
        /// Targets that are the artist's own other entries (kept out of edges).
        var ownNamesInBundle: [String] = []
        var notes: [String] = []
    }
    struct Side: Codable {
        var shared = ""
        var edges = 0
        var edgesByKind: [String: Int] = [:]
        var candidates = 0
        var top20: [String] = []
        var top20Overlap = 0
        var visibleReached = 0
        var missingKinds: [String] = []
        var bundles: [String: Int] = [:]
    }
    struct Inputs: Codable {
        var label = ""
        var before = Side()
        var after = Side()
        /// Per starting point: edges added, by kind, with examples.
        var added: [String: [String]] = [:]
        var candidatesAdded: [String] = []
        var candidatesRemoved: [String] = []
        var enteredTop20: [String] = []
        var leftTop20: [String] = []
        /// Visible top-twenty recommendations the backend did not reach
        /// before and reaches after, with how.
        var recovered: [String] = []
        var stillUnreached: [String] = []
    }
    struct Report: Codable {
        var generation = ""
        var bundles: [BundleCheck] = []
        var inputs: [Inputs] = []
    }

    func testMeasureWhatTheNewBundlesAdd() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_MEASURE_BUNDLES"] == "1",
                          "Set TEST_RUNNER_INDIGO_MEASURE_BUNDLES=1 to measure the Phase 3B bundles.")
        let now = Date()
        let period = ExplorePeriod.containing(now)
        let asOf = ExplorePeriod.asOf(period)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BundleMeasure-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let (pinned, fetch) = await PinnedGenerationClient.resolve(period: period, store: PinnedGenerationStore(root: root), now: now)
        let before = try XCTUnwrap(pinned, fetch.errors.joined(separator: "; "))
        var report = Report(generation: "\(before.date) \(before.manifestDigest.prefix(12))")

        // The new bundles, verified, and the overlay.
        var objects = before.objects
        var pins: [Int: GenerationManifest.Bundle] = [:]
        for id in Self.built {
            var check = BundleCheck(discogsID: id)
            defer { report.bundles.append(check) }
            let (status, refData) = try await PinnedGenerationClient.live("knowledge/v1/refs/artists/\(id).json")
            guard status == 200, let refData, let ref = try? JSONDecoder().decode(ArtistBundleRef.self, from: refData) else {
                check.status = "missing"; check.notes.append("no reference (HTTP \(status))"); continue
            }
            check.digest = ref.digest
            let (bundleStatus, data) = try await PinnedGenerationClient.live(GenerationKeys.bundle(ref.digest))
            guard bundleStatus == 200, let data else { check.status = "failed"; check.notes.append("bundle HTTP \(bundleStatus)"); continue }
            check.digestVerified = GenerationKeys.digest(data) == ref.digest
            guard check.digestVerified, let bundle = try? JSONDecoder().decode(ArtistBundle.self, from: data) else {
                check.status = "failed"; check.notes.append("digest or decode failed"); continue
            }
            check.artistMatches = bundle.artist.discogsID == id
            let source = bundle.source ?? ref.source
            let complete = source.map { $0.complete && $0.documentsMissing == 0 } ?? false
            check.status = complete ? "complete" : "partial"
            check.source = source.map {
                "discovery \($0.complete ? "complete" : "incomplete") \($0.pagesFetched)/\($0.pagesReported.map(String.init) ?? "?") pages, "
                    + "\($0.entries) entries, \($0.documentsRead)/\($0.representativeReleases) documents read, \($0.documentsMissing) missing, "
                    + "\($0.documentsTruncated) over budget\($0.truncated ? ", truncated" : "")"
            } ?? "no source"
            check.collaborators = bundle.collaborators.count
            check.credits = bundle.credits.count
            check.labels = bundle.labels.count
            check.releases = bundle.releases.count
            let own = Set(Self.built + [1982320, 2576890, 1172814, 3999072])
            check.ownNamesInBundle = (bundle.collaborators.map(\.artist) + bundle.credits.map(\.artist))
                .filter { $0.discogsID.map(own.contains) == true && $0.discogsID != id }
                .map { "\($0.name) (\($0.discogsID!))" }
            guard check.artistMatches else { check.notes.append("bundle is for \(bundle.artist.discogsID)"); continue }
            objects[ref.digest] = data
            pins[id] = .init(discogsID: id, status: check.status, digest: ref.digest,
                             read: complete ? nil : source?.documentsRead, of: complete ? nil : source?.representativeReleases)
        }
        let m = before.manifest
        var nodes = m.nodes
        for (key, entry) in nodes {
            guard var bundles = entry.bundles else { continue }
            bundles = bundles.map { pins[$0.discogsID] ?? $0 }
            var changed = entry
            changed.bundles = bundles
            nodes[key] = changed
        }
        let overlay = PinnedGeneration(
            date: before.date, manifestDigest: "overlay",
            manifest: GenerationManifest(format: m.format, id: m.id + "+3b", date: m.date, identity: m.identity, source: m.source,
                                         nodes: nodes, artists: m.artists, publication: m.publication),
            objects: objects)

        // The listeners.
        var inputs: [(String, PersonalInputs, ExploreRun?)] = []
        inputs.append(("pilot listener", PinnedGenerationMeasurement.pilotListener(period: period), nil))
        let container = try ExploreSharedDataComparison.copyOfRealStores()
        let worker = DigWorker(modelContainer: container)
        let visible = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: true, rebuild: false, now: now)
        inputs.append(("development rows", visible.rows, visible))

        for (label, personal, run) in inputs {
            var result = Inputs(label: label)
            let visibleRanking = run.map { ShadowComparison.ranking(personal: $0.personal, knowledge: $0.knowledge, asOf: asOf, turn: period) }
            var sides: [(Side, KnowledgeSnapshot, [ExploreSuggestion])] = []
            for generation in [before, overlay] {
                let deviceLocal = run?.knowledge.deviceLocal ?? .empty
                let (snapshot, coverage, _) = PinnedKnowledgeAdapter.snapshot(
                    personal: personal, deviceLocal: deviceLocal, generation: generation, now: now)
                let ranking = ShadowComparison.ranking(personal: personal, knowledge: snapshot, asOf: asOf, turn: period)
                var side = Side()
                side.shared = String(CanonicalDigest.of(snapshot.shared).prefix(12))
                let edges = snapshot.shared.neighbourhoods.flatMap(\.edges)
                side.edges = edges.count
                side.edgesByKind = Dictionary(edges.map { ($0.kind.rawValue, 1) }, uniquingKeysWith: +)
                side.candidates = ranking.all.count
                side.top20 = ranking.all.prefix(20).map { "\($0.node.title) — \($0.reason) (\($0.kind.rawValue))" }
                side.bundles = coverage.bundles
                if let run, let visibleRanking {
                    let stage = ShadowStage.measure(.relationships, visible: run, knowledge: snapshot,
                                                    visibleRanking: visibleRanking, asOf: asOf, turn: period)
                    side.top20Overlap = stage.top20Overlap
                    side.visibleReached = stage.visibleReached
                    side.missingKinds = stage.missingKinds
                }
                sides.append((side, snapshot, ranking.all))
            }
            result.before = sides[0].0
            result.after = sides[1].0

            // Edges added, per starting point.
            func edgeMap(_ s: KnowledgeSnapshot) -> [String: Set<String>] {
                var out: [String: Set<String>] = [:]
                for hood in s.shared.neighbourhoods {
                    let origin = s.shared.nodes[hood.origin].title
                    for e in hood.edges {
                        out[origin, default: []].insert("\(e.kind.rawValue): \(s.shared.nodes[e.to].title) — \(e.reason)")
                    }
                }
                return out
            }
            let (b, a) = (edgeMap(sides[0].1), edgeMap(sides[1].1))
            for origin in Set(a.keys).union(b.keys).sorted() {
                let new = (a[origin] ?? []).subtracting(b[origin] ?? [])
                guard !new.isEmpty else { continue }
                let byKind = Dictionary(grouping: new) { String($0.split(separator: ":").first ?? "") }
                result.added[origin] = byKind.keys.sorted().map { kind in
                    let items = byKind[kind]!.sorted()
                    return "\(kind) +\(items.count): " + items.prefix(4).map { String($0.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces) }.joined(separator: " | ")
                }
            }
            let beforeIDs = Set(sides[0].2.map(\.id)), afterIDs = Set(sides[1].2.map(\.id))
            let titles = Dictionary((sides[0].2 + sides[1].2).map { ($0.id, $0.node.title) }, uniquingKeysWith: { x, _ in x })
            result.candidatesAdded = afterIDs.subtracting(beforeIDs).compactMap { titles[$0] }.sorted()
            result.candidatesRemoved = beforeIDs.subtracting(afterIDs).compactMap { titles[$0] }.sorted()
            let top20Before = Set(sides[0].2.prefix(20).map(\.id)), top20After = Set(sides[1].2.prefix(20).map(\.id))
            result.enteredTop20 = sides[1].2.prefix(20).filter { !top20Before.contains($0.id) }.map { "\($0.node.title) — \($0.reason)" }
            result.leftTop20 = sides[0].2.prefix(20).filter { !top20After.contains($0.id) }.map { "\($0.node.title) — \($0.reason)" }

            if let run, let visibleRanking {
                let ids = visibleRanking.all.prefix(20).map(\.id)
                let reachBefore = CorroborationDepth.of(ids, personal: run.rows, knowledge: sides[0].1)
                let reachAfter = CorroborationDepth.of(ids, personal: run.rows, knowledge: sides[1].1)
                let names = Dictionary(visibleRanking.all.map { ($0.id, "\($0.node.title) — \($0.reason)") }, uniquingKeysWith: { x, _ in x })
                for (old, new) in zip(reachBefore, reachAfter) {
                    if old.startingPoints == 0 && new.startingPoints > 0 {
                        result.recovered.append("\(names[new.id] ?? new.id) ← \(new.kinds.joined(separator: ","))")
                    } else if new.startingPoints == 0 {
                        // How this device's own knowledge reaches it: which
                        // starting point, by what -- what the backend lacks.
                        let local = ExploreRanker.edgeSets(run.knowledge)
                        let routes = ExploreRanker.startingPoints(run.personal).flatMap { origin in
                            (local[origin] ?? EdgeSet()).byDestination.filter { $0.node.id == new.id }
                                .flatMap(\.edges).map { "\(origin.title): \($0.kind.rawValue) \($0.reason) [\($0.source.rawValue)]" }
                        }
                        // And what the backend has under a similar name, by id:
                        // a node keyed differently is not missing knowledge.
                        let title = (visibleRanking.all.first { $0.id == new.id }?.node.title ?? "").lowercased()
                        let words = Set(title.split(separator: " ").map(String.init).filter { $0.count > 3 })
                        let backend = ExploreRanker.edgeSets(sides[1].1).flatMap { origin, set in
                            set.byDestination.filter { c in
                                let t = c.node.title.lowercased()
                                return t == title || (!words.isEmpty && words.isSubset(of: Set(t.split(separator: " ").map(String.init))))
                                    || (words.contains { t.contains($0) } && c.node.kind == (visibleRanking.all.first { $0.id == new.id }?.node.kind))
                            }.map { "\(origin.title) → \($0.node.id) [\($0.edges.map(\.kind.rawValue).joined(separator: ","))]" }
                        }
                        result.stillUnreached.append("\(names[new.id] ?? new.id) {\(new.id)} ← " + (routes.isEmpty ? "?" : routes.prefix(3).joined(separator: " | "))
                            + " || backend has: " + (backend.isEmpty ? "nothing similar" : backend.prefix(4).joined(separator: " | ")))
                    }
                }
            }
            report.inputs.append(result)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bundle-coverage.json"))
        // Best effort: a sandboxed macOS host cannot write outside its container.
        if let out = ProcessInfo.processInfo.environment["INDIGO_MEASURE_OUT"], !out.isEmpty {
            try? data.write(to: URL(fileURLWithPath: out))
        }
        XCTAssertTrue(report.bundles.allSatisfy { $0.status == "missing" || ($0.digestVerified && $0.artistMatches) })
    }
}
