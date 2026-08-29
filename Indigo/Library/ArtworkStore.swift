//
//  ArtworkStore.swift
//  Indigo
//
//  Embedded artwork is extracted once per album during scanning, downscaled,
//  and written to a disk cache in Application Support. Tracks only hold a key,
//  so the SwiftData store stays small and rescans stay cheap.
//

import Foundation
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

nonisolated final class ArtworkStore: @unchecked Sendable {
    static let shared = ArtworkStore()

    private let directory: URL
    private let cache = NSCache<NSString, PlatformImage>()
    private let fileManager = FileManager.default

    private init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Indigo/Artwork", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        cache.countLimit = 240
    }

    // MARK: Keys

    /// Stable key for an album's cover. Falls back to the file path for
    /// tracks that belong to no album.
    func key(album: String, albumArtist: String, fallbackPath: String) -> String {
        let identity = album.isEmpty
            ? fallbackPath
            : LibraryKey.album(album: album, albumArtist: albumArtist)
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("jpg")
    }

    func exists(_ key: String) -> Bool {
        fileManager.fileExists(atPath: url(for: key).path)
    }

    // MARK: Writing

    /// Downscales and stores raw embedded artwork. Returns false if the data
    /// could not be decoded — a corrupt cover must never fail a scan.
    @discardableResult
    func store(_ data: Data, key: String, maxPixel: CGFloat = 640) -> Bool {
        let destination = url(for: key)
        guard !fileManager.fileExists(atPath: destination.path) else { return true }
        guard let jpeg = downscaledJPEG(from: data, maxPixel: maxPixel) else { return false }
        do {
            try jpeg.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func downscaledJPEG(from data: Data, maxPixel: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: Reading

    func image(for key: String) -> PlatformImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let data = try? Data(contentsOf: url(for: key)),
              let image = PlatformImage(data: data) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// Remote covers need a cache above SwiftUI's view lifetime. Lazy grids tear
/// tiles down while scrolling and `AsyncImage` can then replace a cover that
/// already rendered with its failure placeholder during a transient retry.
nonisolated final class RemoteArtworkStore: @unchecked Sendable {
    static let shared = RemoteArtworkStore()

    private let cache = NSCache<NSURL, PlatformImage>()
    private let directory: URL
    private let fileManager = FileManager.default

    private init() {
        cache.countLimit = 320
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Indigo/RemoteArtwork", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for url: URL) async -> PlatformImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let destination = diskURL(for: url)
        if let data = try? Data(contentsOf: destination), let image = PlatformImage(data: data) {
            cache.setObject(image, forKey: url as NSURL)
            return image
        }
        do {
            let (data, response) = try await NetworkEnvironment.session.data(from: url)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) { return nil }
            guard let image = PlatformImage(data: data) else { return nil }
            cache.setObject(image, forKey: url as NSURL)
            try? data.write(to: destination, options: .atomic)
            return image
        } catch {
            return nil
        }
    }

    func prefetch(_ urls: [URL]) async {
        for batchStart in stride(from: 0, to: urls.count, by: 4) {
            let batch = Array(urls[batchStart..<min(batchStart + 4, urls.count)])
            await withTaskGroup(of: Void.self) { group in
                for url in batch {
                    group.addTask { _ = await self.image(for: url) }
                }
            }
        }
    }

    private func diskURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("img")
    }
}

// MARK: - SwiftUI

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// Square artwork tile. Loads local cache entries off the main thread and
/// falls back to a remote URL for network providers.
struct ArtworkView: View {
    var localKey: String?
    var remoteURL: URL?
    var previewRemoteURL: URL?
    var side: CGFloat?
    var glyphScale: CGFloat = 0.34
    /// The station's own logo, shown when there is no picture of what is
    /// actually on. Kept separate from `remoteURL` because a logo is not cover
    /// art: it is drawn inset on the ground rather than cropped to fill, which
    /// both reads as deliberate and keeps a small mark from being stretched.
    var markURL: URL?
    /// Last resort, when there is no image at all — the station's name set in
    /// the app's own type, which says more than a grey square and claims
    /// nothing it shouldn't.
    var mark: String?

    @State private var image: PlatformImage?
    @State private var loadedKey: String?
    @State private var remoteImage: PlatformImage?
    @State private var loadedRemoteURL: URL?
    @State private var previewImage: PlatformImage?
    @State private var markImage: PlatformImage?
    @State private var loadedMarkURL: URL?

    var body: some View {
        Rectangle()
            .fill(Palette.placeholder)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else if let displayedRemoteImage = remoteImage ?? previewImage {
                    Image(platformImage: displayedRemoteImage)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else if let markImage {
                    GeometryReader { geo in
                        Image(platformImage: markImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(geo.size.width * 0.16)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                } else {
                    placeholderGlyph
                }
            }
            .clipped()
            .frame(width: side, height: side)
            .task(id: localKey) { await load() }
            .task(id: remoteURL) { await loadRemote() }
            .task(id: previewRemoteURL) { await loadPreview() }
            .task(id: markURL) { await loadMark() }
    }

    @ViewBuilder
    private var placeholderGlyph: some View {
        GeometryReader { geo in
            if let mark, !mark.isEmpty {
                Text(mark)
                    .font(Typeface.banner(max(12, geo.size.width * 0.115)))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.inkMuted)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.4)
                    .padding(geo.size.width * 0.1)
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                Image(systemName: "square.stack")
                    .font(.system(size: max(9, geo.size.width * glyphScale), weight: .ultraLight))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func load() async {
        guard let localKey else {
            image = nil
            loadedKey = nil
            return
        }
        guard loadedKey != localKey else { return }
        let loaded = await Task.detached(priority: .utility) {
            ArtworkStore.shared.image(for: localKey)
        }.value
        guard !Task.isCancelled else { return }
        image = loaded
        loadedKey = localKey
    }

    private func loadRemote() async {
        guard let remoteURL else {
            remoteImage = nil
            loadedRemoteURL = nil
            return
        }
        guard loadedRemoteURL != remoteURL else { return }
        let loaded = await RemoteArtworkStore.shared.image(for: remoteURL)
        guard !Task.isCancelled, self.remoteURL == remoteURL else { return }
        // Keep the last successful cover if a refresh briefly fails. This is
        // especially important for The Lot's large residency grid.
        if let loaded {
            remoteImage = loaded
            loadedRemoteURL = remoteURL
        }
    }

    private func loadMark() async {
        guard let markURL else {
            markImage = nil
            loadedMarkURL = nil
            return
        }
        guard loadedMarkURL != markURL else { return }
        let loaded = await RemoteArtworkStore.shared.image(for: markURL)
        guard !Task.isCancelled, self.markURL == markURL else { return }
        if let loaded {
            markImage = loaded
            loadedMarkURL = markURL
        }
    }

    private func loadPreview() async {
        guard let previewRemoteURL else {
            previewImage = nil
            return
        }
        let loaded = await RemoteArtworkStore.shared.image(for: previewRemoteURL)
        guard !Task.isCancelled, self.previewRemoteURL == previewRemoteURL else { return }
        if let loaded { previewImage = loaded }
    }
}
