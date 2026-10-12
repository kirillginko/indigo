//
//  PinnedGenerationMeasurement.swift
//  IndigoTests
//
//  The pinned-generation client against the real published generation
//  (SHARED-KNOWLEDGE.md §15). Opt-in: `TEST_RUNNER_INDIGO_MEASURE_PINNED=1`.
//  Reads R2 through the public host only; writes nothing anywhere but two
//  temporary caches. Two clean clients, cold, warm and offline; the same
//  personal inputs ranked from each. Writes `pinned-measure.json` to the
//  host's temporary directory and prints it.
//
//  The pilot listener is made here from the pilot's starting artists, so the
//  same inputs run on every platform; on a Mac, copies of this Mac's
//  Development and Production rows are measured too, read the way
//  `PilotDemandExport` reads them (copies only, never the stores themselves).
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class PinnedGenerationMeasurement: XCTestCase {
    struct Client: Codable {
        var source = ""
        var manifest = ""
        var ms = 0.0
        var objectsDownloaded = 0
        var objectsReused = 0
        var bytesDownloaded = 0
        var cacheBytes = 0
        var errors: [String] = []
    }
    struct Ranked: Codable {
        var inputs = ""
        var personal = ""
        var coverage = ""
        var shared = ""
        var candidates = 0
        var ranked = ""
        var top5: [String] = []
        var identical = false
    }
    struct Report: Codable {
        var platform = ""
        var evaluationDay = ""
        var cold: [Client] = []
        var warm = Client()
        var offline = Client()
        var parity: [Ranked] = []
    }

    static let pilotArtists = [
        "Anika", "Annika Henderson", "Attilio Novellino", "Ciro Vitiello", "Dean Blunt", "Duenn", "Eric Kloss",
        "Hype Williams", "Joanne Robertson", "Kate NV", "Mica Levi", "Micachu", "Prefuse 73", "Speedy J",
    ]

    func testMeasureThePinnedGeneration() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_MEASURE_PINNED"] == "1",
                          "Set TEST_RUNNER_INDIGO_MEASURE_PINNED=1 to measure the published generation.")
        let now = Date()
        let period = ExplorePeriod.containing(now)
        var report = Report()
        #if os(macOS)
        report.platform = "macOS"
        #else
        report.platform = "iOS"
        #endif
        report.evaluationDay = GenerationKeys.date(ofPeriod: period)

        func store() -> PinnedGenerationStore {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("PinnedMeasure-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return PinnedGenerationStore(root: url)
        }
        func client(_ r: PinnedGenerationClient.Report) -> Client {
            Client(source: r.source, manifest: r.manifest ?? "", ms: r.milliseconds.rounded(), objectsDownloaded: r.objectsDownloaded,
                   objectsReused: r.objectsReused, bytesDownloaded: r.bytesDownloaded, cacheBytes: r.cacheBytes, errors: r.errors)
        }

        // Each client its own ephemeral session: a clean device, with no
        // HTTP cache another client filled.
        let storeA = store(), storeB = store()
        //
        // Or, with `TEST_RUNNER_INDIGO_PINNED_FROM=<folder>`, the published
        // bytes as a reader saved them (`Scripts/knowledge-generation-read.ts`),
        // for a platform with no network: every digest is still checked, so
        // what is ranked is exactly what was published; only the timings stop
        // being network timings.
        let readA: PinnedGenerationClient.Read, readB: PinnedGenerationClient.Read
        if let folder = ProcessInfo.processInfo.environment["INDIGO_PINNED_FROM"], !folder.isEmpty {
            let files: PinnedGenerationClient.Read = { key in
                let url = URL(fileURLWithPath: folder).appendingPathComponent(key)
                guard let data = try? Data(contentsOf: url) else { return (404, nil) }
                return (200, data)
            }
            (readA, readB) = (files, files)
            report.platform += " (published bytes from \(folder))"
        } else {
            readA = PinnedGenerationClient.reader(URLSession(configuration: .ephemeral))
            readB = PinnedGenerationClient.reader(URLSession(configuration: .ephemeral))
        }
        let (a, coldA) = await PinnedGenerationClient.resolve(period: period, store: storeA, read: readA, now: now)
        let (b, coldB) = await PinnedGenerationClient.resolve(period: period, store: storeB, read: readB, now: now)
        report.cold = [client(coldA), client(coldB)]
        let (_, warm) = await PinnedGenerationClient.resolve(period: period, store: storeA, read: readA, now: now)
        report.warm = client(warm)
        let (offlineGeneration, offline) = await PinnedGenerationClient.resolve(
            period: period, store: PinnedGenerationStore(root: storeA.root),
            read: { _ in throw URLError(.notConnectedToInternet) }, now: now)
        report.offline = client(offline)
        let generationA = try XCTUnwrap(a, coldA.errors.joined(separator: "; "))
        let generationB = try XCTUnwrap(b, coldB.errors.joined(separator: "; "))
        XCTAssertEqual(offlineGeneration?.manifestDigest, generationA.manifestDigest)

        var inputs: [(String, PersonalInputs)] = []
        let base = Date(timeIntervalSince1970: Double(period) * ExplorePeriod.length)
        inputs.append(("pilot listener", PersonalInputs(
            crate: [], plays: [],
            met: Self.pilotArtists.enumerated()
                .map { PersonalInputs.Met(node: .artist($1), weight: 1, lastAt: base.addingTimeInterval(-Double($0) * 3_600)) }
                .sorted { $0.node.id < $1.node.id },
            artistPlays: Dictionary(uniqueKeysWithValues: Self.pilotArtists.map { (RecordingKey.normalizeArtist($0), 2) }),
            haunts: [])))
        #if os(macOS)
        let support = StoreLayout.standard.directory
        for (label, folder) in [("development rows", support.appendingPathComponent("Development", isDirectory: true)),
                                ("production rows", support)] {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("PinnedRows-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: copy) }
            var found = false
            for name in ["UserData.store", "Local.store"] {
                for suffix in ["", "-wal", "-shm"] {
                    let from = folder.appendingPathComponent(name + suffix)
                    if FileManager.default.fileExists(atPath: from.path) {
                        try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix))
                        found = true
                    }
                }
            }
            guard found else { continue }
            let container = try Persistence.makeSplitContainer(userData: copy.appendingPathComponent("UserData.store"),
                                                               local: copy.appendingPathComponent("Local.store"))
            inputs.append((label, PersonalInputs.read(context: ModelContext(container), asOf: ExplorePeriod.asOf(period))))
        }
        #endif

        for (label, personal) in inputs {
            var sides: [(shared: String, candidates: [String], ranked: String, top: [String], coverage: String)] = []
            for generation in [generationA, generationB] {
                let (snapshot, coverage, _) = PinnedKnowledgeAdapter.snapshot(
                    personal: personal, deviceLocal: .empty, generation: generation, now: now)
                let ranking = ShadowComparison.ranking(personal: personal, knowledge: snapshot,
                                                       asOf: ExplorePeriod.asOf(period), turn: period)
                let ids = ranking.next.map(\.id) + ranking.all.map(\.id) + ranking.shows + [ranking.direction]
                sides.append((CanonicalDigest.of(snapshot.shared), ranking.all.map(\.id).sorted(), CanonicalDigest.of(ids),
                              ranking.all.prefix(5).map { "\($0.node.title) — \($0.reason)" }, coverage.code))
            }
            let identical = sides[0].shared == sides[1].shared && sides[0].candidates == sides[1].candidates
                && sides[0].ranked == sides[1].ranked
            XCTAssertTrue(identical, label)
            report.parity.append(Ranked(
                inputs: label, personal: String(CanonicalDigest.of(personal).prefix(12)), coverage: sides[0].coverage,
                shared: String(sides[0].shared.prefix(12)), candidates: sides[0].candidates.count,
                ranked: String(sides[0].ranked.prefix(12)), top5: sides[0].top, identical: identical))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pinned-measure.json"))
        // A simulator's clone is deleted with its temporary directory; a
        // folder of the host's can be named instead.
        if let out = ProcessInfo.processInfo.environment["INDIGO_MEASURE_OUT"], !out.isEmpty {
            try data.write(to: URL(fileURLWithPath: out))
        }
        print("PINNED-MEASURE " + String(decoding: data, as: UTF8.self))
    }
}
