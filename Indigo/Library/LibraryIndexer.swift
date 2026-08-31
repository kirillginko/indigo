//
//  LibraryIndexer.swift
//  Indigo
//
//  Background scanning. Runs on its own ModelActor with its own context so the
//  main thread — and playback — stay responsive while a large folder indexes.
//

import Foundation
import SwiftData

nonisolated struct ScanProgress: Equatable, Sendable {
    var filesTotal: Int = 0
    var filesProcessed: Int = 0
    var currentName: String = ""

    var fraction: Double {
        filesTotal > 0 ? Double(filesProcessed) / Double(filesTotal) : 0
    }
}

nonisolated struct ScanSummary: Equatable, Sendable {
    var indexed: Int = 0
    var updated: Int = 0
    var unchanged: Int = 0
    var removed: Int = 0
    var unreadable: Int = 0

    var total: Int { indexed + updated + unchanged }
}

nonisolated enum LibraryError: LocalizedError {
    case folderMissing
    case folderUnreadable
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .folderMissing: "The music folder could not be found. Choose it again."
        case .folderUnreadable: "The music folder could not be read."
        case .accessDenied: "Indigo no longer has permission to read that folder. Choose it again."
        }
    }
}

@ModelActor
actor LibraryIndexer {
    private static let coverFilenames = ["cover", "folder", "front", "album", "artwork"]
    private static let coverExtensions = ["jpg", "jpeg", "png"]

    func scan(
        root: URL,
        generation: Int,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanSummary {
        try await scan(roots: [root], generation: generation, onProgress: onProgress)
    }

    func scan(
        roots: [URL],
        generation: Int,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanSummary {
        let fileManager = FileManager.default
        for root in roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw LibraryError.folderMissing
            }
        }

        let files = try discoverFiles(under: roots)
        var progress = ScanProgress(filesTotal: files.count)
        onProgress(progress)

        var existing: [String: Track] = [:]
        for track in try modelContext.fetch(FetchDescriptor<Track>()) {
            existing[track.path] = track
        }

        var summary = ScanSummary()
        for (offset, file) in files.enumerated() {
            try Task.checkCancellation()
            let url = file.url
            let root = file.root
            let rootPath = root.standardizedFileURL.path

            let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = attributes?.contentModificationDate ?? .distantPast
            let size = attributes?.fileSize ?? 0

            if let track = existing[url.path], track.fileModified == modified, track.fileSize == size {
                track.scanGeneration = generation
                // Backfill for rows written before the field existed.
                if track.searchIndex.isEmpty {
                    track.searchIndex = LibraryKey.searchIndex(
                        title: track.title, artist: track.artist, album: track.album
                    )
                }
                summary.unchanged += 1
            } else {
                let meta = await MetadataReader.read(url: url, root: root)
                if meta.readFailed { summary.unreadable += 1 }
                let artworkKey = resolveArtwork(for: meta, at: url)

                if let track = existing[url.path] {
                    apply(meta, artworkKey: artworkKey, to: track,
                          modified: modified, size: size, generation: generation)
                    summary.updated += 1
                } else {
                    let track = Track(
                        path: url.path,
                        relativePath: relativePath(of: url, rootPath: rootPath),
                        title: meta.title,
                        artist: meta.artist,
                        albumArtist: meta.albumArtist,
                        album: meta.album,
                        genre: meta.genre,
                        trackNumber: meta.trackNumber,
                        discNumber: meta.discNumber,
                        year: meta.year,
                        duration: meta.duration,
                        fileModified: modified,
                        fileSize: size,
                        isrc: meta.isrc,
                        artworkKey: artworkKey,
                        scanGeneration: generation
                    )
                    modelContext.insert(track)
                    existing[url.path] = track
                    summary.indexed += 1
                }
            }

            if offset % 48 == 0 {
                try? modelContext.save()
                progress.filesProcessed = offset + 1
                progress.currentName = url.lastPathComponent
                onProgress(progress)
            }
        }

        try? modelContext.save()
        summary.removed = try prune(generation: generation)
        backfillAlbumArtwork()
        try? modelContext.save()

        progress.filesProcessed = files.count
        progress.currentName = ""
        onProgress(progress)
        return summary
    }

    // MARK: - Discovery

    private struct DiscoveredFile {
        let url: URL
        let root: URL
    }

    private func discoverFiles(under roots: [URL]) throws -> [DiscoveredFile] {
        let fileManager = FileManager.default
        var files: [String: DiscoveredFile] = [:]
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw LibraryError.folderUnreadable
            }

            for case let url as URL in enumerator {
                if Task.isCancelled { break }
                guard MetadataReader.isSupported(url) else { continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                files[url.standardizedFileURL.path, default: DiscoveredFile(url: url, root: root)] =
                    DiscoveredFile(url: url, root: root)
            }
        }
        return files.values.sorted { $0.url.path < $1.url.path }
    }

    private func relativePath(of url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Writing

    private func apply(
        _ meta: AudioMetadata,
        artworkKey: String?,
        to track: Track,
        modified: Date,
        size: Int,
        generation: Int
    ) {
        track.title = meta.title
        track.artist = meta.artist
        track.albumArtist = meta.albumArtist
        track.album = meta.album
        track.genre = meta.genre
        track.trackNumber = meta.trackNumber
        track.discNumber = meta.discNumber
        track.year = meta.year
        track.duration = meta.duration
        track.fileModified = modified
        track.fileSize = size
        track.isrc = meta.isrc
        track.artworkKey = artworkKey
        // Keyed on the album artist the files actually declare, and on the
        // album alone when they declare none.
        //
        // Falling back to the *track* artist here invents a claim the files
        // never made — "this album belongs to Artist A" — and for a
        // compilation that is exactly wrong: every track gets a different key
        // and one record is shredded into one album per performer. Untagged
        // compilations are common, and this was silently destroying all of
        // them.
        track.albumKey = LibraryKey.album(album: meta.album, albumArtist: meta.albumArtist)
        track.artistKey = LibraryKey.normalize(meta.albumArtist.isEmpty ? meta.artist : meta.albumArtist)
        track.sortTitle = LibraryKey.normalize(meta.title)
        track.searchIndex = LibraryKey.searchIndex(
            title: meta.title, artist: meta.artist, album: meta.album
        )
        track.scanGeneration = generation
    }

    /// Embedded art first, then a cover image sitting next to the file.
    private func resolveArtwork(for meta: AudioMetadata, at url: URL) -> String? {
        let store = ArtworkStore.shared
        let key = store.key(album: meta.album, albumArtist: meta.albumArtist, fallbackPath: url.path)
        if store.exists(key) { return key }

        if let data = meta.artwork, store.store(data, key: key) { return key }

        let directory = url.deletingLastPathComponent()
        for name in Self.coverFilenames {
            for ext in Self.coverExtensions {
                let candidate = directory.appendingPathComponent("\(name).\(ext)")
                if let data = try? Data(contentsOf: candidate), store.store(data, key: key) {
                    return key
                }
            }
        }
        return nil
    }

    /// A cover found on one track applies to the whole album.
    private func backfillAlbumArtwork() {
        guard let tracks = try? modelContext.fetch(FetchDescriptor<Track>()) else { return }
        let store = ArtworkStore.shared
        var known: [String: String] = [:]
        for track in tracks {
            if let key = track.artworkKey { known[track.albumKey] = key }
        }
        for track in tracks where track.artworkKey == nil {
            if let key = known[track.albumKey], store.exists(key) {
                track.artworkKey = key
            }
        }
    }

    private func prune(generation: Int) throws -> Int {
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.scanGeneration != generation }
        )
        let stale = try modelContext.fetch(descriptor)
        for track in stale { modelContext.delete(track) }
        return stale.count
    }
}
