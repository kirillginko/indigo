//
//  ArtworkLoadingTests.swift
//  IndigoTests
//
//  A dig page draws its header before the catalogue has said where the
//  picture is. Until it has, no address means "not yet", and the placeholder
//  -- the answer "there is no picture" -- must not flash up first.
//

import XCTest
import SwiftUI
@testable import Indigo

@MainActor
final class ArtworkLoadingTests: XCTestCase {
    private func pixels(_ view: some View, side: CGFloat = 120) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: side, height: side))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
    }

    /// Distinct colours on a coarse grid: a flat ground is one or two, a
    /// drawn mark is many.
    private func distinctColours(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<String>()
        for x in stride(from: 4, to: rep.pixelsWide - 4, by: 6) {
            for y in stride(from: 4, to: rep.pixelsHigh - 4, by: 6) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert("\(Int(c.redComponent * 50))-\(Int(c.greenComponent * 50))-\(Int(c.blueComponent * 50))")
            }
        }
        return seen.count
    }

    func testAPictureStillOnItsWayIsNotAnsweredWithThePlaceholder() throws {
        let settled = try pixels(ArtworkView(side: 120, placeholder: .whiteLabel))
        let awaiting = try pixels(ArtworkView(side: 120, placeholder: .whiteLabel, awaitingAddress: true))

        XCTAssertGreaterThan(distinctColours(settled), 2, "No address and nothing coming: the white label")
        XCTAssertLessThanOrEqual(distinctColours(awaiting), 2, "Address still coming: plain ground, no mark")
    }

    func testABlurredLoadingTileIsNotThePlaceholderEither() throws {
        let settled = try pixels(ArtworkView(side: 120, placeholder: .whiteLabel))
        let loading = try pixels(ArtworkView(side: 120, placeholder: .whiteLabel,
                                             awaitingAddress: true, blursWhileLoading: true))
        let centre = (settled.colorAt(x: 60, y: 60), loading.colorAt(x: 60, y: 60))
        XCTAssertNotEqual(centre.0, centre.1, "The loading field is not the white label")
    }
}
