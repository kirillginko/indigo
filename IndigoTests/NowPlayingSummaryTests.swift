//
//  NowPlayingSummaryTests.swift
//  IndigoTests
//
//  Two windows render the same playback state. If they can disagree about what
//  the listener is hearing, the mini player is worse than not having one.
//

import XCTest
import SwiftData
@testable import Indigo

final class NowPlayingSummaryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: RecordingStore!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        store = RecordingStore(context: context)
    }

    override func tearDown() {
        store = nil; context = nil; container = nil
    }

    // MARK: Source vocabulary

    func testStationsReadAsChannels() {
        let nts1 = MediaItem(id: "nts.1", sourceID: "nts", kind: .radioStation,
                             title: "NTS 1", playbackURL: URL(string: "https://s/1")!)
        XCTAssertEqual(NowPlayingSummary.sourceLabel(for: nts1), "NTS/1")

        let kiosk = MediaItem(id: "kiosk.live", sourceID: "kiosk", kind: .radioStation,
                              title: "Kiosk Radio", playbackURL: URL(string: "https://s/k")!)
        XCTAssertEqual(NowPlayingSummary.sourceLabel(for: kiosk), "Kiosk")
    }

    /// An archived episode is from NTS, but it isn't a channel — "NTS/moxie"
    /// would be nonsense.
    func testArchivedEpisodesAreNotGivenAChannelNumber() {
        let episode = MediaItem(id: "nts.episode.moxie/2026-08-27", sourceID: "nts", kind: .episode,
                                title: "Moxie", playbackURL: URL(string: "https://sc/x")!,
                                embedProvider: .soundcloud)
        XCTAssertEqual(NowPlayingSummary.sourceLabel(for: episode), "NTS")
    }

    // MARK: Live

    func testALiveStationLeadsWithTheShowOnAir() {
        let station = MediaItem(id: "nts.1", sourceID: "nts", kind: .radioStation,
                                title: "NTS 1", subtitle: "Live",
                                playbackURL: URL(string: "https://s/1")!)

        let summary = NowPlayingSummary.make(item: station, showTitle: "Moxie", context: context)

        XCTAssertTrue(summary.isLive)
        XCTAssertEqual(summary.source, "NTS/1")
        XCTAssertEqual(summary.primary, "Moxie", "The show is the headline, not the channel")
        XCTAssertEqual(summary.secondary, "NTS 1")
        XCTAssertEqual(summary.status.map(\.text), ["Live"])
        XCTAssertEqual(summary.status.first?.tone, .live)
    }

    func testALiveStationWithNoScheduleFallsBackToTheChannel() {
        let station = MediaItem(id: "nts.2", sourceID: "nts", kind: .radioStation,
                                title: "NTS 2", subtitle: "Live",
                                playbackURL: URL(string: "https://s/2")!)
        let summary = NowPlayingSummary.make(item: station, showTitle: nil, context: context)
        XCTAssertEqual(summary.primary, "NTS 2")
    }

    // MARK: Archived

    func testAnEmbeddedEpisodeCreditsItsHost() {
        let episode = MediaItem(id: "kiosk.episode./episode/2026-08-27/jo-g", sourceID: "kiosk",
                                kind: .episode, title: "Jo G", subtitle: "27 Aug 2026",
                                playbackURL: URL(string: "https://soundcloud.com/kioskradio/jo-g")!,
                                embedProvider: .soundcloud)

        let summary = NowPlayingSummary.make(item: episode, showTitle: nil, context: context)

        XCTAssertFalse(summary.isLive)
        XCTAssertEqual(summary.source, "Kiosk")
        XCTAssertEqual(summary.primary, "Jo G")
        XCTAssertEqual(summary.status.map(\.text), ["SoundCloud"])
    }

    // MARK: Identity

    /// The chip appears only once something has claimed an identity — an
    /// identification that has never run must read as silence, not failure.
    func testNoIdentityChipUntilSomethingHasClaimedOne() {
        let track = MediaItem(id: "/Music/Bike.flac", sourceID: Track.sourceID, kind: .track,
                              title: "Bike", subtitle: "Autechre",
                              playbackURL: URL(fileURLWithPath: "/Music/Bike.flac"))

        let summary = NowPlayingSummary.make(item: track, showTitle: nil, context: context)

        XCTAssertNil(summary.recording)
        XCTAssertFalse(summary.status.contains { $0.text.hasPrefix("Match") })
        XCTAssertFalse(summary.status.contains { $0.text == "Unknown" })
    }

    func testAKnownRecordingShowsItsIdentity() throws {
        let recording = try store.upsert(title: "Bike", artistName: "Autechre")
        store.link(recording, toLocalFile: "/Music/Bike.flac")

        let track = MediaItem(id: "/Music/Bike.flac", sourceID: Track.sourceID, kind: .track,
                              title: "Bike", subtitle: "Autechre",
                              playbackURL: URL(fileURLWithPath: "/Music/Bike.flac"))
        let summary = NowPlayingSummary.make(item: track, showTitle: nil, context: context)

        XCTAssertEqual(summary.recording?.id, recording.id)
        XCTAssertTrue(summary.status.contains { $0.text == "Match ✓" && $0.tone == .affirmed })
        XCTAssertEqual(summary.source, "Local")
        XCTAssertEqual(summary.primary, "Autechre", "Artist leads, title underneath")
        XCTAssertEqual(summary.secondary, "Bike")
    }

    func testAnUnidentifiedRecordingSaysSo() throws {
        let unknown = try store.createUnknown(
            providerID: "nts", showID: "moxie/2026-08-27",
            heardAt: Date(timeIntervalSince1970: 1_787_000_000), offsetSeconds: 900
        )
        store.link(unknown, toLocalFile: "/Music/mystery.flac")

        let track = MediaItem(id: "/Music/mystery.flac", sourceID: Track.sourceID, kind: .track,
                              title: "mystery", playbackURL: URL(fileURLWithPath: "/Music/mystery.flac"))
        let summary = NowPlayingSummary.make(item: track, showTitle: nil, context: context)

        XCTAssertTrue(summary.status.contains { $0.text == "Unknown" && $0.tone == .pending })
    }

    /// Redrawing a player bar must never write to the store.
    func testBuildingASummaryCreatesNothing() throws {
        let track = MediaItem(id: "/Music/Nothing.flac", sourceID: Track.sourceID, kind: .track,
                              title: "Nothing", subtitle: "Nobody",
                              playbackURL: URL(fileURLWithPath: "/Music/Nothing.flac"))

        _ = NowPlayingSummary.make(item: track, showTitle: nil, context: context)
        _ = NowPlayingSummary.make(item: track, showTitle: nil, context: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Recording>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordingSource>()), 0)
    }

    func testNothingPlayingIsARenderableState() {
        let summary = NowPlayingSummary.make(item: nil, showTitle: nil, context: context)
        XCTAssertEqual(summary.primary, "Nothing playing")
        XCTAssertTrue(summary.status.isEmpty)
        XCTAssertFalse(summary.isLive)
    }
}
