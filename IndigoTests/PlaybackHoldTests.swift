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

/// The hold as the portrait fill actually experiences it, rather than as a
/// flag. The tests above prove `isHoldingBackgroundWork` flips; nothing proved
/// the loop behind it stops sending. A trace of a real session shows the fill
/// searching Discogs every 1.7 seconds straight through a hold that should
/// have parked it.
@MainActor
final class PlaybackHoldFillTests: XCTestCase {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var current: Int { lock.withLock { value } }
    }

    private struct NoAnswer: DiscogsTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            (Data("{}".utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }
    }

    func testTheFillReachesNoWorkWhileHeldAndResumesWhenReleased() async throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)
        // Neighbours nobody has a picture for: a backlog the fill would work on.
        let subject = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                    discogsID: 1, name: "Skee Mask")
        subject.labelNeighbourNames = ["Stenny", "Objekt", "Carl Craig"]
        context.insert(subject)
        try context.save()

        let dig = DigStore(
            context: context,
            discogsClient: DiscogsClient(transport: NoAnswer(), token: "test")
        )
        // Reached only once the loop is past every gate and building its queue.
        let reached = Count()
        dig.cataloguePortraits = { _ in reached.bump(); return [:] }

        dig.holdBackgroundWork()
        let fill = Task { await dig.fillPortraitsInBackground(spacing: .milliseconds(10)) }

        // Past the four seconds the fill waits for the first page to settle.
        try await Task.sleep(for: .seconds(6))
        XCTAssertEqual(reached.current, 0, "Held, so the backlog does no work at all")

        dig.releaseBackgroundHold()
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThan(reached.current, 0, "And it picks up again once let go")

        fill.cancel()
        _ = await fill.result
    }
}
