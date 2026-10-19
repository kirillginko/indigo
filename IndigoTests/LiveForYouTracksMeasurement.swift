//
//  LiveForYouTracksMeasurement.swift
//  IndigoTests
//
//  For You's "Tracks to hear" on this Mac's real histories, as the app works
//  it out (`DigStore.refreshDiscover`): the inputs read from a copy of the
//  stores, the radio's tracks found and checked, then DIG's collaborators
//  walked beside them and everything ranked again. Cold (an empty cache),
//  then warm (the same cache, as a second look within the day). Live and
//  read-only.
//
//  Opt-in: `INDIGO_LIVE_FORYOU_TRACKS=1`. Report (private listening data, kept
//  out of Git): `live-foryou-tracks.txt` in the host's temporary directory.
//  Bytes are this machine's interface counters around each look, so an
//  upper bound that includes anything else on the network at the time.
//

import XCTest
import SwiftData
@testable import Indigo

final class LiveForYouTracksMeasurement: XCTestCase {
    private final class First: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var ms: Double?
        func mark(_ start: ContinuousClock.Instant) {
            let spent = ContinuousClock.now - start
            lock.withLock { if ms == nil { ms = Self.ms(spent) } }
        }
        static func ms(_ spent: Duration) -> Double {
            Double(spent.components.seconds) * 1000 + Double(spent.components.attoseconds) / 1e15
        }
    }

    /// Bytes in and out on every interface but loopback.
    private static func interfaceBytes() -> UInt64 {
        var total: UInt64 = 0
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return 0 }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: entry.ifa_name) != "lo0",
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            total += UInt64(data.pointee.ifi_ibytes) + UInt64(data.pointee.ifi_obytes)
        }
        return total
    }

    func testTracksToHearOnTheRealHistories() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_LIVE_FORYOU_TRACKS"] == "1",
                          "Live: set INDIGO_LIVE_FORYOU_TRACKS=1.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let development = support.appendingPathComponent("Development")
        var out: [String] = []
        for (label, userData) in [("production", support), ("development", development)] {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("ForYouTracks-\(label)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: copy) }
            for (folder, name) in [(userData, "UserData.store"), (development, "Local.store")] {
                for suffix in ["", "-wal", "-shm"] {
                    let from = folder.appendingPathComponent(name + suffix)
                    if FileManager.default.fileExists(atPath: from.path) {
                        try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix))
                    }
                }
            }
            let container = try Persistence.makeSplitContainer(userData: copy.appendingPathComponent("UserData.store"),
                                                               local: copy.appendingPathComponent("Local.store"))
            // As of the copy's last activity, so the "now" half means what it
            // meant then.
            let probe = PersonalInputs.read(context: ModelContext(container), asOf: .distantFuture)
            let now = ((probe.crate.map(\.addedAt) + probe.met.map(\.lastAt)).max() ?? Date()).addingTimeInterval(3_600)

            var source = TrackDiscoverySource.live
            source.cache = TrackDiscoveryCache()
            out.append("== \(label)")
            var last: [DiscoveredTrack] = []
            for look in ["cold", "warm"] {
                let bytes = Self.interfaceBytes()
                let start = ContinuousClock.now
                let inputs = DigStore.discoverInputs(context: ModelContext(container), now: now, collaborators: false)
                let read = First.ms(ContinuousClock.now - start)
                let seeds = inputs.seeds
                let walk = Task.detached { DigStore.discoverCollaborators(of: seeds, context: ModelContext(container)) }
                var ask = TrackDiscoverySource.Ask(seeds: inputs.seeds, taste: inputs.taste, knownArtists: inputs.knownArtists,
                                                   knownTracks: inputs.knownTracks, limit: 12, releaseLookups: 2)
                let first = First()
                var (tracks, report) = await source.discover(ask) { _ in first.mark(start) }
                let radioOnly = First.ms(ContinuousClock.now - start)
                ask.collaborators = await walk.value
                var second = TrackDiscoverySource.Report()
                if !ask.collaborators.isEmpty {
                    let joint = await source.discover(ask)
                    second = joint.report
                    if !joint.tracks.isEmpty { tracks = joint.tracks }
                }
                let total = First.ms(ContinuousClock.now - start)
                out.append(String(format: "%@: inputs %.0f ms; first track %@ ms; radio pass %.0f ms; with collaborators %.0f ms; requests %d + %d, cached reads %d + %d, failures %d + %d; ~%.0f KB on the network",
                                  look as NSString, read, first.ms.map { String(format: "%.0f", $0) } ?? "–", radioOnly, total,
                                  report.requests, second.requests, report.cachedReads, second.cachedReads,
                                  report.failures, second.failures, Double(Self.interfaceBytes() - bytes) / 1024))
                let used = second.requests > 0 || second.cachedReads > 0 ? second : report
                out.append("  seeds \(used.seeds) (on radio \(used.seedsOnRadio)), neighbours \(used.neighbours) (verified \(used.verifiedNeighbours)), appearance rows \(used.appearanceRows), recordings \(used.recordings), episode tracks \(used.episodeTracks), release videos \(used.releaseVideos), name only \(used.metadataOnly); checked: plays \(used.checkedPlays), does not \(used.checkedDoesNot), unknown \(used.checkedUnknown)")
                last = tracks
            }
            let seeds = DigStore.discoverInputs(context: ModelContext(container), now: now, collaborators: false).seeds
            out.append("  starting points: " + seeds.map { "\($0.name) [\($0.signal?.rawValue ?? "-")]" }.joined(separator: "; "))
            for track in last {
                let kind = track.isRecording ? "Play track" : "Hear in radio show"
                let place: String
                switch track.source {
                case .recording(_, let channel): place = track.release.map { "on \($0)" } ?? "upload\(channel.map { " · \($0)" } ?? "")"
                case .episode(let listen, let at): place = "\(listen.showTitle ?? listen.episodeTitle) at \(at / 60):\(String(format: "%02d", at % 60))"
                }
                out.append("  \(kind) | \(track.artist) — \(track.title) | \(place) | \(track.reason) | via \(track.via) [\(track.signal?.rawValue ?? "-")]\(track.knownArtist == true ? " | known artist" : "") | \(track.playable)")
            }
            out.append("")
        }
        try out.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("live-foryou-tracks.txt"),
                                              atomically: true, encoding: .utf8)
    }
}
