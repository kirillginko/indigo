//
//  MediaItem.swift
//  Indigo
//
//  Provider-independent description of anything that can be played.
//  Nothing downstream of the player should know whether an item came from
//  the local library, NTS, or a future provider.
//

import Foundation

nonisolated enum MediaKind: String, Codable, Hashable, Sendable {
    case track
    case radioStation
    case radioShow
    /// An archived broadcast, played through its host's embed widget.
    case episode
}

nonisolated struct MediaItem: Identifiable, Hashable, Sendable {
    let id: String
    /// Identifier of the provider that vended this item ("local", "nts", ...).
    let sourceID: String
    let kind: MediaKind
    let title: String
    /// Artist for a track; show host or station strapline for radio.
    let subtitle: String?
    /// Album for a track; station name for radio.
    let detail: String?
    /// Provider or file tags carried through playback into the crate.
    let genres: [String]
    /// Key into `ArtworkStore` for artwork extracted from a local file.
    let artworkKey: String?
    /// Remote artwork, used by network providers.
    let remoteArtworkURL: URL?
    let playbackURL: URL
    /// Nil for live streams, and unknown until an embed reports it.
    let duration: TimeInterval?
    /// Set when playback goes through a hosted widget rather than AVPlayer.
    let embedProvider: EmbedProvider?

    var isLive: Bool { kind == .radioStation || kind == .radioShow }
    var isEmbedded: Bool { embedProvider != nil }

    init(
        id: String,
        sourceID: String,
        kind: MediaKind,
        title: String,
        subtitle: String? = nil,
        detail: String? = nil,
        genres: [String] = [],
        artworkKey: String? = nil,
        remoteArtworkURL: URL? = nil,
        playbackURL: URL,
        duration: TimeInterval? = nil,
        embedProvider: EmbedProvider? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.genres = genres
        self.artworkKey = artworkKey
        self.remoteArtworkURL = remoteArtworkURL
        self.playbackURL = playbackURL
        self.duration = duration
        self.embedProvider = embedProvider
    }
}
