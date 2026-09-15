//
//  ExploreFieldSliceTests.swift
//  IndigoTests
//
//  The background field on the Explore page is one `colorEffect`, and a
//  `colorEffect` is one Metal texture. A texture has a maximum edge — 16,384 on
//  Apple silicon — and a crate large enough to make that page 16,604 points
//  tall asked for a 1854x16604 BGRA8Unorm:
//
//      RBLayer: unable to create texture: BGRA8Unorm, [1854, 16604]
//
//  A failed texture draws nothing, so the page showed flat `MapColor.cobalt` —
//  which is very nearly the blue the shader itself starts from, and is why this
//  read as "the shader stopped moving" rather than "the shader is gone".
//
//  So the field is drawn in slices. What that has to get right is arithmetic
//  nobody would notice being wrong until a crate grew past it again.
//

import XCTest
@testable import Indigo

final class ExploreFieldSliceTests: XCTestCase {
    /// Apple silicon's maximum 2D texture edge. Nothing here may reach it.
    private let metalLimit: CGFloat = 16384
    private let slice: CGFloat = 4096

    private func heights(_ total: CGFloat) -> [CGFloat] {
        ExploreFieldSlices.tops(forHeight: total, each: slice).map {
            ExploreFieldSlices.height(at: $0, forHeight: total, each: slice)
        }
    }

    func testTheSlicesCoverTheWholePageExactly() {
        for total in [1.0, 100.0, 2048.0, 2049.0, 16604.0, 40000.0] as [CGFloat] {
            XCTAssertEqual(heights(total).reduce(0, +), total, accuracy: 0.001,
                           "Slices must cover \(total) with no gap and no overrun")
        }
    }

    /// The bug itself: the page that could not be drawn.
    func testThePageThatCouldNotBeDrawnIsNowWithinTheLimit() {
        let tall = heights(16604)
        XCTAssertFalse(tall.isEmpty)
        for height in tall {
            XCTAssertLessThanOrEqual(height, slice)
            XCTAssertLessThan(height, metalLimit, "A slice may never be a texture that cannot exist")
        }
        XCTAssertEqual(tall.count, 5, "16,604 at 4,096 a slice")
    }

    /// Each slice starts where the last one ended, or the pattern would step at
    /// every seam.
    func testTheSlicesAreContiguous() {
        let total: CGFloat = 16604
        let tops = ExploreFieldSlices.tops(forHeight: total, each: slice)
        var expected: CGFloat = 0
        for top in tops {
            XCTAssertEqual(top, expected, accuracy: 0.001)
            expected += ExploreFieldSlices.height(at: top, forHeight: total, each: slice)
        }
        XCTAssertEqual(expected, total, accuracy: 0.001)
    }

    /// A page with no height asks for no textures at all, rather than one of
    /// height zero.
    func testNothingToCoverIsNoSlices() {
        XCTAssertTrue(ExploreFieldSlices.tops(forHeight: 0, each: slice).isEmpty)
        XCTAssertTrue(ExploreFieldSlices.tops(forHeight: -10, each: slice).isEmpty)
        XCTAssertTrue(ExploreFieldSlices.tops(forHeight: 100, each: 0).isEmpty)
    }

    /// However tall the page grows, no single slice can become a texture the
    /// GPU will refuse — which is the whole reason this type exists.
    func testNoCrateCanGrowThePagePastTheLimit() {
        for total in stride(from: 1000.0, through: 200_000.0, by: 7_000.0) {
            for height in heights(CGFloat(total)) {
                XCTAssertLessThan(height, metalLimit)
            }
        }
    }
}
