//
//  LibraryGroups.swift
//  Indigo
//
//  Albums and artists are projections over the track table, rebuilt on demand.
//

import Foundation

nonisolated struct AlbumGroup: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let year: Int
    let artworkKey: String?
    let trackCount: Int
    let duration: Double
}

nonisolated struct ArtistGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let albumCount: Int
    let trackCount: Int
    let artworkKey: String?
}

enum LibraryGrouping {
    /// Tracks of an album in disc/track order.
    static func sortedForAlbum(_ tracks: [Track]) -> [Track] {
        tracks.sorted {
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
            return $0.sortTitle < $1.sortTitle
        }
    }

    static func albums(from tracks: [Track]) -> [AlbumGroup] {
        var buckets: [String: [Track]] = [:]
        for track in tracks { buckets[track.albumKey, default: []].append(track) }

        return buckets.map { key, group in
            let ordered = sortedForAlbum(group)
            let first = ordered[0]
            return AlbumGroup(
                id: key,
                title: first.album.isEmpty ? "Unknown Album" : first.album,
                artist: variedArtist(in: ordered) ?? first.displayAlbumArtist,
                year: ordered.compactMap { $0.year > 0 ? $0.year : nil }.min() ?? 0,
                artworkKey: ordered.compactMap(\.artworkKey).first,
                trackCount: ordered.count,
                duration: ordered.reduce(0) { $0 + $1.duration }
            )
        }
        .sorted { lhs, rhs in
            let l = LibraryKey.normalize(lhs.artist), r = LibraryKey.normalize(rhs.artist)
            if l != r { return l < r }
            if lhs.year != rhs.year { return lhs.year < rhs.year }
            return LibraryKey.normalize(lhs.title) < LibraryKey.normalize(rhs.title)
        }
    }

    static func artists(from tracks: [Track]) -> [ArtistGroup] {
        var buckets: [String: [Track]] = [:]
        for track in tracks { buckets[track.artistKey, default: []].append(track) }

        return buckets.map { key, group in
            ArtistGroup(
                id: key,
                name: group[0].displayAlbumArtist.isEmpty ? "Unknown Artist" : group[0].displayAlbumArtist,
                albumCount: Set(group.map(\.albumKey)).count,
                trackCount: group.count,
                artworkKey: group.compactMap(\.artworkKey).first
            )
        }
        .sorted { LibraryKey.normalize($0.name) < LibraryKey.normalize($1.name) }
    }

    /// "Various Artists" when an album's tracks disagree on the performer.
    private static func variedArtist(in tracks: [Track]) -> String? {
        let names = Set(tracks.map { LibraryKey.normalize($0.artist) })
        guard names.count > 1 else { return nil }
        let albumArtists = Set(tracks.map { LibraryKey.normalize($0.albumArtist) }.filter { !$0.isEmpty })
        if albumArtists.count == 1, let first = tracks.first(where: { !$0.albumArtist.isEmpty }) {
            return first.albumArtist
        }
        return "Various Artists"
    }
}
