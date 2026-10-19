import SwiftUI

/// An image must cover the actual Retina viewport before it can fill a slide.
/// Unknown images and small fallbacks stay contained while the larger cut loads.
nonisolated enum PhoneSlideArtworkSizing {
    static func fillsViewport(imagePixels: CGSize?, viewport: CGSize, scale: CGFloat) -> Bool {
        guard let imagePixels, scale > 0, viewport.width > 0, viewport.height > 0 else { return false }
        return imagePixels.width >= viewport.width * scale && imagePixels.height >= viewport.height * scale
    }

    /// A single compact layout, independent of the source image's dimensions.
    static func containedSide(viewport: CGSize) -> CGFloat {
        max(0, min(200, viewport.width - 96, viewport.height * 0.28))
    }
}

struct PhoneSlideArtwork: View {
    let picture: URL?
    let preview: URL?
    let viewport: CGSize
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
    private var request: String { "\(sharper?.absoluteString ?? "")|\(picture?.absoluteString ?? "")|\(preview?.absoluteString ?? "")|\(RemoteArtworkStore.step(for: targetPixels))" }
    private var current: Loaded? { loaded?.request == request ? loaded : nil }

    var body: some View {
        Group {
            if let current {
                if PhoneSlideArtworkSizing.fillsViewport(imagePixels: current.pixels, viewport: viewport, scale: scale) {
                    ArtworkView(remoteURL: current.address, side: viewport.height,
                                aspect: viewport.width / max(1, viewport.height), glyphScale: 0.3)
                } else {
                    ZStack {
                        PlayerShaderBackdrop()
                        ArtworkView(remoteURL: current.address,
                                    side: PhoneSlideArtworkSizing.containedSide(viewport: viewport),
                                    glyphScale: 0.3)
                            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                            .position(x: viewport.width / 2, y: viewport.height * 0.26)
                    }
                }
            } else if picture == nil || settled {
                MineralSheenSurface()
            } else {
                PlayerShaderBackdrop()
            }
        }
        .task(id: request) {
            settled = false
            var seen = Set<URL>()
            var bestCoverage: CGFloat = 0
            for address in [sharper, picture, preview].compactMap({ $0 }) where seen.insert(address).inserted {
                guard !Task.isCancelled else { return }
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
