//
//  MineralWordmark.swift
//  Indigo
//
//  The app's name at the top of the sidebar: monospaced caps on a plate of
//  green metal whose light drifts across it.
//
//  The light is a picture, not a shader. It was a Metal shader redrawn from a
//  SwiftUI timeline, and a timeline is driven from the main thread: opening
//  Dig, or anything else that held the main thread, stopped the light until it
//  let go. Now one tile of the bands is drawn once, two copies of it sit side
//  by side in a layer, and Core Animation slides that layer by one tile,
//  forever. The render server runs that animation, so it keeps moving whatever
//  the app is doing, and costs the app nothing per frame.
//
//  With Reduce Motion on it holds still.
//

import CoreGraphics
import SwiftUI

struct MineralWordmark: View {
    var title = "Mineral"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(title)
            .microLabel(2.4, size: 11)
            .foregroundStyle(Color(red: 0.06, green: 0.11, blue: 0.07))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background { MineralSheenLayer(moving: !reduceMotion) }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}

/// The bands: light across a tile, as a value from 0 to 1, and its colour.
///
/// Periodic in `u` over one tile, so the tile repeats without a seam: each
/// wave makes a whole number of turns across it. A tile is two plates wide,
/// the waves the old shader drew (about 1.35 and 0.6 turns a plate) rounded
/// to 3 and 1 turns a tile.
enum MineralSheen {
    /// How many plates wide one tile is.
    static let tileWidthInPlates: CGFloat = 2
    /// Seconds for the light to cross one tile: the old shader's pace.
    static let secondsPerTile: CFTimeInterval = 19

    static func light(u: Double, v: Double) -> Double {
        let turn = 2 * Double.pi
        let a = sin(u * turn * 3 + sin(v * 2.2) * 0.55)
        let b = sin(u * turn * 1 + 1.7)
        let x = min(max(0.5 + 0.32 * a + 0.24 * b, 0), 1)
        let t = min(max((x - 0.08) / (0.96 - 0.08), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func colour(light: Double, v: Double) -> (red: Double, green: Double, blue: Double) {
        let deep = (0.22, 0.38, 0.21), mid = (0.47, 0.64, 0.42), high = (0.87, 0.95, 0.81)
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        let c = light < 0.5 ? mix(deep, mid, light * 2) : mix(mid, high, (light - 0.5) * 2)
        // A little darker at the top and bottom edges, as pressed metal is.
        let edge = 0.9 + 0.1 * sin(v * .pi)
        return (c.0 * edge, c.1 * edge, c.2 * edge)
    }

    /// `tiles` tiles side by side, each `width` by `height` pixels, in one
    /// image: copies in separate layers met at a hairline the eye could see.
    static func tile(width: Int, height: Int, tiles: Int = 1) -> CGImage? {
        let total = width * tiles
        guard width > 0, height > 0, tiles > 0,
              let context = CGContext(data: nil, width: total, height: height, bitsPerComponent: 8, bytesPerRow: total * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for y in 0..<height {
            let v = (Double(y) + 0.5) / Double(height)
            for x in 0..<total {
                let u = Double(x % width) / Double(width)
                let c = colour(light: light(u: u, v: v), v: v)
                let i = (y * total + x) * 4
                pixels[i] = UInt8(c.red * 255); pixels[i + 1] = UInt8(c.green * 255)
                pixels[i + 2] = UInt8(c.blue * 255); pixels[i + 3] = 255
            }
        }
        return context.makeImage()
    }
}

#if os(macOS)
import AppKit
private typealias PlatformView = NSView
private typealias PlatformRepresentable = NSViewRepresentable
#else
import UIKit
private typealias PlatformView = UIView
private typealias PlatformRepresentable = UIViewRepresentable
#endif

/// The wordmark's moving light as a surface of its own, for anything else
/// that wears it -- the phone's sheen chip (`Chip`).
struct MineralSheenSurface: View {
    var moving = true
    var body: some View { MineralSheenLayer(moving: moving) }
}

/// Two tiles side by side in one image, slid left by one tile and around again.
private struct MineralSheenLayer: PlatformRepresentable {
    let moving: Bool

    #if os(macOS)
    func makeNSView(context: Context) -> SheenView { SheenView() }
    func updateNSView(_ view: SheenView, context: Context) { view.moving = moving }
    #else
    func makeUIView(context: Context) -> SheenView { SheenView() }
    func updateUIView(_ view: SheenView, context: Context) { view.moving = moving }
    #endif

    final class SheenView: PlatformView {
        private let strip = CALayer()
        private var drawnFor: CGSize = .zero
        private var tileWidth: CGFloat = 0
        var moving = true { didSet { if moving != oldValue { restart() } } }

        #if os(macOS)
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.addSublayer(strip)
        }
        override func layout() { super.layout(); redraw() }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); drawnFor = .zero; redraw() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restart() }
        private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
        #else
        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.masksToBounds = true
            layer.addSublayer(strip)
            isUserInteractionEnabled = false
        }
        override func layoutSubviews() { super.layoutSubviews(); redraw() }
        override func didMoveToWindow() { super.didMoveToWindow(); restart() }
        private var scale: CGFloat { window?.screen.scale ?? 3 }
        #endif

        required init?(coder: NSCoder) { fatalError("not used") }

        /// A new tile only when the plate's size changes.
        private func redraw() {
            let size = bounds.size
            guard size.width > 0, size.height > 0, size != drawnFor else { return }
            drawnFor = size
            let tileWidth = (size.width * MineralSheen.tileWidthInPlates).rounded(.up)
            let pixelsWide = Int(tileWidth * scale), pixelsHigh = Int((size.height * scale).rounded(.up))
            guard let image = MineralSheen.tile(width: pixelsWide, height: pixelsHigh, tiles: 2) else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            strip.contents = image
            strip.contentsScale = scale
            strip.contentsGravity = .resize
            strip.anchorPoint = .zero
            strip.bounds = CGRect(x: 0, y: 0, width: tileWidth * 2, height: size.height)
            strip.position = .zero
            self.tileWidth = tileWidth
            CATransaction.commit()
            restart()
        }

        private func restart() {
            strip.removeAnimation(forKey: "drift")
            guard moving, window != nil, tileWidth > 0 else { return }
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = 0
            drift.toValue = -tileWidth
            drift.duration = MineralSheen.secondsPerTile
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .linear)
            // Keep going through a window going to the back and coming forward.
            drift.isRemovedOnCompletion = false
            strip.add(drift, forKey: "drift")
        }
    }
}
