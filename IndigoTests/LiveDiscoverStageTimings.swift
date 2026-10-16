//
//  LiveDiscoverStageTimings.swift
//  IndigoTests
//
//  Where Discover's time goes, cold: every backend read, release lookup and
//  playback check timed against the start, for DIG's landing (the
//  listeners) and for dead-end artist pages. Live and read-only.
//
//  Opt-in: `INDIGO_LIVE_STAGES=1`, `INDIGO_DIG_MEASURE_DIR`. Report:
//  `live-discover-stages.txt` in the host's temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

final class LiveDiscoverStageTimings: XCTestCase {
    private struct Listener: Decodable {
        struct Seed: Decodable { let discogs: Int; let name: String }
        let show: String
        let seeds: [Seed]
    }

    /// Calls as (stage, start, end) in ms from the discovery's start.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var origin = ContinuousClock.now
        private(set) var spans: [(String, Double, Double)] = []
        func reset() { lock.withLock { origin = .now; spans = [] } }
        func ms(_ at: ContinuousClock.Instant) -> Double {
            let d = at - lock.withLock { origin }
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        func time<T>(_ stage: String, _ work: () async throws -> T) async rethrows -> T {
            let start = ContinuousClock.now
            defer { let end = ContinuousClock.now; let s = ms(start), e = ms(end); lock.withLock { spans.append((stage, s, e)) } }
            return try await work()
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var ms: Double?
        func mark(_ start: ContinuousClock.Instant) {
            let d = ContinuousClock.now - start
            lock.withLock { if ms == nil { ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 } }
        }
    }

    func testStages() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["INDIGO_LIVE_STAGES"] == "1", let measure = environment["INDIGO_DIG_MEASURE_DIR"] else {
            throw XCTSkip("Live: set INDIGO_LIVE_STAGES=1 and INDIGO_DIG_MEASURE_DIR.")
        }
        let clock = Clock()
        let live = TrackDiscoverySource.live
        let shelves = CatalogShelfSource(isEnabled: true)
        let videos = ReleaseVideoTracks(shelf: { id in await clock.time("  r2 shelf") { await shelves.shelf(discogsID: id) } },
                                        release: { id in await clock.time("  r2 release") { await ReleaseVideoTracks.live.release(id) } })
        func source() -> TrackDiscoverySource {
            var s = live
            s.cache = TrackDiscoveryCache()
            s.rows = { ids in try await clock.time("rows") { try await live.rows(ids) } }
            s.neighbours = { rows in try await clock.time("neighbours") { try await live.neighbours(rows) } }
            s.relations = { row in try await clock.time("relations rpc") { try await live.relations(row) } }
            s.artists = { rows in try await clock.time("artists") { try await live.artists(rows) } }
            s.appearances = { rows in try await clock.time("appearances") { try await live.appearances(rows) } }
            s.releaseVideos = { id, name in await clock.time("release videos") { await videos.tracks(artistID: id, artist: name) } }
            s.plays = { src in
                let kind: String
                switch src { case .recording: kind = "check youtube"; case .episode(let l, _): kind = "check \(l.provider)" }
                return await clock.time(kind) { await live.plays(src) }
            }
            return s
        }

        var lines: [String] = []
        func run(_ label: String, _ asks: [(String, TrackDiscoverySource.Ask)]) async {
            var stageTotals: [String: [Double]] = [:]   // wall time a stage occupied, per run
            var calls: [String: [Double]] = [:]
            var firsts: [Double] = [], totals: [Double] = [], beforeChecks: [Double] = []
            for (_, ask) in asks {
                clock.reset()
                let (_, report) = await source().discover(ask)
                if let f = report.firstTrackMilliseconds { firsts.append(f) }
                totals.append(report.milliseconds)
                let spans = clock.spans
                if let firstCheck = spans.filter({ $0.0.hasPrefix("check") }).map(\.1).min() { beforeChecks.append(firstCheck) }
                for (stage, list) in Dictionary(grouping: spans, by: \.0) {
                    calls[stage, default: []] += list.map { $0.2 - $0.1 }
                    // Union of the stage's intervals: how long it held the chain.
                    var wall = 0.0, end = -1.0
                    for s in list.sorted(by: { $0.1 < $1.1 }) {
                        if s.1 >= end { wall += s.2 - s.1; end = s.2 } else if s.2 > end { wall += s.2 - end; end = s.2 }
                    }
                    stageTotals[stage, default: []].append(wall)
                }
            }
            func med(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
            func p90(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.9))] }
            lines.append("== \(label), \(asks.count) runs, cold")
            lines.append(String(format: "first track %.0f ms median (p90 %.0f); first playback check starts at %.0f ms median; whole list %.0f ms median (p90 %.0f)",
                                med(firsts), p90(firsts), med(beforeChecks), med(totals), p90(totals)))
            for stage in stageTotals.keys.sorted() {
                let c = calls[stage] ?? []
                lines.append(String(format: "  %-16@ wall %5.0f ms median/run (in %d of %d runs) · %3d calls, %4.0f ms median, %5.0f p90, %5.0f max",
                                    stage as NSString, med(stageTotals[stage]!), stageTotals[stage]!.count, asks.count, c.count, med(c), p90(c), c.max() ?? 0))
            }
            lines.append("")
        }

        let listeners = try JSONDecoder().decode([Listener].self,
                                                 from: Data(contentsOf: URL(fileURLWithPath: measure).appendingPathComponent("listeners.json")))
        await run("DIG landing", listeners.map { listener in
            let seeds = listener.seeds.enumerated().map { TrackDiscovery.Seed(discogsID: $0.element.discogs, name: $0.element.name, weight: 1 - Double($0.offset) * 0.04) }
            return (listener.show, TrackDiscoverySource.Ask(seeds: seeds, knownArtists: Set(listener.seeds.map { RecordingKey.normalizeArtist($0.name) }),
                                                            limit: 12, releaseLookups: 2))
        })
        // Artist pages: one seed each, as the Listen section asks (no DIG
        // collaborators here: those come from the device's graph).
        let pageSeeds = listeners.flatMap { $0.seeds.suffix(2) }.prefix(24)
        await run("Artist pages (Listen)", pageSeeds.map { seed in
            (seed.name, TrackDiscoverySource.Ask(seeds: [.init(discogsID: seed.discogs, name: seed.name, weight: 1)],
                                                 knownArtists: [RecordingKey.normalizeArtist(seed.name)], limit: 5, ownTracks: 3, releaseLookups: 3))
        })
        // DIG's own inputs, read from a copy of this Mac's stores.
        if environment["INDIGO_STAGES_INPUTS"] == "1", let folder = environment["INDIGO_MEASURE_TASTE_DIR"] {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Stages-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: copy) }
            for name in ["UserData.store", "Local.store"] { for suffix in ["", "-wal", "-shm"] {
                let from = URL(fileURLWithPath: folder).appendingPathComponent(name + suffix)
                if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix)) }
            } }
            let container = try Persistence.makeSplitContainer(userData: copy.appendingPathComponent("UserData.store"), local: copy.appendingPathComponent("Local.store"))
            do {
                let context = ModelContext(container)
                var t = clock.ms(ContinuousClock.now)
                func lap(_ what: String) { let n = clock.ms(ContinuousClock.now); lines.append("  \(what): \(Int(n - t)) ms"); t = n }
                let personal = PersonalInputs.read(context: context, asOf: Date()); lap("PersonalInputs.read")
                let origins = MusicianFirstRanker.startingPoints(personal, asOf: Date(), count: 40); lap("startingPoints (\(origins.count))")
                let store = ArtistIdentityStore(context: context)
                for o in origins.prefix(20) { _ = store.artistResolution(ArtistReference(name: o.node.title, discogsID: o.node.discogsID)) }; lap("20 artistResolutions")
                let graph = IdentityGraph(context: context)
                for o in origins.prefix(6) { _ = graph.neighbourhood(of: .artist(o.node.title, discogsID: o.node.discogsID)).edges.forDIG.all }; lap("6 neighbourhoods")
                let tags = LocalKnowledgeAdapter.artistTags(for: personal.tasteArtistKeys, in: context); lap("artistTags (\(personal.tasteArtistKeys.count) keys)")
                _ = TasteProfile.collected(personal: personal, artistTags: tags, now: Date()); lap("TasteProfile.collected")
            }
            // End to end, as DIG's landing does it: the old order (every input,
            // then the backend) against the new (the walk beside the backend).
            var oldFirst: [Double] = [], newFirst: [Double] = [], oldCount: [Int] = [], newCount: [Int] = []
            for _ in 1...3 {
                var start = ContinuousClock.now
                let full = DigStore.discoverInputs(context: ModelContext(container))
                var s1 = live; s1.cache = TrackDiscoveryCache()
                let firstOld = Box()
                let (a, _) = await s1.discover(.init(seeds: full.seeds, collaborators: full.collaborators, taste: full.taste,
                                                     knownArtists: full.knownArtists, knownTracks: full.knownTracks, limit: 12, releaseLookups: 2)) { _ in
                    firstOld.mark(start)
                }
                oldFirst.append(firstOld.ms ?? -1); oldCount.append(a.count)
                start = ContinuousClock.now
                let quick = DigStore.discoverInputs(context: ModelContext(container), collaborators: false)
                var s2 = live; s2.cache = TrackDiscoveryCache()
                let firstNew = Box()
                let seeds = quick.seeds
                let walk = Task.detached { DigStore.discoverCollaborators(of: seeds, context: ModelContext(container)) }
                var ask = TrackDiscoverySource.Ask(seeds: quick.seeds, taste: quick.taste, knownArtists: quick.knownArtists,
                                                   knownTracks: quick.knownTracks, limit: 12, releaseLookups: 2)
                var (b, _) = await s2.discover(ask) { _ in firstNew.mark(start) }
                ask.collaborators = await walk.value
                if !ask.collaborators.isEmpty { b = await s2.discover(ask).tracks }
                newFirst.append(firstNew.ms ?? -1); newCount.append(b.count)
            }
            lines.append("DIG landing from this Mac's history, input read to first track: old order \(oldFirst.map { Int($0) }) ms (\(oldCount) tracks), new \(newFirst.map { Int($0) }) ms (\(newCount) tracks)")
            for pass in 1...2 {
                let start = ContinuousClock.now
                let inputs = DigStore.discoverInputs(context: ModelContext(container))
                lines.append("discoverInputs pass \(pass): \(Int(clock.ms(ContinuousClock.now) - clock.ms(start))) ms for \(inputs.seeds.count) seeds, \(inputs.collaborators.count) collaborators")
            }
        }
        try lines.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("live-discover-stages.txt"),
                                                atomically: true, encoding: .utf8)
    }
}
