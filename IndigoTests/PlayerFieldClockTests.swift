//
//  PlayerFieldClockTests.swift
//  IndigoTests
//
//  The player's field moves only while something plays, and resumes from the
//  frame it stopped on: a pause and a play must not jump, and a hand-off
//  between tracks must not stop it.
//

import XCTest
@testable import Indigo

@MainActor
final class PlayerFieldClockTests: XCTestCase {
    private func clock() throws -> PlayerFieldClock {
        PlayerFieldClock(defaults: try XCTUnwrap(UserDefaults(suiteName: "PlayerFieldClockTests-\(UUID().uuidString)")))
    }

    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func testItMovesOnlyWhilePlaying() throws {
        let clock = try clock()
        XCTAssertEqual(clock.time(at: start), 0)
        clock.playbackChanged(true, at: start)
        XCTAssertEqual(clock.time(at: start + 10), 10, accuracy: 1e-9)
        clock.stop(at: start + 10)
        XCTAssertEqual(clock.time(at: start + 500), 10, accuracy: 1e-9, "paused, it holds its frame")
    }

    func testPlayingAgainCarriesOnFromWhereItStopped() throws {
        let clock = try clock()
        clock.playbackChanged(true, at: start)
        clock.stop(at: start + 10)
        clock.playbackChanged(true, at: start + 300)
        XCTAssertEqual(clock.time(at: start + 300), 10, accuracy: 1e-9, "no jump on play")
        XCTAssertEqual(clock.time(at: start + 305), 15, accuracy: 1e-9)
    }

    func testAHandOffBetweenTracksDoesNotStopIt() async throws {
        let clock = try clock()
        clock.playbackChanged(true, at: start)
        clock.playbackChanged(false, at: start + 5)
        clock.playbackChanged(true, at: start + 5.5)
        try await Task.sleep(for: .seconds(PlayerFieldClock.grace + 0.3))
        XCTAssertTrue(clock.isRunning)
        XCTAssertEqual(clock.time(at: start + 20), 20, accuracy: 1e-9)
    }

    func testAPauseStopsItAfterTheGrace() async throws {
        let clock = try clock()
        clock.playbackChanged(true, at: .now)
        clock.playbackChanged(false)
        XCTAssertTrue(clock.isRunning, "not yet: it may be a hand-off")
        try await Task.sleep(for: .seconds(PlayerFieldClock.grace + 0.3))
        XCTAssertFalse(clock.isRunning)
    }

    func testItKeepsItsPlaceAcrossLaunches() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PlayerFieldClockTests-\(UUID().uuidString)"))
        let first = PlayerFieldClock(defaults: defaults)
        first.playbackChanged(true, at: start)
        first.stop(at: start + 42)
        XCTAssertEqual(PlayerFieldClock(defaults: defaults).time(at: start + 9_999), 42, accuracy: 1e-9)
    }

    func testItWrapsWhereTheShaderExpects() throws {
        let clock = try clock()
        clock.playbackChanged(true, at: start)
        XCTAssertEqual(clock.time(at: start + PlayerFieldClock.wrap + 3), 3, accuracy: 1e-6)
    }
}
