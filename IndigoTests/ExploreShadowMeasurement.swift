//
//  ExploreShadowMeasurement.swift
//  IndigoTests
//
//  The shadow For You on this device's real collection, against the live
//  backend, through the code the app runs. Opt-in:
//  `TEST_RUNNER_INDIGO_MEASURE_SHADOW=1`. Works on a copy of this host's
//  Development stores and writes `explore-shadow.txt` to the host's temporary
//  directory: the comparison, coverage, sizes and timings of a cold look, of
//  the same look again, and of a look after a play that keeps the starting
//  points.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ExploreShadowMeasurement: XCTestCase {
    func testMeasureTheShadowOnThisDevicesStores() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_MEASURE_SHADOW"] == "1",
                          "Set INDIGO_MEASURE_SHADOW=1 to measure the shadow against the live backend.")
        try XCTSkipUnless(SupabaseService.isConfigured, "The backend is not configured in this build.")
        let container = try ExploreSharedDataComparison.copyOfRealStores()
        let worker = DigWorker(modelContainer: container)
        let now = Date()
        let period = ExplorePeriod.containing(now)
        let asOf = ExplorePeriod.asOf(period)
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-cache-\(UUID().uuidString).json")
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-bundles-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: cacheURL)
            try? FileManager.default.removeItem(at: bundleURL)
        }
        var out: [String] = []

        func look(_ label: String) async -> ShadowReport {
            let visible = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: true, rebuild: false, now: now)
            let started = ContinuousClock.now
            let report = await worker.exploreShadow(visible, asOf: asOf, turn: period, now: now,
                                                    cacheURL: cacheURL, bundleURL: bundleURL)
            out.append("== \(label): \(ContinuousClock.now - started) wall")
            out += describe(report)
            return report
        }

        let cold = await look("cold")
        _ = await look("again, same generation")

        // A play of somebody already known: the rows change, the starting
        // points do not, and nothing should be asked for.
        let context = ModelContext(container)
        if let kept = ExploreRanker.knownGround(PersonalInputs.read(context: context, asOf: asOf)).first(where: { $0.node.kind == .artist }) {
            context.insert(ListeningEvent(node: kept.node, action: .played, at: now.addingTimeInterval(-60),
                                          seconds: 600, completion: 1, tags: [], source: nil))
            try context.save()
            out.append("(played \(kept.node.title) again)")
        }
        _ = await look("after a play")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("explore-shadow.txt")
        try out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(cold.fetch.errors.isEmpty, "the live calls failed: \(cold.fetch.errors)")
    }

    private func describe(_ report: ShadowReport) -> [String] {
        let c = report.comparison
        let f = report.fetch
        let coverage = report.coverage
        var lines = [
            "source \(report.source), generation \(f.generation.isEmpty ? "(nothing asked)" : f.generation), stale answers \(coverage.staleAnswers)",
            "calls \(f.calls), \(f.bytes) bytes, ms [\(f.milliseconds.map { String(Int($0.rounded())) }.joined(separator: ", "))], errors \(f.errors.count) \(f.errors.joined(separator: " | "))",
            "asked: \(f.nodesAsked) starting points, \(f.artistsAsked) artists; kept: \(f.nodesKept) points, \(f.artistsKept) artists",
            "starting points: " + coverage.startingPoints.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "),
            "artists: \(coverage.artistsFound) found, \(coverage.artistsUnknown) unknown, \(coverage.artistsMissing) missing",
            "top 12 overlap \(c.top12Overlap)/12, top 20 overlap \(c.top20Overlap)/20, shows \(c.showsOverlap)/\(c.showsCount)",
            "direction: visible \(c.visibleDirection), backend \(c.backendDirection)",
            "missing route kinds: \(c.missingKinds.joined(separator: ", "))",
            "shared digest \(report.visibleShared == report.backendShared ? "same" : "differs"), device-local \(report.deviceLocal.prefix(12))",
            "reworded (\(c.reworded.count)):",
        ]
        lines += c.reworded.prefix(10).map { "  \($0.id): \($0.visible) → \($0.backend)" }
        let b = report.bundleFetch
        lines.append("bundles: \(b.reads) reads, \(b.bytes) bytes, errors [\(b.errors.joined(separator: "; "))]")
        lines += report.bundles.map { "  \($0.node) #\($0.discogsID.map(String.init) ?? "-"): \($0.status) — \($0.detail)" }
        lines.append("visible depth (top 20): \(report.visibleDepth.line)")
        lines.append("STAGES")
        for stage in report.stages {
            lines.append("  \(stage.use.rawValue): top 12 \(stage.top12Overlap)/12, top 20 \(stage.top20Overlap)/20, reaches \(stage.visibleReached)/20 of visible, "
                + "\(stage.edges) edges, reworded \(stage.reworded), missing kinds [\(stage.missingKinds.joined(separator: ", "))]")
            lines.append("    depth \(stage.depth.line)")
            lines.append("    top 20 kinds " + stage.top20Kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            lines += stage.top20.enumerated().map { "    \($0 + 1). \($1)" }
            lines.append("    reworded vs visible:")
            lines += stage.comparison.reworded.prefix(12).map { "      \($0.id): \($0.visible) → \($0.backend)" }
        }
        lines.append("backend top 20:")
        lines += c.backendTop.enumerated().map { "  \($0 + 1). \($1)" }
        lines.append("visible top 20:")
        lines += c.visibleTop.enumerated().map { "  \($0 + 1). \($1)" }
        lines.append("moves (visible → backend):")
        lines += c.moves.map { "  \($0.title): \($0.visible.map { "#\($0)" } ?? "–") → \($0.backend.map { "#\($0)" } ?? "–")" }
        return lines
    }
}
