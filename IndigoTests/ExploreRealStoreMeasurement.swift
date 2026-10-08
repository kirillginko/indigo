//
//  ExploreRealStoreMeasurement.swift
//  IndigoTests
//
//  What For You's inputs come to on a real collection: sizes, build times and
//  the stamp. Opt-in -- set `INDIGO_MEASURE_EXPLORE=1` (as
//  `TEST_RUNNER_INDIGO_MEASURE_EXPLORE=1` through xcodebuild). It copies this
//  host's own Development stores into a temporary directory and works on the
//  copy, so the stores the app uses are only read. The report is written to
//  `explore-measurement.txt` in the host's temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ExploreRealStoreMeasurement: XCTestCase {
    func testMeasureForYouOnThisDevicesStores() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_MEASURE_EXPLORE"] == "1",
                          "Set INDIGO_MEASURE_EXPLORE=1 to measure the real stores.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let source = support.appendingPathComponent("Development", isDirectory: true)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExploreMeasurement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for name in ["UserData.store", "Local.store"] {
            for suffix in ["", "-wal", "-shm"] {
                let from = source.appendingPathComponent(name + suffix)
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix))
            }
        }
        let container = try Persistence.makeSplitContainer(
            userData: copy.appendingPathComponent("UserData.store"),
            local: copy.appendingPathComponent("Local.store"))

        let worker = DigWorker(modelContainer: container)
        let now = Date()
        let period = ExplorePeriod.containing(now)
        let asOf = ExplorePeriod.asOf(period)
        var out: [String] = []
        func describe(_ label: String, _ run: ExploreRun, wall: Duration) {
            let ms = run.report.milliseconds.sorted { $0.key < $1.key }
                .map { "\($0.key) \(String(format: "%.1f", $0.value))ms" }.joined(separator: ", ")
            out.append("\(label): wall \(wall), rebuilt [\(run.report.rebuilt.joined(separator: ", "))]")
            out.append("  \(ms)")
        }

        var started = ContinuousClock.now
        let core = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: false, rebuild: false, now: now)
        describe("cold, first half", core, wall: ContinuousClock.now - started)
        started = ContinuousClock.now
        let full = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: true, rebuild: false, now: now)
        describe("cold, second half (scenes)", full, wall: ContinuousClock.now - started)
        started = ContinuousClock.now
        let warm = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: true, rebuild: false, now: now)
        describe("warm, nothing changed", warm, wall: ContinuousClock.now - started)

        // A personal change that keeps the starting points: re-reading and
        // re-digesting the rows, the knowledge kept.
        let context = ModelContext(container)
        if let item = try context.fetch(FetchDescriptor<CrateItem>()).first {
            item.genreTagsRaw = item.genreTagsRaw + "\nmeasurement"
            try context.save()
        }
        started = ContinuousClock.now
        let edited = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: true, rebuild: false, now: now)
        describe("warm, personal edit", edited, wall: ContinuousClock.now - started)

        started = ContinuousClock.now
        let offers = await worker.exploreRecommendations(full, asOf: asOf)
        let direction = await worker.exploreDirection(full, asOf: asOf, turn: period)
        out.append("ranking: \(ContinuousClock.now - started)")

        var withScene = offers
        withScene.movingToward = direction
        let entry = ExploreDiagnostics.Entry(stamp: full.stamp, ranked: ExploreDiagnostics.Entry.ranked(withScene), report: full.report)
        out.append("code: \(entry.code)")
        out.append("canonical bytes: " + full.report.bytes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        out.append("counts: " + full.report.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let json = try JSONEncoder().encode(full.knowledge)
        let compressed = try (json as NSData).compressed(using: .zlib) as Data
        out.append("snapshot JSON \(json.count) bytes, zlib \(compressed.count) bytes")
        let sharedJSON = try JSONEncoder().encode(full.knowledge.shared)
        let scenesJSON = try JSONEncoder().encode(full.knowledge.shared.scenes)
        let showsJSON = try JSONEncoder().encode(full.knowledge.shared.shows)
        let neighbourhoodsJSON = try JSONEncoder().encode(full.knowledge.shared.neighbourhoods)
        let nodesJSON = try JSONEncoder().encode(full.knowledge.shared.nodes)
        let localJSON = try JSONEncoder().encode(full.knowledge.deviceLocal)
        out.append("  shared \(sharedJSON.count): nodes \(nodesJSON.count), neighbourhoods \(neighbourhoodsJSON.count), shows \(showsJSON.count), scenes \(scenesJSON.count)")
        out.append("  deviceLocal \(localJSON.count)")
        out.append("personal: crate \(full.personal.crate.count), plays \(full.personal.plays.count), met \(full.personal.met.count), haunts \(full.personal.haunts.count)")
        out.append("starting points: " + ExploreRanker.startingPoints(full.personal).map(\.id).joined(separator: ", "))
        out.append("offers: next \(offers.next.count), shows \(offers.shows.count), artists \(offers.artists.count), toward \(direction?.city ?? "-")")

        // Where reading the rows goes.
        func time(_ label: String, _ work: () -> Void) {
            let started = ContinuousClock.now
            work()
            out.append("  read \(label): \(ContinuousClock.now - started)")
        }
        let reading = ModelContext(container)
        out.append("personal read, piece by piece:")
        time("crate items") { _ = CrateService(context: reading).items().map { ($0.node, $0.genreTags, $0.artistName, $0.displayTitle) } }
        let log = ListeningLog(context: reading)
        time("plays in horizon") { _ = log.since(asOf.addingTimeInterval(-TasteProfile.horizon)).map { ($0.id, $0.at, $0.weight, $0.tags) } }
        var every: [ListeningEvent] = []
        time("all events") { every = log.all() }
        time("events touched") { _ = every.map { ($0.kind, $0.nodeKey, $0.weight) } }
        time("gather") { _ = ListeningLog.gather(every) }
        time("haunts") { _ = DigHistory(context: reading).haunts(kinds: ExploreSuggestionEngine.hauntKinds, limit: 12).map(\.node) }
        time("whole read") { _ = PersonalInputs.read(context: reading, asOf: asOf) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("explore-measurement.txt")
        try out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(offers.next.isEmpty && offers.shows.isEmpty, "a real collection offers something")
    }
}
