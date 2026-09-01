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
    private var missing: [URL: Date] = [:]
    private let missingLock = NSLock()

    private init() {
        cache.countLimit = 320
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Indigo/RemoteArtwork", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The picture, only if it is already in memory. Synchronous on purpose:
    /// a view being rebuilt can then draw it in its first frame instead of
    /// showing a grey square and awaiting a value it already has.
    func cachedImage(for url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> PlatformImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let destination = diskURL(for: url)
        if let data = try? Data(contentsOf: destination), let image = PlatformImage(data: data) {
            cache.setObject(image, forKey: url as NSURL)
            return image
        }
        // A picture that is not there stays not there. Lazy grids rebuild a
        // tile every time it scrolls back, so without this a single missing
        // sleeve is refetched on every pass — and a page of them is a page
        // spending its bandwidth on nothing.
        if isKnownMissing(url) { return nil }

        do {
            let (data, response) = try await NetworkEnvironment.session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                noteMissing(url)
                return nil
            }
            guard let image = PlatformImage(data: data) else {
                noteMissing(url)
                return nil
            }
            cache.setObject(image, forKey: url as NSURL)
            try? data.write(to: destination, options: .atomic)
            return image
        } catch {
            // A dropped connection is not an answer about the picture, so it
            // is not remembered as one.
            return nil
        }
    }

    /// Addresses that answered with nothing, and when. Kept for an hour: long
    /// enough to stop a grid retrying on every scroll, short enough that a
    /// service having a bad minute does not cost the rest of the session.
    private func isKnownMissing(_ url: URL) -> Bool {
        missingLock.lock()
        defer { missingLock.unlock() }
        guard let noted = missing[url] else { return false }
        guard Date().timeIntervalSince(noted) < 3600 else {
            missing.removeValue(forKey: url)
            return false
        }
        return true
    }

    private func noteMissing(_ url: URL) {
        missingLock.lock()
        defer { missingLock.unlock() }
        if missing.count > 500 { missing.removeAll() }
        missing[url] = Date()
    }

    func prefetch(_ urls: [URL]) async {
        // Six at a time. These are thumbnails — tens of kilobytes each — and
        // the point is to have them ready before a tile asks.
        for batchStart in stride(from: 0, to: urls.count, by: 6) {
            let batch = Array(urls[batchStart..<min(batchStart + 6, urls.count)])
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
    /// What to draw when there is no picture. A record with no sleeve is not
    /// the same absence as a show with no photograph.
    var placeholder: ArtworkPlaceholder = .glyph
    /// The station's own logo, shown when there is no picture of what is
    /// actually on. Kept separate from `remoteURL` because a logo is not cover
    /// art: it is drawn inset on the ground rather than cropped to fill, which
    /// both reads as deliberate and keeps a small mark from being stretched.
    var markURL: URL?
    /// Last resort, when there is no image at all — the station's name set in
    /// the app's own type, which says more than a grey square and claims
    /// nothing it shouldn't.
    var mark: String?
    /// Whether to fill the square while there is nothing to show.
    ///
    /// A grey block reads as a picture that failed rather than one that has
    /// not arrived — "it looks like the page stopped loading". Where the
    /// surrounding page already says what is going on, the tile is better as
    /// an empty frame.
    var showsGround = true

    /// What the store already holds, read straight through on the first
    /// frame.
    ///
    /// `image(for:)` is `async`, so even a memory-cache hit costs a
    /// suspension — and navigating back rebuilds every tile on the page, so
    /// every one of them drew grey and then filled in from a cache that had
    /// the picture the whole time. `??` is lazy, so this costs a lookup only
    /// for tiles with nothing to show yet.
    private var cachedFull: PlatformImage? {
        guard let remoteURL else { return nil }
        return RemoteArtworkStore.shared.cachedImage(for: remoteURL)
    }

    private var cachedPreview: PlatformImage? {
        guard let preview = distinctPreviewURL else { return nil }
        return RemoteArtworkStore.shared.cachedImage(for: preview)
    }

    /// The small cut, only when it is actually a different picture.
    ///
    /// Callers now ask for a cover and a preview that each fall back to the
    /// other, so a record with only one address supplies the same URL twice.
    /// Fetched as two things that is a wasted request and an extra suspension
    /// in front of the picture, for no second picture.
    private var distinctPreviewURL: URL? {
        guard let previewRemoteURL, previewRemoteURL != remoteURL else { return nil }
        return previewRemoteURL
    }

    @State private var image: PlatformImage?
    @State private var loadedKey: String?
    @State private var remoteImage: PlatformImage?
    @State private var loadedRemoteURL: URL?
    @State private var previewImage: PlatformImage?
    @State private var markImage: PlatformImage?
    @State private var loadedMarkURL: URL?

    var body: some View {
        Rectangle()
            .fill(showsGround ? Palette.placeholder : Color.clear)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else if let full = remoteImage ?? cachedFull {
                    Image(platformImage: full)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else if let preview = previewImage ?? cachedPreview {
                    // The record itself, at the size we have it so far.
                    //
                    // Drawn without smoothing on purpose. A hundred-and-fifty
                    // pixel sleeve stretched over a tile and interpolated is a
                    // blurry smear, and a smear reads as a fault. Left with
                    // its own pixels it reads as the picture arriving —
                    // because it is the picture, just fewer of it — and the
                    // full one replaces it with nothing unrelated in between.
                    Image(platformImage: preview)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fill)
                } else if let markImage {
                    GeometryReader { geo in
                        if Self.canCarry(markImage, at: geo.size.width) {
                            Image(platformImage: markImage)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                // Enough inset that a square logo doesn't
                                // touch the rule around the tile, and no
                                // more. At 0.16 a mark read as a stamp lost
                                // in a box.
                                .padding(geo.size.width * 0.07)
                                .frame(width: geo.size.width, height: geo.size.height)
                        } else {
                            // Some stations publish nothing bigger than a
                            // 32-pixel favicon. Blown up to fill a tile that
                            // is a blurry smear, and shrunk to stay sharp it
                            // is a speck — so the name is used instead, which
                            // is at least legible at any size.
                            placeholderGlyph
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                } else {
                    placeholderGlyph
                }
            }
            .clipped()
            .frame(width: side, height: side)
            // One task, not four.
            //
            // A dig page builds dozens of these, and a lazy grid builds them
            // while you are scrolling. Four `.task` modifiers apiece is four
            // tasks created and cancelled per tile per pass, on the main
            // actor, which is felt as the scroll catching.
            .task(id: Sources(localKey, remoteURL, previewRemoteURL, markURL)) {
                await loadAll()
            }
    }

    @ViewBuilder
    private var placeholderGlyph: some View {
        // The two common cases size themselves, so the overwhelming majority
        // of tiles cost no layout pass at all. Only the text mark — a station
        // with no logo, which is rare — still needs to measure.
        if remoteURL != nil || previewRemoteURL != nil {
            // A picture is on its way, so nothing is drawn over the ground.
            //
            // The glyph and the white-label mark both say "this has no
            // artwork", and saying it while the artwork is in flight puts a
            // wrong answer between the empty tile and the right one.
            Color.clear
        } else if placeholder == .whiteLabel, mark?.isEmpty ?? true {
            WhiteLabelMark()
        } else if mark?.isEmpty ?? true {
            Image(systemName: "square.stack")
                .resizable()
                .scaledToFit()
                .fontWeight(.ultraLight)
                .foregroundStyle(Palette.inkFaint)
                .scaleEffect(glyphScale)
        } else {
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
                }
            }
        }
    }

    /// Whether a mark has the pixels to fill a tile this size. Three times its
    /// own width is about as far as a logo stretches before it stops looking
    /// like artwork and starts looking like a mistake.
    static func canCarry(_ image: PlatformImage, at width: CGFloat) -> Bool {
        guard width > 0 else { return true }
        let natural = max(image.size.width, image.size.height)
        guard natural > 0 else { return false }
        return natural * 3 >= width
    }

    /// What this tile was asked to show. Its identity is what decides whether
    /// the one task needs to run again.
    private struct Sources: Hashable {
        let local: String?
        let remote: URL?
        let preview: URL?
        let mark: URL?

        init(_ local: String?, _ remote: URL?, _ preview: URL?, _ mark: URL?) {
            self.local = local
            self.remote = remote
            self.preview = preview
            self.mark = mark
        }
    }

    private func loadAll() async {
        // The local cache first, which is a disk read rather than a request.
        await load()
        // Then the remote ones together, rather than one behind the other.
        //
        // These were sequential, on the reasoning that the small one should
        // appear first. It still does — it is a tenth of the size — but
        // awaiting it before the cover was even *asked for* meant a preview
        // that was slow, or that got cancelled when the profile was re-read,
        // stopped the cover from ever being requested at all. That is the
        // tile that stays blank until you navigate away and come back: the
        // picture was never fetched, and returning re-reads a cache that
        // something else had filled in the meantime.
        async let preview: Void = loadPreview()
        async let full: Void = loadRemote()
        async let mark: Void = loadMark()
        _ = await (preview, full, mark)
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
        guard let previewRemoteURL = distinctPreviewURL else {
            previewImage = nil
            return
        }
        let loaded = await RemoteArtworkStore.shared.image(for: previewRemoteURL)
        guard !Task.isCancelled, self.previewRemoteURL == previewRemoteURL else { return }
        if let loaded { previewImage = loaded }
    }
}


/// What to draw in place of a picture.
nonisolated enum ArtworkPlaceholder: Hashable, Sendable {
    /// The neutral stack-of-records glyph.
    case glyph
    /// A blank record label. For releases, where the absence of a sleeve is
    /// itself meaningful — a white label, a test press, something nobody
    /// photographed — rather than merely a gap in the data.
    case whiteLabel
}

/// A blank record label: paper, rings, and a spindle hole. No printing,
/// because there wasn't any.
///
/// Drawn rather than shipped as an image so it scales to any tile and costs
/// nothing to load — a placeholder must never be the slow part of a grid.
///
/// Deliberately light in both themes. A white label *is* white; rendering it
/// in the app's dark ground would make it a grey square, which is the generic
/// nothing this exists to replace. In a dark grid it reads exactly as the
/// real thing does in a record bin.
struct WhiteLabelMark: View {
    /// Drawn in a `Canvas` rather than composed from shapes in a
    /// `GeometryReader`.
    ///
    /// A grid of these is built while the listener scrolls, and a
    /// GeometryReader plus five nested shapes apiece is a layout pass per
    /// tile. A canvas is one draw call and no layout at all.
    private let paper = Color(red: 0.96, green: 0.955, blue: 0.94)
    private let groove = Color(red: 0.78, green: 0.775, blue: 0.76)
    private let spindle = Color(red: 0.15, green: 0.15, blue: 0.16)

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let side = min(size.width, size.height)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(paper))

            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            func ring(_ inset: CGFloat, _ opacity: Double, _ width: CGFloat) {
                let radius = side / 2 - inset
                guard radius > 0 else { return }
                let box = CGRect(
                    x: centre.x - radius, y: centre.y - radius,
                    width: radius * 2, height: radius * 2
                )
                context.stroke(
                    Path(ellipseIn: box),
                    with: .color(groove.opacity(opacity)),
                    lineWidth: max(1, width)
                )
            }
            ring(side * 0.06, 0.7, side * 0.006)
            ring(side * 0.30, 0.5, side * 0.005)
            ring(side * 0.36, 0.35, side * 0.004)

            let hole = side * 0.085
            context.fill(
                Path(ellipseIn: CGRect(
                    x: centre.x - hole / 2, y: centre.y - hole / 2,
                    width: hole, height: hole
                )),
                with: .color(spindle)
            )
        }
        .accessibilityLabel("No sleeve")
    }
}
