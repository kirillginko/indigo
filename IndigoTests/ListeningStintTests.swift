//
//  ListeningStintTests.swift
//  IndigoTests
//
//  How much was heard, when the clock and the playhead disagree.
//

import XCTest
@testable import Indigo

final class ListeningStintTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// The case that was logged: "75 Minutes" left on the crate queue at
    /// 16:38, the widget frozen 52 seconds in with the network gone and the
    /// Mac asleep, still reading "playing" when it was skipped at 03:43.
    func testAFrozenWidgetLeftOvernightIsCreditedWhatItPlayed() {
        var stint = ListeningStint()
        stint.update(isPlaying: true, progress: 0, position: 0, now: at(0))
        // Eleven hours later, and the playhead has not moved since.
        let skipped = at(11 * 3600 + 5 * 60)
        stint.update(isPlaying: true, progress: 0.134, position: 52, now: skipped)
        let heard = stint.finish(now: skipped)

        XCTAssertEqual(heard.seconds, 52, accuracy: 0.001)
        XCTAssertEqual(heard.completion, 0.134, accuracy: 0.0001)
    }

    func testAStallMidwayCreditsOnlyThePlayingEitherSideOfIt() {
        var stint = ListeningStint()
        stint.update(isPlaying: true, position: 0, now: at(0))
        // A pause after a minute: that minute was heard.
        stint.update(isPlaying: false, position: 60, now: at(60))
        stint.update(isPlaying: true, position: 60, now: at(120))
        // Resumed, then the stream starved for twenty minutes without the
        // state ever leaving "playing": only the 30 seconds it moved count.
        stint.update(isPlaying: true, position: 90, now: at(120 + 1230))
        let heard = stint.finish(now: at(120 + 1230))

        XCTAssertEqual(heard.seconds, 90, accuracy: 0.001)
    }

    func testThePlayheadNeverCreditsMoreThanTheClock() {
        var stint = ListeningStint()
        stint.update(isPlaying: true, position: 0, now: at(0))
        // Jumped ahead by some route that never said so: ten seconds of the
        // clock cannot be three minutes of listening.
        stint.update(isPlaying: false, position: 180, now: at(10))

        XCTAssertEqual(stint.finish(now: at(10)).seconds, 10, accuracy: 0.001)
    }

    func testASeekForwardIsNotListening() {
        var stint = ListeningStint()
        stint.update(isPlaying: true, position: 0, now: at(0))
        // The coordinator banks at the jump, then starts from where it landed.
        stint.update(isPlaying: true, position: 30, now: at(30))
        stint.moved(to: 300, now: at(30))
        stint.update(isPlaying: false, position: 320, now: at(50))

        XCTAssertEqual(stint.finish(now: at(50)).seconds, 50, accuracy: 0.001)
    }

    func testASeekBackDoesNotThrowAwayWhatWasHeard() {
        var stint = ListeningStint()
        stint.update(isPlaying: true, position: 0, now: at(0))
        stint.update(isPlaying: true, position: 60, now: at(60))
        stint.moved(to: 10, now: at(60))
        // Thirty more seconds from the earlier place: the playhead ends behind
        // where it was before the seek, and both stretches still count.
        stint.update(isPlaying: false, position: 40, now: at(90))

        XCTAssertEqual(stint.finish(now: at(90)).seconds, 90, accuracy: 0.001)
    }

    func testAPlayheadReadAfterTheRewindCreditsNothingRatherThanTheClock() {
        // Why the coordinator puts the playhead at the end before closing a
        // finished track: a stretch that reads as moving backwards is not
        // evidence of listening, so it is not credited the clock either.
        var stint = ListeningStint()
        stint.update(isPlaying: true, position: 0, now: at(0))
        stint.update(isPlaying: false, position: 0, now: at(240))
        XCTAssertEqual(stint.finish(now: at(240)).seconds, 0, accuracy: 0.001)

        stint.update(isPlaying: true, position: 0, now: at(0))
        stint.update(isPlaying: false, progress: 1, position: 240, now: at(240))
        stint.complete()
        let heard = stint.finish(now: at(240))
        XCTAssertEqual(heard.seconds, 240, accuracy: 0.001)
        XCTAssertEqual(heard.completion, 1)
    }

    func testALiveStreamHasNoPlayheadAndIsMeasuredByTheClock() {
        var stint = ListeningStint()
        stint.update(isPlaying: true, now: at(0))
        stint.update(isPlaying: true, now: at(600))
        stint.update(isPlaying: false, now: at(900))

        XCTAssertEqual(stint.finish(now: at(900)).seconds, 900, accuracy: 0.001)
    }

    func testAPlayheadThatAppearsMidStretchFallsBackToTheClock() {
        // A widget that reported no position when it started: there is
        // nothing to check the clock against for that stretch.
        var stint = ListeningStint()
        stint.update(isPlaying: true, now: at(0))
        stint.update(isPlaying: true, position: 400, now: at(20))
        stint.update(isPlaying: false, position: 430, now: at(50))

        XCTAssertEqual(stint.finish(now: at(50)).seconds, 50, accuracy: 0.001)
    }

    func testLoadingAndBufferingAreNotHeard() {
        // The coordinator passes "sound is coming out", not the play button:
        // twenty seconds of loading, then a minute of music.
        var stint = ListeningStint()
        stint.update(isPlaying: false, position: 0, now: at(0))
        stint.update(isPlaying: true, position: 0, now: at(20))
        stint.update(isPlaying: false, position: 60, now: at(80))

        XCTAssertEqual(stint.finish(now: at(80)).seconds, 60, accuracy: 0.001)
    }

    func testAMoveWhilePausedChangesNothing() {
        var stint = ListeningStint()
        stint.update(isPlaying: true, position: 0, now: at(0))
        stint.update(isPlaying: false, position: 30, now: at(30))
        stint.moved(to: 200, now: at(40))
        stint.update(isPlaying: true, position: 200, now: at(50))
        stint.update(isPlaying: false, position: 210, now: at(60))

        XCTAssertEqual(stint.finish(now: at(60)).seconds, 40, accuracy: 0.001)
    }

    /// A widget that loops back to the start on its own, between samples,
    /// reads as the playhead going backwards: nothing is credited for that
    /// stretch rather than the clock -- never more than was heard.
    func testALoopBetweenSamplesNeverCreditsUnheardTime() {
        var stint = ListeningStint()
        stint.update(isPlaying: true, position: 0, now: at(0))
        stint.update(isPlaying: true, position: 170, now: at(170))
        // Looped at 180 and is now 20 seconds into the second pass.
        stint.update(isPlaying: true, position: 20, now: at(200))
        let heard = stint.finish(now: at(200))
        XCTAssertLessThanOrEqual(heard.seconds, 200)
        XCTAssertEqual(heard.seconds, 170, accuracy: 0.001)
    }

    /// The network drops (the engine fails, so not audible), then the item
    /// is reopened where it was and plays again: the dead time is not heard,
    /// and the playing on both sides is.
    func testRecoveryAfterAFailureCreditsOnlyThePlaying() {
        var stint = ListeningStint()
        stint.update(isPlaying: true, position: 0, now: at(0))
        stint.update(isPlaying: false, position: 40, now: at(40))      // failed
        stint.update(isPlaying: false, position: 40, now: at(100))     // reopening
        stint.update(isPlaying: true, position: 40, now: at(130))      // playing again
        stint.update(isPlaying: false, position: 70, now: at(160))
        XCTAssertEqual(stint.finish(now: at(160)).seconds, 70, accuracy: 0.001)
    }

    /// Skipped to the next item mid-track: the outgoing stint closes on what
    /// was heard, and the next starts from nothing.
    func testQueueAdvanceClosesOneStintAndStartsTheNext() {
        var stint = ListeningStint()
        stint.update(isPlaying: true, position: 0, now: at(0))
        stint.update(isPlaying: true, position: 45, now: at(45))
        XCTAssertEqual(stint.finish(now: at(45)).seconds, 45, accuracy: 0.001)
        stint.update(isPlaying: true, position: 0, now: at(46))
        stint.update(isPlaying: false, position: 10, now: at(56))
        XCTAssertEqual(stint.finish(now: at(56)).seconds, 10, accuracy: 0.001)
    }
}
