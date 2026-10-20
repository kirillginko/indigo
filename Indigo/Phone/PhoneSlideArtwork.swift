import SwiftUI

/// An image must cover the actual Retina viewport before it can fill a slide.
/// Unknown images and small fallbacks stay contained while the larger cut loads.
nonisolated enum PhoneSlideArtworkSizing {
    static func fillsViewport(imagePixels: CGSize?, viewport: CGSize, scale: CGFloat) -> Bool {
        guard let imagePixels, scale > 0, viewport.width > 0, viewport.height > 0 else { return false }
        return imagePixels.width >= viewport.width * scale && imagePixels.height >= viewport.height * scale
    }

    /// Keep small images within their native pixels at the screen's backing scale.
    static func containedSide(viewport: CGSize, imagePixels: CGSize? = nil,
                              scale: CGFloat = 1, maximumSide: CGFloat = 200) -> CGFloat {
        let available = max(0, min(maximumSide, viewport.width - 96, viewport.height * 0.28))
        guard let imagePixels else { return available }
        guard scale > 0 else { return 0 }
        return max(0, min(available, min(imagePixels.width, imagePixels.height) / scale))
    }

    /// Whether a picture is enough to fill a slide when some softness is
    /// acceptable: its shorter side has at least `minimumSide` pixels. The
    /// Lot's booth camera frame is 426×240 and fills; a 150-pixel thumbnail
    /// does not.
    static func fillsSlide(imagePixels: CGSize?, minimumSide: CGFloat) -> Bool {
        guard let imagePixels else { return false }
        return min(imagePixels.width, imagePixels.height) >= minimumSide
    }
}

struct PhoneSlideArtwork: View {
    let picture: URL?
    let preview: URL?
    let viewport: CGSize
    var stationMark: URL? = nil
    /// Live's slides: fill the slide with any picture whose shorter side has
    /// this many pixels, accepting some softness, rather than only one sharp
    /// at full Retina. Nil keeps the strict rule.
    var fillFloor: CGFloat? = nil
    @Environment(\.displayScale) private var scale
    @State private var loaded: Loaded?
    @State private var settled = false

    private struct Loaded {
        let request: String
        let address: URL
        let pixels: CGSize
    }

    private var targetPixels: CGFloat {
        max(viewport.width, viewport.height) * scale
    }
    private var sharper: URL? { ArtworkSizing.sharper(picture, pixels: targetPixels) }
    private var request: String { "\(sharper?.absoluteString ?? "")|\(picture?.absoluteString ?? "")|\(preview?.absoluteString ?? "")|\(stationMark?.absoluteString ?? "")|\(RemoteArtworkStore.step(for: targetPixels))" }
    private var current: Loaded? { loaded?.request == request ? loaded : nil }

    private func fills(_ pixels: CGSize) -> Bool {
        if let fillFloor { return PhoneSlideArtworkSizing.fillsSlide(imagePixels: pixels, minimumSide: fillFloor) }
        return PhoneSlideArtworkSizing.fillsViewport(imagePixels: pixels, viewport: viewport, scale: scale)
    }

    var body: some View {
        Group {
            if let current {
                let isStationMark = current.address == stationMark
                if !isStationMark, fills(current.pixels) {
                    ArtworkView(remoteURL: current.address, side: viewport.height,
                                aspect: viewport.width / max(1, viewport.height), glyphScale: 0.3)
                } else {
                    ZStack {
                        PlayerShaderBackdrop()
                        ArtworkView(remoteURL: current.address,
                                    side: PhoneSlideArtworkSizing.containedSide(
                                        viewport: viewport, imagePixels: current.pixels,
                                        scale: scale, maximumSide: isStationMark ? 120 : 200),
                                    glyphScale: 0.3)
                            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                            .position(x: viewport.width / 2, y: viewport.height * 0.26)
                    }
                }
            } else if (picture == nil && stationMark == nil) || settled {
                MineralSheenSurface()
            } else {
                PlayerShaderBackdrop()
            }
        }
        .task(id: request) {
            settled = false
            var seen = Set<URL>()
            var bestCoverage: CGFloat = 0
            for address in [sharper, picture, preview, stationMark].compactMap({ $0 }) where seen.insert(address).inserted {
                guard !Task.isCancelled else { return }
                // A mark is a fallback, never a replacement for a loaded show picture.
                if address == stationMark, bestCoverage > 0 { continue }
                if let image = await RemoteArtworkStore.shared.image(for: address, pixels: targetPixels) {
                    guard !Task.isCancelled else { return }
                    #if os(macOS)
                    let pixels = image.size
                    #else
                    let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
                    #endif
                    let coverage = min(pixels.width / max(1, viewport.width), pixels.height / max(1, viewport.height))
                    if coverage > bestCoverage {
                        bestCoverage = coverage
                        loaded = Loaded(request: request, address: address, pixels: pixels)
                    }
                    if PhoneSlideArtworkSizing.fillsViewport(imagePixels: pixels, viewport: viewport, scale: scale) {
                        return
                    }
                }
            }
            if !Task.isCancelled { settled = true }
        }
    }
}
