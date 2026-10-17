//
//  ClusterSeedInputsTiming.swift
//  IndigoTests
//
//  Where the cluster-seed inputs spend their time, stage by stage, on a copy
//  of this Mac's stores; and a fingerprint of the profile built, so a faster
//  build can be shown to give the same answer.
//
//  Opt-in: `INDIGO_CLUSTER_TIMING=1`. Report: `cluster-seed-timing.txt` in
//  the host's temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

final class ClusterSeedInputsTiming: XCTestCase {
    func testWhereTheTimeGoes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_CLUSTER_TIMING"] == "1", "Set INDIGO_CLUSTER_TIMING=1.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Timing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for (folder, name) in [(support, "UserData.store"), (support.appendingPathComponent("Development"), "Local.store")] {
            for suffix in ["", "-wal", "-shm"] {
                let from = folder.appendingPathComponent(name + suffix)
                if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix)) }
            }
        }
        let container = try Persistence.makeSplitContainer(userData: copy.appendingPathComponent("UserData.store"),
                                                           local: copy.appendingPathComponent("Local.store"))
        var out: [String] = []
        func time<T>(_ label: String, _ body: () -> T) -> T {
            let t = ContinuousClock.now
            let value = body()
            let d = ContinuousClock.now - t
            out.append(String(format: "%-34@ %6.0f ms", label as NSString, Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15))
            return value
        }
        let now = Date()
        for pass in 1...2 {
            out.append("== pass \(pass) (fresh context)")
            let context = ModelContext(container)
            let records = time("records -> RecordProfile") { ((try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? []).map(RecordProfile.init(record:)) }
            let vectors = time("style space") { RecordSimilarity(pool: records).vectors }
            let read = time("ListenerProfile.read") { ListenerProfile.read(context: context) }
            let profile = time("ListenerProfile.build") {
                ListenerProfile.build(evidence: read.evidence, styles: read.styles, artistStyles: read.artistStyles, vectors: vectors, asOf: now)
            }
            _ = time("seeds") { ListenerRetrieval.seeds(profile, vectors: vectors) }
            let rows = time("DiscogsArtist fetch") { (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? [] }
            _ = time("StyleBook") { ListenerRetrieval.StyleBook(entries: rows.map { (key: $0.nameKey, id: $0.discogsID, styles: $0.styles) },
                                                                  records: records, vectors: vectors) }
            _ = time("PersonalInputs.read") { PersonalInputs.read(context: context, asOf: now).tasteArtistKeys }
            _ = time("ClusterSeedPicks.inputs (all)") { ClusterSeedPicks.inputs(context: ModelContext(container), vectors: vectors, now: now) }
            out.append("profile: \(profile.units.count) units, \(profile.clusters.count) clusters; " + profile.clusters.map {
                "\($0.label.joined(separator: "/")) \(String(format: "%.4f", $0.longTermShare)) \($0.units)" }.joined(separator: "; "))
        }
        try out.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("cluster-seed-timing.txt"),
                                              atomically: true, encoding: .utf8)
    }
}
