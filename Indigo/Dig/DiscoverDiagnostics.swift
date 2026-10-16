//
//  DiscoverDiagnostics.swift
//  Indigo
//
//  How Discover's tracks fare when somebody presses Play, counted on the
//  device and nowhere else: did playback begin, how long after DIG opened,
//  was the track heard out or skipped, did the queue go on to the next
//  discovery, was it crated. Read from the player's own state while a
//  discovery is on; kept as a few numbers in a file in Caches and shown in
//  the Debug screen. No identifiers, nothing sent, no backend table.
//

import Foundation
import Observation

@MainActor
@Observable
final class DiscoverDiagnostics {
    static let shared = DiscoverDiagnostics()

    struct Counts: Codable, Equatable {
        var pressed = 0, began = 0, neverBegan = 0
        var recordings = 0, radio = 0
        var completed = 0, skipped = 0, continued = 0, crated = 0
        /// Seconds from opening DIG to hearing the track, newest last.
        var secondsToHear: [Double] = []

        var medianSecondsToHear: Double? {
            guard !secondsToHear.isEmpty else { return nil }
            return secondsToHear.sorted()[secondsToHear.count / 2]
        }
    }

    private(set) var counts = Counts()
    @ObservationIgnored private var watching: Task<Void, Never>?
    @ObservationIgnored private var discoveryIDs: [String: (start: Int, isRecording: Bool)] = [:]
    @ObservationIgnored private let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("discover-diagnostics.json")

    private init() {
        if let file, let data = try? Data(contentsOf: file), let held = try? JSONDecoder().decode(Counts.self, from: data) {
            counts = held
        }
    }

    /// Play was pressed on these discoveries, the first one now.
    func pressed(_ tracks: [DiscoveredTrack], opened: Date, player: PlaybackCoordinator, crate: CrateService) {
        guard let first = tracks.first else { return }
        counts.pressed += 1
        if first.isRecording { counts.recordings += 1 } else { counts.radio += 1 }
        for track in tracks {
            let (item, start) = track.mediaItem
            discoveryIDs[item.id] = (start ?? 0, track.isRecording)
        }
        save()
        watching?.cancel()
        let firstID = first.mediaItem.item.id
        watching = Task { [weak self] in await self?.watch(firstID, opened: opened, player: player, crate: crate) }
    }

    /// Follows the player while discoveries are on, a reading a second.
    private func watch(_ firstID: String, opened: Date, player: PlaybackCoordinator, crate: CrateService) async {
        var current = firstID
        var heard: Double = 0
        var began = false
        let pressedAt = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let now = player.current
            if now?.id == current {
                let start = Double(discoveryIDs[current]?.start ?? 0)
                let position = player.position - start
                if player.isPlaying, position > 1, !began {
                    began = true
                    counts.began += 1
                    counts.secondsToHear.append((Date().timeIntervalSince(opened) * 10).rounded() / 10)
                    counts.secondsToHear = Array(counts.secondsToHear.suffix(200))
                    save()
                }
                heard = max(heard, position)
                if let item = now, crate.isCrated(nowPlaying: item, liveShow: nil), discoveryIDs[current] != nil {
                    counts.crated += 1
                    discoveryIDs[current] = nil
                    save()
                }
                if !began, Date().timeIntervalSince(pressedAt) > 20 {
                    counts.neverBegan += 1
                    save()
                    return
                }
                continue
            }
            // It moved on: what became of the one that was on.
            let wasRecording = discoveryIDs[current]?.isRecording ?? true
            if began {
                let duration = player.duration > 0 && wasRecording ? player.duration : 0
                if heard < 30 { counts.skipped += 1 } else if duration > 0 ? heard >= duration * 0.9 : heard >= 180 { counts.completed += 1 }
            }
            guard let next = now, discoveryIDs[next.id] != nil else { save(); return }
            counts.continued += 1
            current = next.id
            heard = 0
            began = false
            save()
        }
    }

    func reset() { counts = Counts(); save() }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(counts) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
