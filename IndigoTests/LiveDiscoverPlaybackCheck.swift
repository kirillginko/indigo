//
//  LiveDiscoverPlaybackCheck.swift
//  IndigoTests
//
//  Discover's tracks through the app's own player, for real: a YouTube
//  recording, a SoundCloud or Mixcloud radio episode seeked to the moment
//  the track was played, a Lot Radio HLS episode the same way, and a dead
//  video queued before a good one, to see the player go on.
//
//  Opt-in: `INDIGO_LIVE_PLAYBACK=1`. Report: `live-discover-playback.txt` in
//  the host's temporary directory.
//

#if os(macOS)
import XCTest
import AppKit
@testable import Indigo

@MainActor
final class LiveDiscoverPlaybackCheck: XCTestCase {
    func testDiscoveriesPlay() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_LIVE_PLAYBACK"] == "1", "Live: set INDIGO_LIVE_PLAYBACK=1.")
        // Real discoveries from a listener whose crate is a few well-played artists.
        let seeds = [(45, "Aphex Twin"), (2742, "Björk"), (1289, "Can"), (12577, "Burial"), (1818, "Arthur Russell")]
            .enumerated().map { TrackDiscovery.Seed(discogsID: $0.element.0, name: $0.element.1, weight: 1 - Double($0.offset) * 0.05) }
        let (tracks, _) = await TrackDiscoverySource.live.discover(.init(seeds: seeds, limit: 24))
        var lines = ["\(tracks.count) discoveries to try"]
        let player = PlaybackCoordinator(defaults: UserDefaults(suiteName: "discover-playback-check")!)
        // As the app does it: the embed's web view in a visible window, which
        // WebKit needs before it plays anything (`EmbedPlayerSurface`).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = player.embed.webView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        defer { player.pause() }

        func waitPlaying(_ id: String, past: Double = 1, timeout: Double = 30) async -> (Bool, Double, Double) {
            let started = Date()
            while Date().timeIntervalSince(started) < timeout {
                try? await Task.sleep(for: .milliseconds(500))
                if player.current?.id == id, player.isPlaying, player.position > past {
                    return (true, Date().timeIntervalSince(started), player.position)
                }
            }
            return (false, timeout, player.position)
        }

        func attempt(_ label: String, _ track: DiscoveredTrack?) async {
            guard let track else { lines.append("\(label): none among the discoveries"); return }
            let (item, start) = track.mediaItem
            player.play([item])
            if let start { player.seekWhenReady(to: TimeInterval(start), in: item.id) }
            let target = Double(start ?? 0)
            let (ok, seconds, position) = await waitPlaying(item.id, past: target > 0 ? target + 1 : 1)
            lines.append("\(label): \(track.artist) — \(track.title): \(ok ? "playing" : "NOT playing") after \(String(format: "%.1f", seconds))s, at \(Int(position))s\(start.map { " (track at \($0)s)" } ?? ""), seek bar \(player.canSeek ? "usable" : "NOT usable")")
            // The listener scrubs: does it go there and stay, without the
            // pending seek pulling it back?
            if ok, player.canSeek {
                let scrub = min(player.duration - 30, position + 300)
                player.seek(to: scrub)
                try? await Task.sleep(for: .seconds(6))
                lines.append("   scrubbed to \(Int(scrub))s: now at \(Int(player.position))s, \(abs(player.position - scrub) < 15 ? "held" : "NOT held")")
            }
            player.pause()
            try? await Task.sleep(for: .seconds(1))
        }

        await attempt("YouTube recording", tracks.first { $0.isRecording })
        await attempt("SoundCloud/Mixcloud episode, from the track's moment", tracks.first { track in
            if case .episode(let listen, let at) = track.source { return at > 60 && listen.provider == NTSProvider.providerID }
            return false
        })
        var lot = tracks.first { track in
            if case .episode(let listen, let at) = track.source { return at > 60 && listen.provider == LotProvider.providerID }
            return false
        }
        // None among them: one from the verified sample (`track-sample.json`).
        if lot == nil, let folder = ProcessInfo.processInfo.environment["INDIGO_DIG_MEASURE_DIR"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("track-sample.json")),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let row = rows.first(where: { $0["provider"] as? String == "lotradio" && $0["plays"] as? Bool == true && (($0["offset_seconds"] as? Int) ?? 0) > 60 }),
           let link = row["archive_url"] as? String, let url = URL(string: link), let at = row["offset_seconds"] as? Int {
            let title = row["raw_track_title"] as? String ?? "Track"
            lot = DiscoveredTrack(artist: row["raw_artist_name"] as? String ?? "", artistDiscogsID: 0, title: title,
                                  source: .episode(RadioListen(provider: LotProvider.providerID, episode: "lot/sample",
                                                               episodeTitle: row["show"] as? String ?? "Lot Radio", showTitle: row["show"] as? String,
                                                               airedAt: nil, played: title, offsetSeconds: at, archiveURL: url), at: at),
                                  artworkURL: nil, reason: "", via: "", playable: .yes, score: 0)
        }
        await attempt("Lot Radio HLS episode, from the track's moment", lot)

        // A dead video first, a good one after: does the player go on?
        if let good = tracks.first(where: \.isRecording) {
            let dead = MediaItem(id: "youtube.dead", sourceID: "youtube", kind: .track, title: "Gone",
                                 playbackURL: URL(string: "https://www.youtube.com/watch?v=00000000000")!, embedProvider: .youtube)
            let next = good.mediaItem.item
            player.play([dead, next], startingAt: 0)
            let (ok, seconds, _) = await waitPlaying(next.id, timeout: 45)
            lines.append("Dead video then a good one: \(ok ? "went on to the good one after \(String(format: "%.1f", seconds))s" : "did NOT go on (current: \(player.current?.title ?? "nothing"))")")
        }
        try lines.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("live-discover-playback.txt"),
                                                atomically: true, encoding: .utf8)
    }
}
#endif
