//
//  LiveDeadEndRescueMeasurement.swift
//  IndigoTests
//
//  Whether Discover rescues dead-end artist pages: the catalogue sample's
//  pages with no meaningful musician route (no collaborator, player, writer
//  or producer who leads on), each given what its Listen section would give
//  it -- a few of the artist's own tracks, then adjacent ones -- live and
//  read-only, every track checked to play.
//
//  Opt-in: `INDIGO_LIVE_RESCUE=1` and `INDIGO_DIG_MEASURE_DIR` (the bundles).
//  Report: `live-dead-end-rescue.txt` in the host's temporary directory.
//

import XCTest
@testable import Indigo

final class LiveDeadEndRescueMeasurement: XCTestCase {
    private struct Manifest: Decodable { struct Entry: Decodable { let digest: String }; let artists: [String: Entry] }

    override func tearDown() { MusicianFirst.override = nil }

    func testRescueDeadEnds() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["INDIGO_LIVE_RESCUE"] == "1", let root = environment["INDIGO_DIG_MEASURE_DIR"] else {
            throw XCTSkip("Live: set INDIGO_LIVE_RESCUE=1 and INDIGO_DIG_MEASURE_DIR.")
        }
        MusicianFirst.override = true
        let dir = URL(fileURLWithPath: root).appendingPathComponent("bundles")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        var bundles: [Int: ArtistBundle] = [:]
        for (key, entry) in manifest.artists {
            guard let id = Int(key) else { continue }
            bundles[id] = try JSONDecoder().decode(ArtistBundle.self, from: Data(contentsOf: dir.appendingPathComponent("\(entry.digest).json")))
        }
        // Musician routes, and who leads on, as DigRouteMeasurement counts them.
        let musician: Set<RelationshipKind> = [.collaborator, .personnel, .producer]
        var routes: [Int: [MusicEdge]] = [:], graph: [Int: Set<Int>] = [:]
        for (id, bundle) in bundles {
            let edges = BundleEdges.edges(from: .artist(bundle.artist.name, discogsID: id), bundle: bundle, ownIdentities: [id], sqlTargets: [])
                .filter { $0.to.kind == .artist && musician.contains($0.kind) && !MusicianFirst.isTechnicalCredit($0) }
            routes[id] = edges
            for edge in edges { if let to = edge.to.discogsID, to != id { graph[id, default: []].insert(to); graph[to, default: []].insert(id) } }
        }
        let deadEnds = bundles.keys.sorted().filter { id in
            !(routes[id] ?? []).contains { edge in edge.to.discogsID.map { !(graph[$0] ?? []).subtracting([id]).isEmpty } ?? false }
        }
        let sample = stride(from: 0, to: deadEnds.count, by: max(1, deadEnds.count / 120)).map { deadEnds[$0] }.prefix(120)

        // As the app reads it: the shelf cache is off in a test process
        // unless asked for.
        var source = TrackDiscoverySource.live
        let shelves = CatalogShelfSource(isEnabled: true)
        source.releaseVideos = { id, name in
            await ReleaseVideoTracks(shelf: { await shelves.shelf(discogsID: $0) }, release: ReleaseVideoTracks.live.release)
                .tracks(artistID: id, artist: name)
        }
        var rescued = 0, ownOnly = 0, adjacentOnly = 0, both = 0, tracks = 0, recordings = 0, requests = 0
        var firstTimes: [Double] = [], totalTimes: [Double] = [], examples: [String] = []
        for id in sample {
            guard let bundle = bundles[id] else { continue }
            let seed = TrackDiscovery.Seed(discogsID: id, name: bundle.artist.name, weight: 1)
            // What DIG's own graph gives the page: its verified credits.
            let collaborators = (routes[id] ?? []).compactMap { edge -> TrackDiscovery.Neighbour? in
                guard let other = edge.to.discogsID else { return nil }
                return .init(discogsID: other, name: edge.to.title, seed: seed, reason: edge.reason, strength: 2)
            }
            let (found, report) = await source.discover(.init(seeds: [seed], collaborators: collaborators,
                                                              knownArtists: [RecordingKey.normalizeArtist(bundle.artist.name)],
                                                              limit: 5, ownTracks: 3, releaseLookups: 3))
            requests += report.requests
            totalTimes.append(report.milliseconds)
            if let first = report.firstTrackMilliseconds { firstTimes.append(first) }
            let own = found.filter { $0.artistDiscogsID == id }.count, adjacent = found.count - own
            tracks += found.count
            recordings += found.filter(\.isRecording).count
            if !found.isEmpty {
                rescued += 1
                if own > 0 && adjacent > 0 { both += 1 } else if own > 0 { ownOnly += 1 } else { adjacentOnly += 1 }
            }
            if !found.isEmpty, examples.count < 10 {
                let genres = (bundle.styles + bundle.genres).prefix(2).map(\.name).joined(separator: ", ")
                examples.append("\(bundle.artist.name) [\(genres)]: " + found.prefix(3).map { "\($0.artist) — \($0.title) (\($0.playLabel)\($0.artistDiscogsID == id ? ", own" : ""))" }.joined(separator: "; "))
            }
        }
        firstTimes.sort(); totalTimes.sort()
        func median(_ values: [Double]) -> String { values.isEmpty ? "–" : String(format: "%.0f ms", values[values.count / 2]) }
        let pages = sample.count
        let lines = [
            "Dead-end pages in the catalogue sample (no musician route that leads on): \(deadEnds.count) of \(bundles.count); \(pages) sampled",
            "rescued — at least one track checked to play: \(rescued) of \(pages) (\(String(format: "%.0f%%", 100 * Double(rescued) / Double(max(1, pages)))))",
            "  their own tracks only \(ownOnly), adjacent only \(adjacentOnly), both \(both); \(tracks) tracks, \(recordings) of them recordings, \(tracks - recordings) radio moments",
            "time to the first track \(median(firstTimes)) median; to the whole list \(median(totalTimes)); \(String(format: "%.1f", Double(requests) / Double(max(1, pages)))) requests a page",
            "", "examples:"
        ] + examples.map { "  " + $0 }
        try lines.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("live-dead-end-rescue.txt"),
                                                atomically: true, encoding: .utf8)
    }
}
