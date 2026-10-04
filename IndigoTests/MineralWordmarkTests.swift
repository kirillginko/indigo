//
//  MineralWordmarkTests.swift
//  IndigoTests
//
//  The wordmark's light is one tile, slid sideways forever. It only reads as
//  one moving surface if the tile's right edge runs into its left without a
//  step.
//

import XCTest
@testable import Indigo

final class MineralWordmarkTests: XCTestCase {
    func testTheTileRepeatsWithoutASeam() {
        for v in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(MineralSheen.light(u: 0, v: v), MineralSheen.light(u: 1, v: v), accuracy: 1e-9, "v \(v)")
        }
    }

    func testTheLightSpansDarkToBright() {
        let samples = stride(from: 0.0, to: 1.0, by: 0.01).map { MineralSheen.light(u: $0, v: 0.5) }
        XCTAssertLessThan(samples.min()!, 0.2)
        XCTAssertGreaterThan(samples.max()!, 0.8)
    }

    func testATileIsDrawn() throws {
        let tile = try XCTUnwrap(MineralSheen.tile(width: 240, height: 40))
        XCTAssertEqual(tile.width, 240)
        XCTAssertEqual(tile.height, 40)
    }
}
