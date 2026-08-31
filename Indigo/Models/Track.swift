//
//  Track.swift
//  Indigo
//
//  The persisted unit of the local library. Albums and artists are derived
//  from tracks rather than stored separately — one source of truth, no
//  relationship graph to keep consistent across rescans.
//

import Foundation
import SwiftData

@Model
nonisolated final class Track {
    /// Absolute file path. Unique identity for the library index.
    @Attribute(.unique) var path: String
    /// Path relative to the chosen library root, so the root can move.
    var relativePath: String

    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var genre: String

    /// Normalised grouping keys (case- and diacritic-insensitive).
    var albumKey: String
    var artistKey: String
    var sortTitle: String
    /// Normalised "title artist album", built once at index time so searching
    /// is a single `contains` per row instead of three foldings per keystroke.
    var searchIndex: String = ""

    var trackNumber: Int
    var discNumber: Int
    var year: Int
    var duration: Double

    var fileModified: Date
    var fileSize: Int
    var addedAt: Date

    /// ISRC read from the file's tags, when it had one.
    var isrc: String?
    /// Key into `ArtworkStore`; nil when the file had no embedded artwork.
    var artworkKey: String?
    /// Scan generation that last saw this file, used to prune deleted files.
    var scanGeneration: Int

    init(
        path: String,
        relativePath: String,
        title: String,
        artist: String,
        albumArtist: String,
        album: String,
        genre: String,
        trackNumber: Int,
        discNumber: Int,
        year: Int,
        duration: Double,
        fileModified: Date,
        fileSize: Int,
        isrc: String? = nil,
        artworkKey: String?,
        scanGeneration: Int
    ) {
        self.path = path
        self.relativePath = relativePath
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.genre = genre
        // Keyed on the album artist the files actually declare, and on the
        // album alone when they declare none.
        //
        // Falling back to the *track* artist here invents a claim the files
        // never made — "this album belongs to Artist A" — and for a
        // compilation that is exactly wrong: every track gets a different key
        // and one record is shredded into one album per performer. Untagged
        // compilations are common, and this was silently destroying all of
        // them.
        self.albumKey = LibraryKey.album(album: album, albumArtist: albumArtist)
        self.artistKey = LibraryKey.normalize(albumArtist.isEmpty ? artist : albumArtist)
        self.sortTitle = LibraryKey.normalize(title)
        self.searchIndex = LibraryKey.searchIndex(title: title, artist: artist, album: album)
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.duration = duration
        self.fileModified = fileModified
        self.fileSize = fileSize
        self.isrc = isrc
        self.addedAt = Date()
        self.artworkKey = artworkKey
        self.scanGeneration = scanGeneration
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// Artist shown in album and artist listings.
    var displayAlbumArtist: String { albumArtist.isEmpty ? artist : albumArtist }
}

// MARK: - Grouping keys

nonisolated enum LibraryKey {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func album(album: String, albumArtist: String) -> String {
        "\(normalize(albumArtist))\u{1F}\(normalize(album))"
    }

    static func searchIndex(title: String, artist: String, album: String) -> String {
        normalize("\(title) \(artist) \(album)")
    }
}
