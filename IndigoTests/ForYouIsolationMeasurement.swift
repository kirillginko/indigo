//
//  ForYouIsolationMeasurement.swift
//  IndigoTests
//
//  That DIG's internal switches cannot move For You: the same copy of the
//  real stores, For You worked out by the app's own worker with musician-first
//  DIG and Hear next off, then on, and every candidate, score and place
//  compared -- and the knowledge they were worked out from.
//
//  Opt-in: `INDIGO_MEASURE_TASTE=1` with `INDIGO_MEASURE_TASTE_DIR` (a folder
//  holding UserData.store and Local.store copies). Report:
//  `foryou-isolation.txt` in the host's temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ForYouIsolationMeasurement: XCTestCase {
    override func tearDown() {
        MusicianFirst.override = nil
        DigRecommendations.override = nil
        ForYouMusicianFirst.override = nil
    }

    func testDIGsSwitchesCannotMoveForYou() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["INDIGO_MEASURE_TASTE"] == "1", let folder = environment["INDIGO_MEASURE_TASTE_DIR"] else {
            throw XCTSkip("Set INDIGO_MEASURE_TASTE=1 and INDIGO_MEASURE_TASTE_DIR.")
        }
        // One copy per side, from the same files, so neither run can leave
        // anything behind for the other.
        func container() throws -> ModelContainer {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Isolation-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            for name in ["UserData.store", "Local.store"] {
                for suffix in ["", "-wal", "-shm"] {
                    let from = URL(fileURLWithPath: folder).appendingPathComponent(name + suffix)
                    if FileManager.default.fileExists(atPath: from.path) {
                        try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix))
                    }
                }
            }
            return try Persistence.makeSplitContainer(
                userData: copy.appendingPathComponent("UserData.store"), local: copy.appendingPathComponent("Local.store"))
        }
        let probe = PersonalInputs.read(context: ModelContext(try container()), asOf: .distantFuture)
        let asOf = ((probe.crate.map(\.addedAt) + probe.met.map(\.lastAt)).max() ?? Date()).addingTimeInterval(3_600)
        let period = ExplorePeriod.containing(asOf)

        func forYou(dig: Bool) async throws -> (stamp: String, offers: [ExploreSuggestion]) {
            ForYouMusicianFirst.override = false
            MusicianFirst.override = dig
            DigRecommendations.override = dig
            let worker = DigWorker(modelContainer: try container())
            let run = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: false, rebuild: false, now: asOf)
            let offers = await worker.exploreRecommendations(run, asOf: asOf)
            return (CanonicalDigest.of(run.stamp), offers.next + offers.shows + offers.artists)
        }
        let off = try await forYou(dig: false)
        let on = try await forYou(dig: true)

        var lines = ["For You with DIG's switches off and on, same copied stores, as of \(asOf)",
                     "knowledge stamp: off \(off.stamp.prefix(16)), on \(on.stamp.prefix(16)) — \(off.stamp == on.stamp ? "same" : "DIFFERENT")",
                     "offers: \(off.offers.count) and \(on.offers.count); same candidates in the same order: \(off.offers.map(\.id) == on.offers.map(\.id)); same scores: \(off.offers.map(\.score) == on.offers.map(\.score))"]
        let technical = off.offers.filter { DigRecommender.role(in: $0.reason).map { CreditRole.contribution(of: $0) == .technical } ?? false }
        lines.append("For You's own offers that are technical credits (kept, as always): \(technical.map { "\($0.node.title) (\($0.reason))" }.joined(separator: "; "))")
        try lines.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("foryou-isolation.txt"),
                                                atomically: true, encoding: .utf8)
        XCTAssertEqual(off.stamp, on.stamp)
        XCTAssertEqual(off.offers.map(\.id), on.offers.map(\.id))
        XCTAssertEqual(off.offers.map(\.score), on.offers.map(\.score))
        XCTAssertEqual(off.offers.map(\.reason), on.offers.map(\.reason))
    }
}
