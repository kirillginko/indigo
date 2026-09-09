//
//  PlaybackHoldTests.swift
//  IndigoTests
//
//  A stream opening is the one request in the app that cannot be retried
//  quietly: AVPlayer gets sixty seconds to connect and then the station is
//  simply unavailable. Behind it the picture backlog runs at forty requests a
//  minute of work nobody is waiting on.
//
//  It already stands aside for a page somebody is reading. A station somebody
//  has just pressed deserves at least as much.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class PlaybackHoldTests: XCTestCase {

    func testStartingSomethingTellsTheBackgroundWorkToStandAside() {
        let player = PlaybackCoordinator(defaults: UserDefaults(suiteName: "hold-test")!)
        var held = 0
        player.onPlaybackStarting = { held += 1 }

        player.playRadio(MediaItem(
            id: "kiosk.live", sourceID: "kiosk", kind: .radioStation, title: "Kiosk",
            playbackURL: URL(string: "https://example.test/stream")!
        ))
        XCTAssertEqual(held, 1)

        // Every start, not only the first: moving between stations opens a new
        // connection each time, and each one has the same sixty seconds.
        player.playRadio(MediaItem(
            id: "nts.live", sourceID: "nts", kind: .radioStation, title: "NTS",
            playbackURL: URL(string: "https://example.test/stream2")!
        ))
        XCTAssertEqual(held, 2)
        player.stopAll()
    }

    func testAStoreAskedToStandAsideDoesSoAndThenStops() throws {
        let configuration = ModelConfiguration(
            schema: Persistence.schema, isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let dig = DigStore(context: ModelContext(container))

        // Nothing playing: the fill has no reason to wait.
        XCTAssertFalse(dig.isHoldingBackgroundWork)
        dig.holdBackgroundWork()
        XCTAssertTrue(dig.isHoldingBackgroundWork)

        // And it stops standing aside the moment the stream settles, rather
        // than sitting out a fixed stretch of time. A station that opened in
        // a second must not cost the page its pictures for the rest of a
        // minute.
        dig.releaseBackgroundHold()
        XCTAssertFalse(dig.isHoldingBackgroundWork)
    }

    /// The failure this replaces: the hold ran for a fixed twelve seconds
    /// from the moment play was pressed, so a station taking twenty-nine —
    /// which the trace of an NTS connect shows, with two reconnects — lost
    /// the protection two thirds of the way through, and the picture backlog
    /// came back and spent the request budget while the stream was still
    /// failing to open.
    @MainActor
    func testTheHoldLastsWhileTheStreamIsStillOpening() throws {
        let configuration = ModelConfiguration(
            schema: Persistence.schema, isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let dig = DigStore(context: ModelContext(container))
        let player = PlaybackCoordinator()
        player.onPlaybackStarting = { dig.holdBackgroundWork() }
        player.onPlaybackSettled = { dig.releaseBackgroundHold() }

        player.playRadio(MediaItem(
            id: "nts.live", sourceID: "nts", kind: .radioStation, title: "NTS",
            playbackURL: URL(string: "https://example.test/stream")!
        ))

        XCTAssertTrue(
            dig.isHoldingBackgroundWork,
            "Still opening, so the backlog is still out of the way"
        )
        player.stopAll()
    }
}
