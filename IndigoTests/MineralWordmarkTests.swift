//
//  MineralWordmarkTests.swift
//  IndigoTests
//
//  The wordmark wraps its clock; the wrap is only invisible if every wave in
//  `mineralSheen` has completed whole turns by then. Wrapping at 20π left the
//  slowest wave half a turn out, and the bands jumped every 63 seconds.
//

import XCTest
@testable import Indigo

final class MineralWordmarkTests: XCTestCase {
    /// The rates in `MineralShaders.metal`, radians a second. Change both together.
    private let rates = [0.9, 0.35, 0.5]

    func testEveryWaveCompletesWholeTurnsAtTheWrap() {
        for rate in rates {
            let turns = rate * MineralWordmark.period / (2 * .pi)
            XCTAssertEqual(turns, turns.rounded(), accuracy: 1e-9, "rate \(rate)")
        }
    }
}
