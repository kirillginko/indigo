//
//  Track+MediaItem.swift
//  Indigo
//

import Foundation

extension Track {
    static let sourceID = "local"

    func mediaItem() -> MediaItem {
        MediaItem(
            id: path,
            sourceID: Track.sourceID,
            kind: .track,
            title: title,
            subtitle: artist,
            detail: album,
            genres: genre.isEmpty ? [] : [genre],
            artworkKey: artworkKey,
            playbackURL: url,
            duration: duration > 0 ? duration : nil
        )
    }
}

extension Array where Element == Track {
    func mediaItems() -> [MediaItem] { map { $0.mediaItem() } }
}
