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

    /// The station's own mark, for the player when there is no picture of
    /// what is on — which for Noods is whenever the stream was not started
    /// from its page. Their touch icon: 180 pixels, and the only square mark
    /// the site serves.
    static let logoURL = URL(string: "https://noodsradio.com/apple-touch-icon.png")

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    /// Noods publishes no public schedule feed Indigo can read — the one that
    /// drives their own site sits behind a RadioCult key that belongs to them
    /// — so the live page is the stream and nothing it can't stand behind.
    ///
    /// `artwork` is whatever the station page is showing beside its play
    /// button, so the player carries the picture the listener pressed play
    /// next to rather than an empty square.
    func mediaItem(artwork: URL? = nil) -> MediaItem {
        MediaItem(
            id: station.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: station.name,
            subtitle: "Live",
            detail: station.strapline,
            remoteArtworkURL: artwork,
            playbackURL: station.streamURL
        )
    }
}
