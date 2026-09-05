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

import Foundation

nonisolated struct ListeningStint {
    /// Seconds banked from earlier stretches of playing.
    private var banked: TimeInterval = 0
    /// When the current stretch of playing began, if one is running.
    private var startedAt: Date?
    /// The furthest through the item this stint ever reached, 0…1.
    private(set) var furthest: Double = 0

    /// Seconds of playing so far, including the stretch still running.
    func heard(now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return banked }
        return banked + max(0, now.timeIntervalSince(startedAt))
    }

    /// Follows the transport. Called on every state change, so it costs a
    /// comparison in the common case where nothing about playing changed.
    mutating func update(isPlaying: Bool, progress: Double = 0, now: Date = Date()) {
        furthest = max(furthest, min(1, max(0, progress)))
        switch (isPlaying, startedAt) {
        case (true, nil):
            startedAt = now
        case (false, .some(let began)):
            banked += max(0, now.timeIntervalSince(began))
            startedAt = nil
        default:
            break
        }
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
