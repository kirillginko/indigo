//
//  ExploreCullingTests.swift
//  IndigoTests
//
//  For You builds only the cards within a window's height of the screen.
//  Every card cost something on every step of a scroll, cached or not, and
//  ~150 of them were 70-80% of the main thread while scrolling.
//

import XCTest
@testable import Indigo

@MainActor
final class ExploreCullingTests: XCTestCase {
    private func scroll(top: CGFloat, viewport: CGFloat = 722, header: CGFloat = 149) -> ExploreScroll {
        let scroll = ExploreScroll()
        scroll.headerHeight = header
        scroll.update(.init(top: top, contentHeight: 10_000, viewportHeight: viewport))
        return scroll
    }

    /// Everything on screen is built, and a window's height either side.
    func testTheWindowAndAWindowEitherSideAreBuilt() {
        let scroll = scroll(top: 3000)
        let cardsTop: CGFloat = 3000 - 149
        for y in stride(from: cardsTop - 700, through: cardsTop + 722 + 700, by: 50) {
            XCTAssertTrue(ExploreScroll.builds(CGPoint(x: 0, y: y), in: scroll.band), "y=\(y)")
        }
    }

    func testCardsFarFromTheWindowAreNot() {
        let scroll = scroll(top: 3000)
        XCTAssertFalse(ExploreScroll.builds(CGPoint(x: 0, y: 200), in: scroll.band))
        XCTAssertFalse(ExploreScroll.builds(CGPoint(x: 0, y: 9000), in: scroll.band))
    }

    /// The page re-renders when the band changes, so a small scroll must not
    /// change it: only crossing a tile does.
    func testASmallScrollLeavesTheBandAlone() {
        let scroll = scroll(top: 3000)
        let before = scroll.band
        scroll.update(.init(top: 3010, contentHeight: 10_000, viewportHeight: 722))
        XCTAssertEqual(scroll.band, before)
    }

    /// At the top, the cards under the header are built from the first frame.
    func testTheTopOfThePageIsBuiltAtTheTop() {
        let scroll = scroll(top: 0)
        XCTAssertTrue(ExploreScroll.builds(CGPoint(x: 0, y: 150), in: scroll.band))
        XCTAssertTrue(ExploreScroll.builds(CGPoint(x: 0, y: 1400), in: scroll.band))
    }
}
