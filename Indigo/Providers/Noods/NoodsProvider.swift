//
//  NoodsProvider.swift
//  Indigo
//
//  Noods Radio, broadcasting from Bristol. One channel, streamed through
//  RadioCult's Icecast relay.
//

import Foundation
import Observation

@Observable
final class NoodsProvider: RadioProvider {
    nonisolated static let providerID = "noods"
    let displayName = "Noods Radio"

    let stations: [RadioStation] = [
        RadioStation(
            id: "noods.live",
            providerID: NoodsProvider.providerID,
            name: "Noods Radio",
            shortName: "Noods",
            strapline: "Bristol",
            streamURL: URL(string: "https://noods-radio.radiocult.fm/stream")!
        )
    ]

    var station: RadioStation { stations[0] }

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    /// Noods publishes no public schedule feed Indigo can read — the one that
    /// drives their own site sits behind a RadioCult key that belongs to them
    /// — so the live page is the stream and nothing it can't stand behind.
    func mediaItem() -> MediaItem {
        MediaItem(
            id: station.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: station.name,
            subtitle: "Live",
            detail: station.strapline,
            playbackURL: station.streamURL
        )
    }
}
