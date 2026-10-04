//
//  PlayerFieldClock.swift
//  Indigo
//
//  The time the player's field is drawn at. It moves only while something
//  plays, and carries on from where it stopped.
//
//  It used to be the wall clock: paused, the field held its last frame, and
//  played again it jumped to wherever the wall clock had got to. A track
//  change paused it too, because the hand-off between tracks buffers. Now the
//  clock adds up only the time playback runs, rides through a stop shorter
//  than `grace` (a hand-off, not a pause), and keeps its place across launches.
//  Every copy of the field -- player, header, sidebar -- reads this one clock.
//

import Foundation
import Observation

@MainActor
@Observable
final class PlayerFieldClock {
    static let shared = PlayerFieldClock()

    /// The shader is given time modulo this, to keep float32 precise; its
    /// colour and light cycles divide it, so the wrap is not seen.
    nonisolated static let wrap: Double = 4096
    /// A stop shorter than this is a hand-off between tracks, not a pause.
    nonisolated static let grace: TimeInterval = 1.5

    private(set) var isRunning = false
    @ObservationIgnored private var accumulated: Double
    @ObservationIgnored private var runningSince: Date?
    @ObservationIgnored private var pendingStop = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "playerFieldClock"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accumulated = defaults.double(forKey: key)
    }

    /// Where the field is at `date`.
    func time(at date: Date) -> Double {
        let running = runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return (accumulated + running).truncatingRemainder(dividingBy: Self.wrap)
    }

    /// Playback started or stopped. Calling it again with the same value does
    /// nothing, so every copy of the field may report it.
    func playbackChanged(_ playing: Bool, at date: Date = .now) {
        if playing {
            pendingStop += 1
            guard runningSince == nil else { return }
            runningSince = date
            isRunning = true
        } else {
            guard runningSince != nil else { return }
            pendingStop += 1
            let ticket = pendingStop
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.grace))
                guard let self, self.pendingStop == ticket else { return }
                self.stop(at: date.addingTimeInterval(Self.grace))
            }
        }
    }

    /// Stops now, without the grace. For a stop known to be a pause, and tests.
    func stop(at date: Date) {
        guard let since = runningSince else { return }
        accumulated = (accumulated + max(0, date.timeIntervalSince(since))).truncatingRemainder(dividingBy: Self.wrap)
        runningSince = nil
        isRunning = false
        defaults.set(accumulated, forKey: key)
    }
}
