//
//  PlaybackWitness.swift
//  Indigo
//
//  Turns playing into evidence.
//
//  The player deliberately knows nothing about SwiftData, DIG or the graph —
//  it reports that an item's listening ended and how much of it there was, and
//  stops there. This is the piece on the other side of that line: it decides
//  what a played item *was* in graph terms, and writes it down.
//
//  One play usually produces more than one row, and that is the point. Putting
//  on a Noods episode is an encounter with the show, with the station, and —
//  when the item names one — with the artist. Phase 2 asks "where have I heard
//  this artist", and the only way that question has an answer is if the artist
//  was logged at the time rather than inferred from a show title later.
//

import Foundation
import SwiftData

@MainActor
final class PlaybackWitness {
    private let log: ListeningLog

    init(context: ModelContext) {
        self.log = ListeningLog(context: context)
    }

    /// Present so that releasing one under XCTest does not abort the host.
    /// An app-module main-actor class with no explicit deinit is torn down
    /// through `swift_task_deinitOnExecutorImpl`, which crashes only under
    /// test injection — see `DigStore`, which carries the same line for the
    /// same reason.
    nonisolated deinit {}

    /// Starts listening to the player. Replaces any hook already installed,
    /// so watching twice logs once.
    func watch(_ player: PlaybackCoordinator) {
        player.onListeningEnded = { [weak self] item, seconds, completion in
            self?.record(item, seconds: seconds, completion: completion)
        }
    }

    /// Writes one play down, as every node it was an encounter with.
    func record(_ item: MediaItem, seconds: TimeInterval, completion: Double, at: Date = Date()) {
        let reading = Self.reading(for: item, resolveRecording: { [log] key in
            var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.matchKey == key })
            descriptor.fetchLimit = 1
            return (try? log.context.fetch(descriptor))?.first
        })
        // Three outcomes, not two. Long enough is listening; long enough to
        // have been a decision and no longer is a rejection, which is worth
        // knowing; and anything below that is a mis-click. A hundred rows of
        // the last kind is a history of a mouse rather than of a listener.
        let action: ListeningAction
        switch seconds {
        case ListeningEvent.accidentSeconds...: action = .played
        case ListeningEvent.noticedSeconds...: action = .skipped
        default: return
        }

        for node in reading.subjects {
            log.record(
                node, action: action, at: at,
                seconds: seconds, completion: completion,
                tags: item.genres, source: reading.source
            )
        }
    }

    // MARK: - What an item is

    /// Everything a played item counts as an encounter with, and where it
    /// came from.
    nonisolated struct Reading {
        var subjects: [MusicNode] = []
        var source = ListeningSource()
    }

    /// Pure, so the mapping can be tested without a player or a store.
    ///
    /// `resolveRecording` is handed in rather than looked up here because a
    /// node is a value and has no context to ask — and because a track that
    /// has never been crated still deserves a row, just one that cannot be
    /// opened yet. Its key is the same either way, so the day it gains a
    /// `Recording` the earlier encounters are already filed against it.
    nonisolated static func reading(
        for item: MediaItem,
        resolveRecording: (String) -> Recording? = { _ in nil }
    ) -> Reading {
        var reading = Reading()
        let identity = stableID(for: item)

        switch item.kind {
        case .radioStation, .radioShow:
            // A live stream is the station. What was on at the time is the
            // provider's business, and is already logged as provenance by
            // whatever identified it.
            reading.subjects.append(.station(providerID: item.sourceID, stationID: item.id))
            reading.source = ListeningSource(providerID: item.sourceID, showTitle: item.title)

        case .episode:
            let show = MusicNode.broadcast(providerID: item.sourceID, showID: identity, title: item.title)
            reading.subjects.append(show)
            if BroadcastSource.route(providerID: item.sourceID) != nil {
                reading.subjects.append(.station(providerID: item.sourceID))
            }
            reading.source = ListeningSource(
                providerID: item.sourceID, showID: identity, showTitle: item.title
            )

        case .track:
            // Titles on these are written by whoever posted them — "Skee Mask
            // - Rev8617" — so the same credit recovery the crate does applies.
            let credit = TrackCredit.resolve(artist: item.subtitle, title: item.title)
            let key = RecordingKey.match(artist: credit.artist, title: credit.title)
            if !key.isEmpty {
                if let known = resolveRecording(key) {
                    reading.subjects.append(.recording(known))
                } else {
                    reading.subjects.append(MusicNode(
                        kind: .recording, key: key,
                        title: credit.title, subtitle: credit.artist
                    ))
                }
            }
            if let artist = credit.artist, !artist.isEmpty {
                reading.subjects.append(.artist(artist))
            }
            if item.sourceID != Track.sourceID,
               BroadcastSource.route(providerID: item.sourceID) != nil {
                reading.subjects.append(.station(providerID: item.sourceID))
                reading.source = ListeningSource(providerID: item.sourceID)
            }
        }
        return reading
    }

    /// The provider's own id for an item, with the crate's replay wrapper
    /// peeled off. See `NowPlayingLink`, which needs exactly the same thing to
    /// send the player bar somewhere.
    nonisolated static func stableID(for item: MediaItem) -> String {
        let wrapper = "crate.\(item.sourceID)."
        guard item.id.hasPrefix(wrapper) else { return item.id }
        return String(item.id.dropFirst(wrapper.count))
    }
}
