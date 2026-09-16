//
//  ArtworkMosaic.swift
//  Indigo
//
//  The block of colour a tile shows when there is no picture in it.
//
//  This began as `MapGlyph`, private to EXPLORE, where a card with no image
//  has always drawn one rather than a grey square. It is here because the
//  answer it gives — "there is nothing to show you, and this is which nothing
//  it is" — is the right one everywhere, and the rest of the app was showing
//  an `square.stack` symbol or an empty frame instead.
//
//  Deterministic: the same subject draws the same block every time, on every
//  launch and on every page it appears on. That is the whole value of it. A
//  random one would be decoration; a stable one is recognisable, so a record
//  with no sleeve still looks like that record when you meet it again.
//

import SwiftUI

/// The colours a mosaic is built from. Moved here from EXPLORE, which still
/// uses them to colour its cards.
enum MosaicColor {
    static let cobalt = Color(red: 0.10, green: 0.34, blue: 0.91)
    static let blue = Color(red: 0.12, green: 0.45, blue: 0.96)
    static let blueLight = Color(red: 0.28, green: 0.82, blue: 0.94)
    static let green = Color(red: 0.29, green: 0.94, blue: 0.57)
    static let paleGreen = Color(red: 0.45, green: 0.96, blue: 0.68)
    static let paper = Color(red: 0.94, green: 0.96, blue: 0.94)
    static let lavender = Color(red: 0.73, green: 0.83, blue: 0.98)

    /// The ones a mosaic picks from when nobody chose for it.
    ///
    /// `paper` is left out: on the pale ground most tiles sit on it is very
    /// nearly invisible, which is the grey square this exists to avoid.
    static let spread: [Color] = [cobalt, blue, blueLight, green, paleGreen, lavender]
}

struct ArtworkMosaic: View {
    let seed: Int
    let color: Color

    /// Seeded from whatever identifies the subject — a URL, a library key, a
    /// name. Any of them is stable across launches, which the block has to be.
    init(seed: Int, color: Color? = nil) {
        self.seed = seed
        // Not `abs(seed)`: a 64-bit hash can be `Int.min`, whose magnitude
        // does not fit in an `Int`, and `abs` traps on it. Reinterpreting the
        // bits as unsigned keeps every seed in range and costs nothing.
        let slot = Int(UInt(bitPattern: seed) % UInt(MosaicColor.spread.count))
        self.color = color ?? MosaicColor.spread[slot]
    }

    init(identity: String, color: Color? = nil) {
        self.init(seed: Self.seed(for: identity), color: color)
    }

    var body: some View {
        // One `Canvas` rather than a grid of shapes, and the inset drawn
        // inside it rather than as padding: a tile costs a single draw and no
        // layout pass, which matters because a dig page builds dozens of them
        // inside a scroll.
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            let inset = size.width * 0.12
            let unit = (size.width - inset * 2) / 6
            guard unit > 0 else { return }
            for y in 0..<6 {
                for x in 0..<6 {
                    let n = Self.cell(seed, x, y)
                    // The half-point overdraw closes the seams that rounding
                    // otherwise leaves between neighbouring cells.
                    let cell = CGRect(
                        x: inset + CGFloat(x) * unit,
                        y: inset + CGFloat(y) * unit,
                        width: unit + 0.3,
                        height: unit + 0.3
                    )
                    context.fill(
                        Path(cell),
                        with: .color(n < 5 ? color : n < 8 ? .white.opacity(0.3) : .black)
                    )
                }
            }
        }
        .background(.black)
        .accessibilityHidden(true)
    }

    /// Which of the sixteen shades this cell takes.
    ///
    /// The seed is mixed into the cell's own coordinates rather than added to
    /// them. Added — `(seed &+ x &* 13 &+ y &* 29 &+ x &* y) & 15`, which is
    /// what this grid did when it was EXPLORE's alone — the seed is a uniform
    /// offset under a four-bit mask, so the whole app has only **sixteen**
    /// patterns: every artist looks like fifteen others, and the seeds whose
    /// offset lands most cells past the black threshold draw a square that
    /// reads as empty. With a dozen cards on a map that was survivable; as the
    /// placeholder for every artist in the app it is not.
    ///
    /// Mixed, each cell is independent, so a seed picks one arrangement out of
    /// an enormous number and the colour/white/black split below holds for
    /// every one of them.
    static func cell(_ seed: Int, _ x: Int, _ y: Int) -> Int {
        var h = UInt64(bitPattern: Int64(seed))
        h ^= UInt64(x) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(y) &* 0xC2B2_AE3D_27D4_EB4F
        // splitmix64's finaliser: cheap, and it moves every input bit into the
        // low four this reads.
        h ^= h >> 30
        h = h &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 27
        h = h &* 0x94D0_49BB_1331_11EB
        h ^= h >> 31
        return Int(h & 15)
    }

    /// A stable number for a string.
    ///
    /// Deliberately **not** `hashValue`: Swift seeds string hashing per
    /// process, so the same record would draw a different block every launch —
    /// which would undo the one property this type is for. FNV-1a is fixed
    /// forever and cheap enough to call while scrolling.
    static func seed(for identity: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(truncatingIfNeeded: hash)
    }
}
