//
//  MetadataReader.swift
//  Indigo
//
//  Reads tags via AVFoundation and degrades gracefully: containers that expose
//  no metadata to AVFoundation (FLAC with Vorbis comments, for example) fall
//  back to filename and folder structure so the library is still usable.
//

import AVFoundation
import Foundation

nonisolated struct AudioMetadata: Sendable {
    var title: String = ""
    var artist: String = ""
    var albumArtist: String = ""
    var album: String = ""
    var genre: String = ""
    var trackNumber: Int = 0
    var discNumber: Int = 0
    var year: Int = 0
    var duration: Double = 0
    var artwork: Data?
    /// International Standard Recording Code, when the file carries one. The
    /// strongest rung of the local-match ladder: two files with the same ISRC
    /// are the same recording, whatever their tags say.
    var isrc: String?
    /// True when AVFoundation could not open the file at all.
    var readFailed: Bool = false
}

nonisolated enum MetadataReader {
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "alac", "flac", "wav", "wave", "aif", "aiff", "aifc", "caf", "mp4"
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func read(url: URL, root: URL) async -> AudioMetadata {
        var meta = AudioMetadata()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        if let duration = try? await asset.load(.duration), duration.isNumeric {
            meta.duration = max(0, CMTimeGetSeconds(duration))
        } else {
            meta.readFailed = true
        }

        var items: [AVMetadataItem] = []
        if let all = try? await asset.load(.metadata) { items.append(contentsOf: all) }
        if let common = try? await asset.load(.commonMetadata) { items.append(contentsOf: common) }

        if !items.isEmpty {
            meta.title = await string(items, [.commonIdentifierTitle, .id3MetadataTitleDescription,
                                              .iTunesMetadataSongName, .quickTimeMetadataTitle]) ?? ""
            meta.artist = await string(items, [.commonIdentifierArtist, .id3MetadataLeadPerformer,
                                               .iTunesMetadataArtist, .quickTimeMetadataArtist]) ?? ""
            meta.albumArtist = await string(items, [.id3MetadataBand, .iTunesMetadataAlbumArtist]) ?? ""
            meta.isrc = await string(items, [.id3MetadataInternationalStandardRecordingCode])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            meta.album = await string(items, [.commonIdentifierAlbumName, .id3MetadataAlbumTitle,
                                              .iTunesMetadataAlbum, .quickTimeMetadataAlbum]) ?? ""
            meta.genre = await string(items, [.id3MetadataContentType, .iTunesMetadataUserGenre,
                                              .iTunesMetadataPredefinedGenre, .quickTimeMetadataGenre,
                                              .quickTimeUserDataGenre]) ?? ""
            meta.trackNumber = await number(items, [.id3MetadataTrackNumber, .iTunesMetadataTrackNumber]) ?? 0
            meta.discNumber = await number(items, [.id3MetadataPartOfASet, .iTunesMetadataDiscNumber]) ?? 0
            meta.year = await year(items)
            meta.artwork = await data(items, [.commonIdentifierArtwork, .id3MetadataAttachedPicture,
                                              .iTunesMetadataCoverArt])
        }

        applyFallbacks(to: &meta, url: url, root: root)
        return meta
    }

    // MARK: - Metadata accessors

    private static func string(_ items: [AVMetadataItem], _ identifiers: [AVMetadataIdentifier]) async -> String? {
        for identifier in identifiers {
            for item in items where item.identifier == identifier {
                if let value = try? await item.load(.stringValue) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return nil
    }

    private static func data(_ items: [AVMetadataItem], _ identifiers: [AVMetadataIdentifier]) async -> Data? {
        for identifier in identifiers {
            for item in items where item.identifier == identifier {
                if let value = try? await item.load(.dataValue), !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func number(_ items: [AVMetadataItem], _ identifiers: [AVMetadataIdentifier]) async -> Int? {
        for identifier in identifiers {
            for item in items where item.identifier == identifier {
                if let value = try? await item.load(.numberValue), value.intValue > 0 {
                    return value.intValue
                }
                if let value = try? await item.load(.stringValue), let parsed = leadingInt(value) {
                    return parsed
                }
                // iTunes 'trkn'/'disk' atoms are packed binary: 0,0,index,count...
                if let value = try? await item.load(.dataValue), value.count >= 4 {
                    let number = Int(value[value.startIndex + 2]) << 8 | Int(value[value.startIndex + 3])
                    if number > 0 { return number }
                }
            }
        }
        return nil
    }

    private static func year(_ items: [AVMetadataItem]) async -> Int {
        let candidates: [AVMetadataIdentifier] = [
            .id3MetadataYear, .id3MetadataRecordingTime, .id3MetadataOriginalReleaseTime,
            .iTunesMetadataReleaseDate, .commonIdentifierCreationDate, .quickTimeMetadataYear
        ]
        guard let raw = await string(items, candidates) else { return 0 }
        let digits = raw.prefix(while: { $0.isNumber })
        if digits.count == 4, let value = Int(digits) { return value }
        if let match = raw.range(of: "[0-9]{4}", options: .regularExpression) {
            return Int(raw[match]) ?? 0
        }
        return 0
    }

    private static func leadingInt(_ value: String) -> Int? {
        let digits = value.trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let parsed = Int(digits), parsed > 0 else { return nil }
        return parsed
    }

    // MARK: - Fallbacks

    /// Fills any field the container did not provide, using the file's name and
    /// its position in the folder hierarchy (…/Artist/Album/01 Title.flac).
    private static func applyFallbacks(to meta: inout AudioMetadata, url: URL, root: URL) {
        let stem = url.deletingPathExtension().lastPathComponent
        let parsed = parseFilename(stem)

        if meta.title.isEmpty { meta.title = parsed.title }
        if meta.trackNumber == 0 { meta.trackNumber = parsed.trackNumber }
        if meta.artist.isEmpty, let artist = parsed.artist { meta.artist = artist }

        let rootPath = root.standardizedFileURL.path
        let parent = url.deletingLastPathComponent()
        let grandparent = parent.deletingLastPathComponent()

        if meta.album.isEmpty, parent.standardizedFileURL.path != rootPath {
            meta.album = parent.lastPathComponent
        }
        if meta.artist.isEmpty, grandparent.standardizedFileURL.path.hasPrefix(rootPath),
           grandparent.standardizedFileURL.path != rootPath {
            meta.artist = grandparent.lastPathComponent
        }
        if meta.artist.isEmpty { meta.artist = "Unknown Artist" }
        if meta.album.isEmpty { meta.album = "Unknown Album" }
        if meta.discNumber == 0 { meta.discNumber = 1 }
    }

    /// Recognises "01 - Title", "01. Title", "01 Title" and "Artist - Title".
    private static func parseFilename(_ stem: String) -> (trackNumber: Int, artist: String?, title: String) {
        var working = stem.trimmingCharacters(in: .whitespaces)
        var trackNumber = 0

        if let match = working.range(of: "^([0-9]{1,3})\\s*[-._)]?\\s+", options: .regularExpression) {
            let digits = working[match].prefix(while: { $0.isNumber })
            trackNumber = Int(digits) ?? 0
            working.removeSubrange(match)
        }

        let separators = [" - ", " – ", " — "]
        for separator in separators {
            if let range = working.range(of: separator) {
                let artist = String(working[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let title = String(working[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty && !title.isEmpty {
                    return (trackNumber, artist, title)
                }
            }
        }
        let title = working.trimmingCharacters(in: .whitespaces)
        return (trackNumber, nil, title.isEmpty ? stem : title)
    }
}
