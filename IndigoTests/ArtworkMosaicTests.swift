//
//  ArtworkMosaicTests.swift
//  IndigoTests
//
//  The block a tile draws when it has no picture.
//
//  Its whole value is that it is the same block every time: a record you have
//  met before looks like itself when you meet it again. That is one property
//  and it is invisible — a per-launch-random block looks exactly as good in a
//  screenshot — so it is worth a test rather than a comment.
//

import XCTest
import SwiftUI
@testable import Indigo

final class ArtworkMosaicTests: XCTestCase {
    /// The trap this exists for.
    ///
    /// Swift seeds `String.hashValue` per process, so the obvious spelling
    /// gives a different block on every launch. This value is written down so
    /// that swapping the hash for one that is not stable fails here rather
    /// than being noticed months later as "the squares keep changing".
    func testTheSeedIsFixedForeverRatherThanPerLaunch() {
        XCTAssertEqual(
            ArtworkMosaic.seed(for: "https://img.discogs.com/world-music.jpg"),
            ArtworkMosaic.seed(for: "https://img.discogs.com/world-music.jpg")
        )
        // Recomputed from the FNV-1a constants in the implementation. If this
        // changes, every tile in the app changes with it.
        XCTAssertEqual(ArtworkMosaic.seed(for: "World Music"), -6_827_321_323_682_410_144)
    }

    func testDifferentSubjectsGetDifferentBlocks() {
        let names = ["World Music", "Hyperdub", "Ilian Tape", "Orange Milk", "Dean Blunt"]
        let seeds = Set(names.map { ArtworkMosaic.seed(for: $0) })
        XCTAssertEqual(seeds.count, names.count, "Two subjects should not share a block by accident")
    }

    /// An empty identity is a real case — a tile with no key, no address and
    /// no name — and it must still produce a block rather than trapping.
    func testAnEmptyIdentityStillDrawsSomething() {
        XCTAssertNotNil(ArtworkMosaic(identity: "").color)
    }

    /// `abs()` traps on `Int.min`, which a 64-bit hash can genuinely produce.
    func testAColourIsChosenEvenForTheMostAwkwardSeed() {
        let mosaic = ArtworkMosaic(seed: .min)
        XCTAssertNotNil(mosaic.color)
    }
}

// MARK: - What it actually draws
//
// The first version of this shipped looking like an empty square for a good
// number of artists, and nothing in the suite noticed: every test was about
// the seed, and the seed was fine. These render the view and look at pixels.

@MainActor
final class ArtworkMosaicDrawingTests: XCTestCase {
    /// Renders at the size a connection row uses.
    private func pixels(seed: Int, side: CGFloat = 38) throws -> [UInt8] {
        let renderer = ImageRenderer(content: ArtworkMosaic(seed: seed).frame(width: side, height: side))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage, "The mosaic must render at all")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        var out: [UInt8] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                out.append(UInt8(colour.redComponent * 255))
                out.append(UInt8(colour.greenComponent * 255))
                out.append(UInt8(colour.blueComponent * 255))
            }
        }
        return out
    }

    /// The bug the screenshot showed: a tile that is all black reads as a
    /// picture that failed, which is the one thing a placeholder must not do.
    func testEverySeedDrawsSomethingOtherThanBlack() throws {
        for seed in stride(from: -900, through: 900, by: 37) {
            let lit = try pixels(seed: seed).filter { $0 > 40 }.count
            XCTAssertGreaterThan(
                lit, 0,
                "Seed \(seed) drew an empty square"
            )
        }
    }

    /// And the other half of the complaint: they must not all look alike.
    func testDifferentArtistsDrawDifferentPatterns() throws {
        let names = ["mu tate", "Dean Blunt", "Aphex Twin", "Kate NV", "Anika",
                     "Cokiyu", "Hype Williams", "Celia Hollander"]
        var seen: Set<[UInt8]> = []
        for name in names {
            seen.insert(try pixels(seed: ArtworkMosaic.seed(for: name)))
        }
        XCTAssertEqual(
            seen.count, names.count,
            "Every artist should get their own pattern, not one of a handful"
        )
    }

    /// The grid used to offer only sixteen arrangements, so this is the
    /// regression that matters most: a thousand seeds must not collapse into a
    /// tiny number of distinct patterns.
    func testTheGridOffersFarMoreThanSixteenPatterns() {
        var shapes: Set<[Int]> = []
        for seed in 0..<1000 {
            shapes.insert((0..<6).flatMap { y in (0..<6).map { x in ArtworkMosaic.cell(seed, x, y) } })
        }
        XCTAssertGreaterThan(
            shapes.count, 900,
            "A thousand artists should not share a handful of patterns"
        )
    }
}

// MARK: - The tile, not just the block
//
// `ArtworkMosaicDrawingTests` renders `ArtworkMosaic` on its own, which proves
// the block draws and proves nothing about whether a tile ever reaches it.
// The artist page's 220pt portrait was reported blank while the 38pt rows
// beside it were not, and no test above could have caught that.

@MainActor
final class ArtworkViewPlaceholderTests: XCTestCase {
    private func litPixels(_ view: some View, side: CGFloat) throws -> Int {
        let renderer = ImageRenderer(content: view.frame(width: side, height: side))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        var lit = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                // Anything with colour in it: the mosaic's blues and greens,
                // never its black ground.
                if c.redComponent > 0.2 || c.greenComponent > 0.2 || c.blueComponent > 0.2 { lit += 1 }
            }
        }
        return lit
    }

    /// The row size, which was working.
    func testASmallArtistTileDrawsItsBlock() throws {
        let tile = ArtworkView(remoteURL: nil, side: 38, placeholder: .mosaic)
        XCTAssertGreaterThan(try litPixels(tile, side: 38), 0)
    }

    /// The artist page's portrait, which was reported blank. `showsGround` is
    /// false there, which is the only thing that differs from the rows.
    func testTheLargeArtistPortraitDrawsItsBlock() throws {
        let portrait = ArtworkView(
            remoteURL: nil, side: 220, glyphScale: 0.24,
            placeholder: .mosaic, showsGround: false
        )
        XCTAssertGreaterThan(
            try litPixels(portrait, side: 220), 0,
            "The 220pt portrait must draw a block, as the rows do"
        )
    }

    /// A record must not get one, whatever else changes.
    func testAReleaseTileStillDrawsTheWhiteLabelRatherThanABlock() throws {
        let sleeve = ArtworkView(remoteURL: nil, side: 54, placeholder: .whiteLabel)
        let blocky = ArtworkView(remoteURL: nil, side: 54, placeholder: .mosaic)
        XCTAssertNotEqual(
            try litPixels(sleeve, side: 54),
            try litPixels(blocky, side: 54),
            "Records keep the white label"
        )
    }
}
