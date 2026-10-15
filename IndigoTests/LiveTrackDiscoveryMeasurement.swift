//
//  LiveTrackDiscoveryMeasurement.swift
//  IndigoTests
//
//  DIG Discover on real listeners: this Mac's own history (a copy of the
//  stores) and fourteen radio hosts across genres, each standing in for a
//  listener whose crate is the ten verified artists their show plays most.
//  Every offered track is checked to play through the integration that would
//  play it. Live and read-only.
//
//  Opt-in: `INDIGO_LIVE_TRACKS=1`, `INDIGO_DIG_MEASURE_DIR` (holding
//  `listeners.json`), `INDIGO_MEASURE_TASTE_DIR` (store copies). Report:
//  `live-track-discovery.txt` in the host's temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class LiveTrackDiscoveryMeasurement: XCTestCase {
    private struct Listener: Decodable {
        struct Seed: Decodable { let discogs: Int; let name: String; let plays: Int }
        let bucket: String
        let show: String
        let seeds: [Seed]
    }

    override func tearDown() { MusicianFirst.override = nil; TrackDiscoveryFeature.override = nil }

    func testDiscoverForRealListeners() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["INDIGO_LIVE_TRACKS"] == "1", let measure = environment["INDIGO_DIG_MEASURE_DIR"] else {
            throw XCTSkip("Live: set INDIGO_LIVE_TRACKS=1 and INDIGO_DIG_MEASURE_DIR.")
        }
        MusicianFirst.override = true
        let listeners = try JSONDecoder().decode([Listener].self,
                                                 from: Data(contentsOf: URL(fileURLWithPath: measure).appendingPathComponent("listeners.json")))
        let source = TrackDiscoverySource.live
        var lines: [String] = []
        var totals = (listeners: 0, offered: 0, recordings: 0, episodes: 0, newArtists: 0, playsChecked: 0, doesNot: 0, unknown: 0, metadata: 0)
        var times: [Double] = []

        func record(_ label: String, _ tracks: [DiscoveredTrack], _ report: TrackDiscoverySource.Report, known: Set<String>) {
            totals.listeners += 1
            totals.offered += tracks.count
            totals.recordings += tracks.filter { if case .recording = $0.source { true } else { false } }.count
            totals.episodes += tracks.filter { if case .episode = $0.source { true } else { false } }.count
            let fresh = tracks.filter { !known.contains(RecordingKey.normalizeArtist($0.artist)) }.count
            totals.newArtists += fresh
            totals.playsChecked += report.checkedPlays
            totals.doesNot += report.checkedDoesNot
            totals.unknown += report.checkedUnknown
            totals.metadata += report.metadataOnly
            times.append(report.milliseconds)
            lines.append("")
            lines.append("== \(label): \(tracks.count) playable tracks (\(fresh) by artists new to them), \(Set(tracks.map(\.artistDiscogsID)).count) artists, \(String(format: "%.0f", report.milliseconds)) ms, \(report.requests) requests")
            lines.append("   seeds \(report.seeds), on radio \(report.seedsOnRadio); neighbours \(report.neighbours), verified \(report.verifiedNeighbours); appearance rows \(report.appearanceRows): recordings \(report.recordings), episode tracks \(report.episodeTracks), name only \(report.metadataOnly); checks: plays \(report.checkedPlays), does not \(report.checkedDoesNot), unknown \(report.checkedUnknown)")
            for track in tracks.prefix(6) {
                let source: String
                switch track.source {
                case .recording(_, let channel): source = "▶ recording\(channel.map { " (\($0))" } ?? "")"
                case .episode(let listen, let offset): source = "▶ \(listen.showTitle ?? listen.episodeTitle) at \(offset / 60):\(String(format: "%02d", offset % 60))"
                }
                lines.append("   \(track.artist) — \(track.title)  \(source)  · \(track.reason)")
            }
        }

        for listener in listeners {
            let seeds = listener.seeds.enumerated().map { index, seed in
                TrackDiscovery.Seed(discogsID: seed.discogs, name: seed.name, weight: 1 - Double(index) * 0.04)
            }
            let known = Set(listener.seeds.map { RecordingKey.normalizeArtist($0.name) })
            let (tracks, report) = await source.discover(seeds: seeds, collaborators: [], taste: .empty,
                                                         knownArtists: known, knownTracks: [])
            record("\(listener.show) [\(listener.bucket)]", tracks, report, known: known)
        }

        // This Mac's listener, through the app's own inputs.
        if let folder = environment["INDIGO_MEASURE_TASTE_DIR"] {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Discover-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: copy) }
            for name in ["UserData.store", "Local.store"] {
                for suffix in ["", "-wal", "-shm"] {
                    let from = URL(fileURLWithPath: folder).appendingPathComponent(name + suffix)
                    if FileManager.default.fileExists(atPath: from.path) {
                        try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix))
                    }
                }
            }
            let container = try Persistence.makeSplitContainer(
                userData: copy.appendingPathComponent("UserData.store"), local: copy.appendingPathComponent("Local.store"))
            let dig = DigStore(context: ModelContext(container))
            let started = ContinuousClock.now
            let inputs = dig.discoverInputs()
            let inputTime = ContinuousClock.now - started
            let (tracks, report) = await source.discover(seeds: inputs.seeds, collaborators: inputs.collaborators,
                                                         taste: inputs.taste, knownArtists: inputs.knownArtists,
                                                         knownTracks: inputs.knownTracks)
            record("You (this Mac's history; seeds \(inputs.seeds.map(\.name).joined(separator: ", ")); inputs read in \(inputTime))",
                   tracks, report, known: inputs.knownArtists)
        }

        times.sort()
        lines.insert("Discover, \(totals.listeners) listeners: \(totals.offered) playable tracks offered (\(totals.recordings) recordings, \(totals.episodes) episode tracks), \(totals.newArtists) by artists new to the listener. Checks before offering: \(totals.playsChecked) play, \(totals.doesNot) do not, \(totals.unknown) unknown (never offered). Name-only tracks seen and left out: \(totals.metadata). Time to a list: \(String(format: "%.0f", times.isEmpty ? 0 : times[times.count / 2])) ms median, \(String(format: "%.0f", times.last ?? 0)) ms slowest.", at: 0)
        try lines.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("live-track-discovery.txt"),
                                                atomically: true, encoding: .utf8)
    }
}
