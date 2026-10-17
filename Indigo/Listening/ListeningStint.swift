//
//  ListeningStint.swift
//  Indigo
//
//  How much of a thing was actually heard.
//
//  Harder than it sounds, and worth its own type. `position` is useless for a
//  live stream, which has none; wall-clock since the item loaded is useless
//  for anything paused halfway through lunch; and reading progress at the
//  moment a track ends catches the engine after it has already rewound. So a
//  stint accumulates playing time across pauses and remembers the furthest it
//  ever got, rather than asking either question once at the end.
//
//  And the clock alone is not enough either. A YouTube upload left on a crate
//  queue overnight in the simulator logged 22,010 seconds heard at 13%
//  through: the network went and the Mac slept, the widget stopped moving
//  without ever saying it had paused, and every second of the night counted.
//  So where an item has a playhead, a stretch is credited no more than the
//  playhead moved in it — a stall, a suspended process or a frozen widget
//  moves the clock and not the playhead.
//

import Foundation

nonisolated struct ListeningStint {
    /// Seconds banked from earlier stretches of playing.
    private var banked: TimeInterval = 0
    /// When the current stretch of playing began, if one is running.
    private var startedAt: Date?
    /// Where the playhead stood as the current stretch began, for items that
    /// have one. Nil for a live stream, which has none.
    private var startedAtPosition: TimeInterval?
    /// The furthest through the item this stint ever reached, 0…1.
    private(set) var furthest: Double = 0

    /// Seconds of playing so far, including the stretch still running.
    ///
    /// The running stretch is counted by the clock alone, as there is no
    /// playhead to hand here; `update` corrects it against the playhead.
    func heard(now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return banked }
        return banked + max(0, now.timeIntervalSince(startedAt))
    }

    /// Follows the transport. Called on every state change, so it costs a
    /// comparison in the common case where nothing about playing changed.
    ///
    /// `isPlaying` means sound is coming out — not loading, not buffering,
    /// not reopening. `position` is the playhead, for items that have one.
    /// A sample taken while playing banks the stretch so far and starts the
    /// next one from here, so each stretch is checked against the playhead.
    mutating func update(
        isPlaying: Bool,
        progress: Double = 0,
        position: TimeInterval? = nil,
        now: Date = Date()
    ) {
        furthest = max(furthest, min(1, max(0, progress)))
        if let began = startedAt {
            banked += credit(from: began, at: startedAtPosition, to: now, at: position)
            startedAt = nil
            startedAtPosition = nil
        }
        if isPlaying {
            startedAt = now
            startedAtPosition = position
        }
    }

    /// The playhead was moved by the listener. Whatever ran up to here has
    /// already been banked by `update`; this only starts the running stretch
    /// from the new place, so a jump forward is not taken for listening and a
    /// jump back is not taken for a stall.
    mutating func moved(to position: TimeInterval?, now: Date = Date()) {
        guard startedAt != nil else { return }
        startedAt = now
        startedAtPosition = position
    }

    /// What one stretch of playing is worth: the clock, and where there is a
    /// playhead, no more than it moved.
    private func credit(
        from began: Date, at startPosition: TimeInterval?,
        to now: Date, at endPosition: TimeInterval?
    ) -> TimeInterval {
        let elapsed = max(0, now.timeIntervalSince(began))
        guard let startPosition, let endPosition else { return elapsed }
        return min(elapsed, max(0, endPosition - startPosition))
    }

    /// The item played itself out. Recorded explicitly because the engine has
    /// usually rewound by the time anyone asks how far it got.
    mutating func complete() {
        furthest = 1
    }

    /// Closes the stint and hands back what it saw.
    mutating func finish(now: Date = Date()) -> (seconds: TimeInterval, completion: Double) {
        let seconds = heard(now: now)
        let completion = furthest
        self = ListeningStint()
        return (seconds, completion)
    }
}
