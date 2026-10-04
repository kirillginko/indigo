//
//  ShaderClock.swift
//  Indigo
//
//  The time a moving field is drawn at. It moves only while the field is
//  meant to -- the player's while something plays, For You's while the page is
//  on screen -- and carries on from where it stopped, across launches too.
//
//  Both used to start from somewhere else each time. The player's was the wall
//  clock: paused, it held its last frame, and played again it jumped to
//  wherever the wall clock had got to; a track change paused it as well.
//  For You's lived in the page's view state, so leaving the page and coming
//  back started it, and its ninety-second fade into warm colours, from zero.
//  Each copy of a field reads one shared clock.
//

import Foundation
import Observation

@MainActor
@Observable
final class ShaderClock {
    /// The player's field, across the player, header and sidebar. Its colour
    /// and light cycles divide 4,096s, so the wrap is not seen; a stop shorter
    /// than 1.5s is a hand-off between tracks, not a pause.
    static let player = ShaderClock(key: "playerFieldClock", wrap: 4096, grace: 1.5)
    /// For You's field. It slides with time, so a wrap is a jump -- once an
    /// hour of looking at the page. Larger is not safe: at tens of thousands
    /// of seconds the field stopped resolving its per-frame step and froze.
    static let explore = ShaderClock(key: "exploreFieldClock", wrap: 3600, grace: 0)

    let wrap: Double
    let grace: TimeInterval
    private(set) var isRunning = false
    @ObservationIgnored private var accumulated: Double
    /// Like `accumulated`, never wrapped.
    @ObservationIgnored private var total: Double
    /// Like `total`, for this run of the app only: for what should happen again
    /// at every launch, like a fade in.
    @ObservationIgnored private var session: Double = 0
    @ObservationIgnored private var runningSince: Date?
    @ObservationIgnored private var pendingStop = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    init(key: String, wrap: Double, grace: TimeInterval, defaults: UserDefaults = .standard) {
        self.key = key
        self.wrap = wrap
        self.grace = grace
        self.defaults = defaults
        accumulated = defaults.double(forKey: key).truncatingRemainder(dividingBy: wrap)
        total = defaults.double(forKey: key + ".total")
    }

    /// A main-actor deinit hops to the executor, and the hop aborts the
    /// process (as `CrateService`'s and the sidebar's did). The app's two
    /// clocks are never freed; tests make and drop their own.
    nonisolated deinit {}

    /// Where the field is at `date`.
    func time(at date: Date) -> Double {
        let running = runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return (accumulated + running).truncatingRemainder(dividingBy: wrap)
    }

    /// All the time the field has moved, never wrapped.
    func totalTime(at date: Date) -> Double {
        total + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    /// The time the field has moved since the app launched, never wrapped.
    func sessionTime(at date: Date) -> Double {
        session + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    /// The field should or should not be moving. Calling it again with the
    /// same value does nothing, so every copy of a field may report it. A stop
    /// takes effect after `grace`, unless it starts again first.
    func setRunning(_ running: Bool, at date: Date = .now) {
        if running {
            pendingStop += 1
            guard runningSince == nil else { return }
            runningSince = date
            isRunning = true
        } else {
            guard runningSince != nil else { return }
            pendingStop += 1
            guard grace > 0 else { return stop(at: date) }
            let ticket = pendingStop
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.grace))
                guard self.pendingStop == ticket else { return }
                self.stop(at: date.addingTimeInterval(self.grace))
            }
        }
    }

    /// Stops now, without the grace.
    func stop(at date: Date) {
        guard let since = runningSince else { return }
        let ran = max(0, date.timeIntervalSince(since))
        accumulated = (accumulated + ran).truncatingRemainder(dividingBy: wrap)
        total += ran
        session += ran
        runningSince = nil
        isRunning = false
        defaults.set(accumulated, forKey: key)
        defaults.set(total, forKey: key + ".total")
    }
}
