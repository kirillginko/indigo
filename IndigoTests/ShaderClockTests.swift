//
//  ShaderClockTests.swift
//  IndigoTests
//
//  A field moves only while it should, and resumes from the frame it stopped
//  on: a pause and a play must not jump, a hand-off between tracks must not
//  stop the player's, and leaving For You and coming back must not restart it.
//

import XCTest
@testable import Indigo

@MainActor
final class ShaderClockTests: XCTestCase {
    private func clock() throws -> ShaderClock {
        ShaderClock(key: "test", wrap: 4096, grace: 1.5, defaults: try XCTUnwrap(UserDefaults(suiteName: "ShaderClockTests-\(UUID().uuidString)")))
    }

    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func testItMovesOnlyWhilePlaying() throws {
        let clock = try clock()
        XCTAssertEqual(clock.time(at: start), 0)
        clock.setRunning(true, at: start)
        XCTAssertEqual(clock.time(at: start + 10), 10, accuracy: 1e-9)
        clock.stop(at: start + 10)
        XCTAssertEqual(clock.time(at: start + 500), 10, accuracy: 1e-9, "paused, it holds its frame")
    }

    func testPlayingAgainCarriesOnFromWhereItStopped() throws {
        let clock = try clock()
        clock.setRunning(true, at: start)
        clock.stop(at: start + 10)
        clock.setRunning(true, at: start + 300)
        XCTAssertEqual(clock.time(at: start + 300), 10, accuracy: 1e-9, "no jump on play")
        XCTAssertEqual(clock.time(at: start + 305), 15, accuracy: 1e-9)
    }

    func testAHandOffBetweenTracksDoesNotStopIt() async throws {
        let clock = try clock()
        clock.setRunning(true, at: start)
        clock.setRunning(false, at: start + 5)
        clock.setRunning(true, at: start + 5.5)
        try await Task.sleep(for: .seconds(1.5 + 0.3))
        XCTAssertTrue(clock.isRunning)
        XCTAssertEqual(clock.time(at: start + 20), 20, accuracy: 1e-9)
    }

    func testAPauseStopsItAfterTheGrace() async throws {
        let clock = try clock()
        clock.setRunning(true, at: .now)
        clock.setRunning(false)
        XCTAssertTrue(clock.isRunning, "not yet: it may be a hand-off")
        try await Task.sleep(for: .seconds(1.5 + 0.3))
        XCTAssertFalse(clock.isRunning)
    }

    func testItKeepsItsPlaceAcrossLaunches() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ShaderClockTests-\(UUID().uuidString)"))
        let first = ShaderClock(key: "test", wrap: 4096, grace: 1.5, defaults: defaults)
        first.setRunning(true, at: start)
        first.stop(at: start + 42)
        XCTAssertEqual(ShaderClock(key: "test", wrap: 4096, grace: 1.5, defaults: defaults).time(at: start + 9_999), 42, accuracy: 1e-9)
    }

    func testItWrapsWhereTheShaderExpects() throws {
        let clock = try clock()
        clock.setRunning(true, at: start)
        XCTAssertEqual(clock.time(at: start + 4096 + 3), 3, accuracy: 1e-6)
    }

    func testWithoutGraceAStopIsImmediate() throws {
        let clock = ShaderClock(key: "test", wrap: 100_000, grace: 0,
                                defaults: try XCTUnwrap(UserDefaults(suiteName: "ShaderClockTests-\(UUID().uuidString)")))
        clock.setRunning(true, at: start)
        clock.setRunning(false, at: start + 30)
        XCTAssertFalse(clock.isRunning)
        clock.setRunning(true, at: start + 900)
        XCTAssertEqual(clock.time(at: start + 900), 30, accuracy: 1e-9, "back on the page, where it left off")
    }

    /// For You's fade into warm colours reads the total, so a wrap of the
    /// field's time must never take the warmth away again.
    func testTheTotalNeverWrapsAndOutlivesALaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ShaderClockTests-\(UUID().uuidString)"))
        let first = ShaderClock(key: "test", wrap: 100, grace: 0, defaults: defaults)
        first.setRunning(true, at: start)
        first.setRunning(false, at: start + 250)
        XCTAssertEqual(first.time(at: start + 250), 50, accuracy: 1e-9)
        XCTAssertEqual(first.totalTime(at: start + 250), 250, accuracy: 1e-9)
        let again = ShaderClock(key: "test", wrap: 100, grace: 0, defaults: defaults)
        XCTAssertEqual(again.totalTime(at: start), 250, accuracy: 1e-9)
        XCTAssertEqual(again.time(at: start), 50, accuracy: 1e-9)
    }

    /// For You's fade into warm colours reads this: it starts again at every
    /// launch, but not when the page is left and come back to.
    func testSessionTimeStartsAgainAtLaunchButNotOnReturn() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ShaderClockTests-\(UUID().uuidString)"))
        let first = ShaderClock(key: "test", wrap: 3600, grace: 0, defaults: defaults)
        first.setRunning(true, at: start)
        first.setRunning(false, at: start + 60)
        first.setRunning(true, at: start + 500)
        XCTAssertEqual(first.sessionTime(at: start + 520), 80, accuracy: 1e-9, "a return carries on")
        first.stop(at: start + 520)
        let relaunched = ShaderClock(key: "test", wrap: 3600, grace: 0, defaults: defaults)
        XCTAssertEqual(relaunched.sessionTime(at: start + 600), 0, "a launch starts over")
        XCTAssertEqual(relaunched.time(at: start + 600), 80, accuracy: 1e-9, "while the field keeps its place")
    }
}
