//
//  CrateQueueTests.swift
//  IndigoTests
//
//  Playing out of the crate queues the rest of the crate, and the crate holds
//  stations as well as files. A live stream used to refuse next and previous
//  outright, which was right for a station played on its own — a queue of one
//  — and meant a live show in the crate was a dead end in the transport.
//

import XCTest
@testable import Indigo

@MainActor
final class CrateQueueTests: XCTestCase {

    private func station(_ id: String) -> MediaItem {
        MediaItem(
            id: id, sourceID: "kiosk", kind: .radioStation, title: id,
            playbackURL: URL(string: "https://example.test/\(id)")!
        )
    }

    func testALiveShowWithAQueueBehindItCanBeSkipped() {
        let player = PlaybackCoordinator(defaults: UserDefaults(suiteName: "crate-queue-test")!)
        defer { player.stopAll() }

        player.play([station("one"), station("two")], startingAt: 0)
        XCTAssertTrue(player.isLive)
        XCTAssertTrue(player.canSkipNext, "A live show with something after it should offer next")
        XCTAssertFalse(player.canSkipPrevious, "Nothing before it, and a stream has no start to return to")

        player.next()
        XCTAssertTrue(player.isCurrent("two"))
        XCTAssertFalse(player.canSkipNext)
        XCTAssertTrue(player.canSkipPrevious)

        player.previous()
        XCTAssertTrue(player.isCurrent("one"))
    }

    func testAStationOnItsOwnHasNowhereToSkipTo() {
        let player = PlaybackCoordinator(defaults: UserDefaults(suiteName: "crate-queue-test")!)
        defer { player.stopAll() }

        player.playRadio(station("one"))
        XCTAssertFalse(player.canSkipNext)
        XCTAssertFalse(player.canSkipPrevious)

        // And pressing them anyway leaves the station playing, not paused.
        player.next()
        player.previous()
        XCTAssertTrue(player.isCurrent("one"))
    }
}
