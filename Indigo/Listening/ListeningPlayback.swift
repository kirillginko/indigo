//
//  ListeningPlayback.swift
//  Indigo
//
//  One playback, however many rows it wrote.
//
//  `PlaybackWitness` writes a play down as every node it was an encounter
//  with -- the recording and its artist, a show and its station -- so the
//  log holds two or three rows for one listen. Counting rows counts each
//  listen twice. The rows of one listen already share everything that
//  describes the listening: the same moment (one `Date` handed to every
//  row), the same action, the same seconds and completion, and the same
//  surface. That is the key here; no new field is needed to tie them.
//
//  Read-only: a view over events, for diagnostics and replays.
//
//  It is a heuristic, and its limits are these:
//  - Two different listens with the same millisecond, action, seconds,
//    completion and surface would merge. One device writes one listen at a
//    time, so only two devices' clocks could collide -- and then the seconds
//    would have to match to the bit.
//  - It trusts every row of a listen to carry the same moment. The witness
//    hands one `Date` to all of them, and a restore or a sync copies the
//    field whole (`EventValue`); a writer that stamped each row with its own
//    `Date()` would split one listen into several.
//  - Rows from before attribution group the same way, without a surface.
//  - A listen whose artist could not be named wrote a recording alone, and
//    one listen to a show writes the show and its station; both count once.
//  - Saves, page opens and dismissals are not playback and are not grouped.
//  - It cannot tell a listen from a duplicated row; `UserDataDedupe`, by
//    event id, is what removes those.
//

import Foundation

nonisolated struct ListeningPlayback: Sendable, Equatable {
    let at: Date
    let action: ListeningAction
    let seconds: Double
    let surface: ListeningSurface?
    /// The rows it wrote, by kind.
    var recording: String?
    var artist: String?
    var others: [MusicNodeKind] = []
    var rows = 0

    /// The rows of one listen share these; two listens never do.
    struct Key: Hashable {
        let millisecond: Int64
        let action: String
        let seconds: Double
        let completion: Double
        let surface: [String]
    }

    static func key(_ event: ListeningEvent) -> Key {
        Key(millisecond: Int64((event.at.timeIntervalSinceReferenceDate * 1000).rounded()), action: event.actionRaw,
            seconds: event.seconds, completion: event.completion,
            surface: event.tags.filter(ListeningSurface.isSurfaceTag))
    }

    /// Plays and skips, one per listen, oldest first. Saves, page opens and
    /// dismissals are not playback and are left out.
    static func group(_ events: [ListeningEvent]) -> [ListeningPlayback] {
        var held: [Key: ListeningPlayback] = [:]
        for event in events where event.action == .played || event.action == .skipped {
            let key = key(event)
            var playback = held[key] ?? ListeningPlayback(at: event.at, action: event.action, seconds: event.seconds, surface: event.surface)
            switch event.kind {
            case .recording: playback.recording = playback.recording ?? event.title
            case .artist: playback.artist = playback.artist ?? event.title
            default: playback.others.append(event.kind)
            }
            playback.rows += 1
            held[key] = playback
        }
        return held.values.sorted { $0.at != $1.at ? $0.at < $1.at : ($0.recording ?? $0.artist ?? "") < ($1.recording ?? $1.artist ?? "") }
    }
}

/// Attributed playback, counted once per listen: by the screen it started
/// on and by the recommendation that led there.
nonisolated struct AttributionSummary: Sendable {
    struct Count: Sendable, Equatable { var played = 0; var skipped = 0 }
    var playbacks = 0
    var rows = 0
    var attributed = 0
    var byScreen: [String: Count] = [:]
    var byOrigin: [String: Count] = [:]
    /// Listens whose rows did not look like one listen: more than one
    /// recording or artist under one key. Should be none.
    var suspect = 0

    init(_ events: [ListeningEvent]) {
        let playbacks = ListeningPlayback.group(events)
        self.playbacks = playbacks.count
        rows = playbacks.reduce(0) { $0 + $1.rows }
        for p in playbacks {
            if p.rows > 3 { suspect += 1 }
            guard let surface = p.surface else { continue }
            attributed += 1
            let origin = surface.origin.map { "\($0.screen)\($0.route.map { " (\($0))" } ?? "")" } ?? "–"
            if p.action == .played { byScreen[surface.screen, default: Count()].played += 1; byOrigin[origin, default: Count()].played += 1 }
            else { byScreen[surface.screen, default: Count()].skipped += 1; byOrigin[origin, default: Count()].skipped += 1 }
        }
    }

    var lines: [String] {
        var out = ["\(playbacks) playbacks from \(rows) rows (plays and skips); \(attributed) attributed; \(suspect) that do not look like one listen"]
        out.append("by screen (played / skipped):")
        for (screen, c) in byScreen.sorted(by: { ($0.value.played + $0.value.skipped, $1.key) > ($1.value.played + $1.value.skipped, $0.key) }) {
            out.append("  \(screen): \(c.played) / \(c.skipped)")
        }
        out.append("by recommendation origin (played / skipped):")
        for (origin, c) in byOrigin.sorted(by: { ($0.value.played + $0.value.skipped, $1.key) > ($1.value.played + $1.value.skipped, $0.key) }) {
            out.append("  \(origin): \(c.played) / \(c.skipped)")
        }
        return out
    }
}
