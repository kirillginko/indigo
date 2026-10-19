//
//  ForYouHoldoutEvaluation.swift
//  IndigoTests
//
//  Would For You have found what the listener went on to find? The history
//  is rewound to a cutoff; each version recommends from what was there then;
//  and a recommendation counts if the listener's first crate add or first
//  listening event for that artist came after the cutoff. No ratings: the
//  listener's own later listening and crating is the answer.
//
//  Versions: the visible For You (`ExploreRanker`), DIG Discover's tracks,
//  Records like yours, their Phase 4 mix, and a control -- artists the walk
//  reaches, in an arbitrary fixed order, as many as the mix offers.
//
//  Known leak, the same for every version: DIG's caches hold what was
//  browsed after the cutoff, so the knowledge the walk reads is today's.
//  "Reachable" says how many of the later finds the walk could reach at all.
//
//  Opt-in: `INDIGO_HOLDOUT=1` (tracks are found live, read-only). Report
//  (private): `foryou-holdout.txt` in the host's temporary directory.
//

import XCTest
import SwiftData
import CryptoKit
@testable import Indigo

final class ForYouHoldoutEvaluation: XCTestCase {
    func testWhatForYouWouldHaveFound() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_HOLDOUT"] == "1", "Set INDIGO_HOLDOUT=1.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Holdout-\(UUID().uuidString)")
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
        let context = ModelContext(container)
        let everything = PersonalInputs.read(context: context, asOf: .distantFuture)
        let last = (everything.crate.map(\.addedAt) + everything.met.map(\.lastAt)).max() ?? Date()
        let events = try context.fetch(FetchDescriptor<ListeningEvent>())

        // Every artist's first sign, crate or listening.
        var firstCrated: [String: Date] = [:], firstHeard: [String: Date] = [:]
        for item in everything.crate {
            for key in Set(item.tasteArtistKeys + [item.sceneArtistKey].compactMap { $0 }) where !key.isEmpty {
                firstCrated[key] = min(firstCrated[key] ?? .distantFuture, item.addedAt)
            }
        }
        for event in events {
            let key = event.kind == .artist ? event.nodeKey
                : event.kind == .recording ? RecordingKey.normalizeArtist(event.subtitle ?? "") : ""
            guard !key.isEmpty else { continue }
            firstHeard[key] = min(firstHeard[key] ?? .distantFuture, event.at)
        }

        var out = ["history: crate \(everything.crate.count), listening events \(events.count), last activity \(last)", ""]
        for days in [21, 45] {
            let cutoff = last.addingTimeInterval(-Double(days) * 86_400)
            func first(_ key: String) -> Date { min(firstCrated[key] ?? .distantFuture, firstHeard[key] ?? .distantFuture) }
            // Found after the cutoff, and not a sign of them before it.
            let crated = Set(firstCrated.filter { $0.value >= cutoff && first($0.key) >= cutoff }.keys)
            let heard = Set(firstHeard.filter { $0.value >= cutoff && first($0.key) >= cutoff }.keys).union(crated)

            // The history as it stood at the cutoff.
            var past = PersonalInputs.read(context: context, asOf: cutoff)
            past.crate = past.crate.filter { $0.addedAt < cutoff }
            past.met = past.met.filter { $0.lastAt < cutoff }
            past.haunts = past.haunts.filter { $0.lastVisitedAt < cutoff }
            past.plays = past.plays.filter { $0.at < cutoff }
            past.artistPlays = [:]

            let worker = DigWorker(modelContainer: container)
            let run = await worker.exploreRun(asOf: cutoff, period: ExplorePeriod.containing(cutoff), generation: 0, scenes: false,
                                              rebuild: false, now: cutoff, personal: past)
            let offers = await worker.exploreRecommendations(run, asOf: cutoff)
            var source = TrackDiscoverySource.live
            source.cache = TrackDiscoveryCache()
            let inputs = DigStore.discoverInputs(personal: past, context: ModelContext(container), now: cutoff)
            let tracks = await source.discover(.init(seeds: inputs.seeds, collaborators: inputs.collaborators, taste: inputs.taste,
                                                     knownArtists: inputs.knownArtists, knownTracks: inputs.knownTracks,
                                                     limit: 12, releaseLookups: 2)).tracks
            let records = SimilarRecords.find(personal: past, context: context, asOf: cutoff).records
            let mix = ForYouMix.mix(offers: offers, tracks: tracks, records: records)

            // The control: what the walk reaches, ranked by nothing.
            let known = ExploreRanker.knownGround(run.personal)
            let seen = Set(known.map(\.node.id)), encountered = Set(run.personal.met.map(\.node.id)).union(run.alsoKnown)
            let sets = ExploreRanker.edgeSets(run.knowledge)
            var reached: [String: MusicNode] = [:]
            for origin in known.prefix(ExploreSuggestionEngine.origins) {
                for connection in (sets[origin.node] ?? EdgeSet()).byDestination
                where connection.node.kind == .artist && !seen.contains(connection.node.id) && !encountered.contains(connection.node.id) {
                    reached[connection.node.id] = connection.node
                }
            }
            func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
            let control = reached.values.sorted { digest($0.id) < digest($1.id) }.prefix(max(1, mix.count))
                .map { RecordingKey.normalizeArtist($0.title) }
            let reachable = Set(reached.values.map { RecordingKey.normalizeArtist($0.title) })

            let versions: [(String, [String])] = [
                ("For You (visible)", (offers.next + offers.artists).filter { $0.node.kind == .artist }.map { RecordingKey.normalizeArtist($0.node.title) }),
                ("Tracks to hear", tracks.map { RecordingKey.normalizeArtist($0.artist) }),
                ("Records like yours", records.flatMap { $0.record.artistKeys }),
                ("Mix", mix.flatMap { $0.artistKeys }),
                ("Control (unranked walk)", control),
            ]
            out.append("== cutoff \(days) days before the last activity (\(cutoff))")
            out.append("found afterwards: \(heard.count) new artists heard or crated, \(crated.count) of them crated; reachable by the walk at the cutoff: \(heard.intersection(reachable).count)")
            for (name, artists) in versions {
                let offered = Set(artists)
                let hits = offered.intersection(heard), crateHits = offered.intersection(crated)
                out.append("  \(name): \(offered.count) artists offered; \(hits.count) later heard or crated (\(crateHits.count) crated)\(hits.isEmpty ? "" : ": " + hits.sorted().joined(separator: ", "))")
            }
            out.append("  later finds the walk reached: " + heard.intersection(reachable).sorted().prefix(30).joined(separator: ", "))
            out.append("")
        }
        try out.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("foryou-holdout.txt"),
                                              atomically: true, encoding: .utf8)
    }
}
