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
    var side: CGFloat?
    var glyphScale: CGFloat = 0.34

    @State private var image: PlatformImage?
    @State private var loadedKey: String?

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
                } else if let remoteURL {
                    AsyncImage(url: remoteURL, transaction: Transaction(animation: .none)) { phase in
                        switch phase {
                        case .success(let remote):
                            remote.resizable().aspectRatio(contentMode: .fill)
                        default:
                            placeholderGlyph
                        }
                    }
                } else {
                    placeholderGlyph
                }
            }
            .clipped()
            .frame(width: side, height: side)
            .task(id: localKey) { await load() }
    }

    private var placeholderGlyph: some View {
        GeometryReader { geo in
            Image(systemName: "square.stack")
                .font(.system(size: max(9, geo.size.width * glyphScale), weight: .ultraLight))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: geo.size.width, height: geo.size.height)
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
}
