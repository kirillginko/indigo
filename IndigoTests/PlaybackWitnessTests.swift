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
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        ListeningAttributionFeature.override = true
        defer { ListeningAttributionFeature.override = nil }
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        XCTAssertTrue(events.allSatisfy { $0.musicTags == ["techno"] })
        XCTAssertTrue(events.allSatisfy { $0.surface == ListeningSurface(screen: "radio.archive", route: KioskProvider.providerID.lowercased()) },
                      "pressed somewhere that said nothing: an archive is radio")
    }

    /// Where a listen started is written down with it, and survives the
    /// tag folding; taste never sees it.
    /// Off, as in the App Store build: nothing but the music in the tags.
    @MainActor
    func testWithAttributionOffOnlyTheMusicIsWritten() throws {
        ListeningAttributionFeature.override = false
        defer { ListeningAttributionFeature.override = nil }
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let context = ModelContext(try ModelContainer(for: Persistence.schema, configurations: configuration))
        PlaybackWitness(context: context).record(item(id: "y", source: "youtube", kind: .track, title: "T", subtitle: "A", genres: ["Dub"]),
                                                 seconds: 60, completion: 1, surface: ListeningSurface(screen: "foryou.mix"))
        XCTAssertTrue(ListeningLog(context: context).all().allSatisfy { $0.tags == ["dub"] })
    }

    @MainActor
    func testTheSurfaceThatStartedAListenIsWrittenDown() throws {
        ListeningAttributionFeature.override = true
        defer { ListeningAttributionFeature.override = nil }
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)
        let witness = PlaybackWitness(context: context)
        witness.record(
            item(id: "youtube.x", source: "youtube", kind: .track, title: "Rev8617", subtitle: "Skee Mask", genres: ["Ambient / Techno"]),
            seconds: 240, completion: 1,
            surface: ListeningSurface(screen: "foryou.mix", via: "Burial, Kode9", route: "track")
        )
        let events = ListeningLog(context: context).all()
        XCTAssertEqual(events.count, 2, "the recording and the artist")
        for event in events {
            XCTAssertEqual(event.surface, ListeningSurface(screen: "foryou.mix", via: RecordingKey.normalizeArtist("Burial  Kode9"), route: "track"))
            XCTAssertEqual(event.musicTags, ["ambient", "techno"])
        }
        let taste = TasteProfile.build(from: events, now: Date())
        XCTAssertFalse(taste.weights.keys.contains { ListeningSurface.isSurfaceTag($0) })
    }

    @MainActor
    func testThePlayerRemembersWhereEachItemWasStartedFrom() {
        let player = PlaybackCoordinator(defaults: UserDefaults(suiteName: "surface-test")!)
        defer { player.stopAll() }
        let a = item(id: "a", source: "nts", kind: .radioStation, title: "A")
        let b = item(id: "b", source: "nts", kind: .radioStation, title: "B")
        player.play([a, b], from: ListeningSurface(screen: "dig.discover", via: "x", route: "track"))
        XCTAssertEqual(player.surface(for: "b")?.screen, "dig.discover", "a queued item keeps the surface it was queued from")
        player.playRadio(item(id: "s", source: "nts", kind: .radioStation, title: "NTS 1"))
        XCTAssertEqual(player.surface(for: "s")?.screen, "radio.live", "the screen said nothing: the item says radio")
        // The listen running is credited to where it started, even when a
        // new queue holding the same item arrives before it ends.
        player.play([b, a], startingAt: 0, surfaces: [ListeningSurface(screen: "foryou.mix", via: "y"), nil])
        XCTAssertEqual(player.listeningSurface?.screen, "foryou.mix")
        XCTAssertEqual(player.surface(for: "b")?.via, "y", "each queued item its own")
        player.play([a])
        XCTAssertEqual(player.surface(for: "a")?.screen, "radio.live", "played again from somewhere that said nothing: not the old surface")
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
