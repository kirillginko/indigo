//
//  PlaybackWitnessTests.swift
//  IndigoTests
//
//  Phase 1. Playing something has to become evidence without the player
//  learning what SwiftData is. Pinned here: what one play counts as, and that
//  the accounting of how much was heard survives pauses and the rewind at the
//  end of a track.
//

import XCTest
import SwiftData
@testable import Indigo

final class PlaybackWitnessTests: XCTestCase {
    private func item(
        id: String,
        source: String,
        kind: MediaKind,
        title: String,
        subtitle: String? = nil,
        genres: [String] = []
    ) -> MediaItem {
        MediaItem(
            id: id, sourceID: source, kind: kind, title: title, subtitle: subtitle,
            genres: genres, playbackURL: URL(string: "https://example.com/\(id)")!
        )
    }

    // MARK: What a play counts as

    func testPuttingOnAnEpisodeIsAnEncounterWithTheShowAndTheStation() {
        let reading = PlaybackWitness.reading(for: item(
            id: "noods.show.endpapers", source: NoodsProvider.providerID,
            kind: .episode, title: "Endpapers"
        ))

        XCTAssertEqual(reading.subjects.map(\.kind), [.broadcast, .station])
        XCTAssertEqual(reading.subjects.first?.title, "Endpapers")
        XCTAssertEqual(reading.source.showTitle, "Endpapers")
        // Kept in the provider's own handle form, so the encounter can be
        // reopened rather than merely named.
        XCTAssertEqual(reading.source.showID, "noods.show.endpapers")
    }

    func testAReplayedBroadcastIsTheSameShowAsTheOriginal() {
        // The crate wraps a broadcast's id so the queue can tell its own entry
        // from the provider's. An encounter must not be filed under the
        // wrapper, or the same show would be two things.
        let replayed = PlaybackWitness.reading(for: item(
            id: "crate.lyl.lyl.episode.abc", source: LYLProvider.providerID,
            kind: .episode, title: "A Show"
        ))
        let original = PlaybackWitness.reading(for: item(
            id: "lyl.episode.abc", source: LYLProvider.providerID,
            kind: .episode, title: "A Show"
        ))
        XCTAssertEqual(replayed.subjects.first?.id, original.subjects.first?.id)
    }

    func testALiveStreamIsTheStationAndNotAShow() {
        let reading = PlaybackWitness.reading(for: item(
            id: "2", source: NTSProvider.providerID,
            kind: .radioStation, title: "NTS 2"
        ))

        XCTAssertEqual(reading.subjects.map(\.kind), [.station])
        // Keyed on the station rather than the channel: somebody who says they
        // listen to NTS means NTS, not channel 2.
        XCTAssertEqual(reading.subjects.first?.key, NTSProvider.providerID)
        XCTAssertEqual(reading.subjects.first?.handle, "2")
    }

    func testATrackIsBothTheRecordingAndTheArtist() {
        let reading = PlaybackWitness.reading(for: item(
            id: "/Music/a.flac", source: Track.sourceID,
            kind: .track, title: "Vernal Equinox", subtitle: "Jon Hassell"
        ))

        XCTAssertEqual(reading.subjects.map(\.kind), [.recording, .artist])
        XCTAssertEqual(reading.subjects.last?.title, "Jon Hassell")
        // A local file came from no station.
        XCTAssertTrue(reading.source.isEmpty)
    }

    func testATrackTitledByWhoeverUploadedItStillFindsItsArtist() {
        let reading = PlaybackWitness.reading(for: item(
            id: "yt.1", source: Track.sourceID,
            kind: .track, title: "Skee Mask - Rev8617"
        ))
        XCTAssertEqual(reading.subjects.last?.kind, .artist)
        XCTAssertEqual(reading.subjects.last?.title, "Skee Mask")
    }

    func testATrackNobodyCanNameIsNotFiledUnderAnEmptyIdentity() {
        let reading = PlaybackWitness.reading(for: item(
            id: "x", source: Track.sourceID, kind: .track, title: ""
        ))
        XCTAssertTrue(reading.subjects.isEmpty)
    }

    // MARK: Writing it down

    @MainActor
    func testAMisClickIsNotWrittenDownAtAll() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)
        let witness = PlaybackWitness(context: context)

        witness.record(
            item(id: "kiosk.episode.a", source: KioskProvider.providerID,
                 kind: .episode, title: "A Show"),
            seconds: 2, completion: 0
        )
        XCTAssertTrue(ListeningLog(context: context).all().isEmpty)
    }

    @MainActor
    func testARejectionIsWrittenDownAsOne() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)
        let witness = PlaybackWitness(context: context)

        witness.record(
            item(id: "kiosk.episode.a", source: KioskProvider.providerID,
                 kind: .episode, title: "A Show", genres: ["Techno"]),
            seconds: 12, completion: 0.01
        )
        let events = ListeningLog(context: context).all()
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.action == .skipped })
        XCTAssertTrue(events.allSatisfy { $0.tags == ["techno"] })
    }

    // MARK: Measuring how much was heard

    func testTimePausedIsNotTimeHeard() {
        let start = Date()
        var stint = ListeningStint()
        stint.update(isPlaying: true, now: start)
        stint.update(isPlaying: false, now: start.addingTimeInterval(60))
        // An hour away from the desk.
        stint.update(isPlaying: true, now: start.addingTimeInterval(3660))
        let heard = stint.finish(now: start.addingTimeInterval(3720))

        XCTAssertEqual(heard.seconds, 120, accuracy: 0.001)
    }

    func testATrackPlayedToItsEndIsRememberedAsCompleteAfterTheEngineRewinds() {
        let start = Date()
        var stint = ListeningStint()
        stint.update(isPlaying: true, progress: 0.4, now: start)
        stint.complete()
        // The engine rewinds and reports zero before anyone asks.
        stint.update(isPlaying: false, progress: 0, now: start.addingTimeInterval(200))

        XCTAssertEqual(stint.finish(now: start.addingTimeInterval(200)).completion, 1)
    }

    func testAStintThatNeverPlayedHeardNothing() {
        var stint = ListeningStint()
        stint.update(isPlaying: false)
        XCTAssertEqual(stint.finish().seconds, 0)
    }
}
