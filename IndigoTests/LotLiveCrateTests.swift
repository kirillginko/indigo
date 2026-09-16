//
//  LotLiveCrateTests.swift
//  IndigoTests
//
//  Keeping a Lot show while it is on the air.
//
//  At that moment the broadcast has no handle to point at — The Lot has not
//  published the recording — so the row stores the station: `lot.live`, the
//  on-air title, and the live HLS address. None of that survives the show
//  ending. The title names something no longer broadcasting, the address plays
//  whatever is on now, and the row opens the shows directory because
//  `lot.live` is not an episode handle.
//
//  Reported as: "I crated a Lot radio show while it was live, but once it
//  updated to the archived show it never updated the link."
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class LotLiveCrateTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var crate: CrateService!

    private let live = "https://livepeercdn.studio/hls/85c28sa2o8wppm"
    private let billing = "Love From The Sun with Jada Lorraine, Deon Jamar and Specter"

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        crate = CrateService(context: context)
    }

    override func tearDown() {
        crate = nil
        context = nil
        container = nil
    }

    private func keptWhileOnAir() -> CrateItem {
        crate.add(
            broadcast: "lot.live",
            providerID: LotProvider.providerID,
            title: billing,
            subtitle: "The Lot Radio",
            artworkURL: nil,
            playbackURL: URL(string: live),
            embedProvider: nil,
            isLiveStream: true,
            genres: []
        )
        return crate.items().first { $0.showID == "lot.live" }!
    }

    private func episode(
        _ title: String, slug: String, show: String, airedAt: Date, stream: String? = nil
    ) -> LotEpisode {
        LotEpisode(
            id: slug, title: title, slug: slug,
            airedAt: airedAt, startedAt: airedAt, endedAt: nil,
            streamURL: stream.flatMap(URL.init(string:)),
            tracklist: [], imageURL: nil, thumbnailURLs: [],
            location: nil, genres: [], artists: [],
            show: LotShow(id: show, name: show, slug: show, photoURL: nil, genres: [], artists: [])
        )
    }

    // MARK: The row as kept

    func testAShowKeptOnAirIsMarkedAsNeedingRepair() throws {
        let item = keptWhileOnAir()
        XCTAssertTrue(item.needsLiveSnapshotRepair)
        // And it already refuses to play, which is the half that worked: the
        // live address would be a different show under the kept name.
        XCTAssertNil(item.broadcastMediaItem())
    }

    // MARK: The repair

    func testMigratingPointsTheRowAtTheBroadcast() throws {
        let item = keptWhileOnAir()
        let ref = LotEpisodeRef(show: "love-from-the-sun", episode: "2026-09-14")
        let aired = episode(billing, slug: "2026-09-14", show: "love-from-the-sun",
                            airedAt: .now, stream: "https://lot.example/archive.m3u8")

        crate.migrateLotLiveBroadcast(item, ref: ref, media: aired.mediaItem())

        XCTAssertEqual(item.showID, "lot.episode.love-from-the-sun/2026-09-14")
        XCTAssertFalse(item.isLiveStream)
        XCTAssertFalse(item.needsLiveSnapshotRepair)
        XCTAssertEqual(item.playbackURLString, "https://lot.example/archive.m3u8")
        XCTAssertEqual(item.displayTitle, billing, "The billing they kept is what they recognise")
    }

    /// The Lot cuts the recording some time after the broadcast, so the handle
    /// can exist before the audio does.
    func testTheLiveAddressIsDroppedEvenWithNoArchiveAudioYet() throws {
        let item = keptWhileOnAir()
        let ref = LotEpisodeRef(show: "love-from-the-sun", episode: "2026-09-14")
        let uncut = episode(billing, slug: "2026-09-14", show: "love-from-the-sun", airedAt: .now)
        XCTAssertNil(uncut.mediaItem(), "Precondition: nothing to play yet")

        crate.migrateLotLiveBroadcast(item, ref: ref, media: uncut.mediaItem())

        XCTAssertEqual(item.showID, "lot.episode.love-from-the-sun/2026-09-14")
        XCTAssertNil(
            item.playbackURLString,
            "Playing nothing beats playing whatever is on air now"
        )
    }

    // MARK: Which broadcast

    func testTheBroadcastNearestToWhenItWasKeptWins() {
        let kept = Date()
        let candidates = [
            episode(billing, slug: "old", show: "s", airedAt: kept.addingTimeInterval(-60 * 60 * 20)),
            episode(billing, slug: "right", show: "s", airedAt: kept.addingTimeInterval(-60 * 30)),
            episode(billing, slug: "later", show: "s", airedAt: kept.addingTimeInterval(60 * 60 * 18))
        ]
        let found = LotBrowseStore.best(
            of: candidates, matching: LibraryKey.normalize(billing), near: kept
        )
        XCTAssertEqual(found?.episode, "right")
    }

    /// The bound that matters. A residency airs repeatedly under one billing,
    /// so without it this hands back whichever episode is closest in the whole
    /// archive — for a monthly show, one weeks away from what they heard.
    func testABroadcastFromAnotherWeekIsRefusedRatherThanGuessed() {
        let kept = Date()
        let candidates = [
            episode(billing, slug: "last-month", show: "s",
                    airedAt: kept.addingTimeInterval(-60 * 60 * 24 * 30))
        ]
        XCTAssertNil(
            LotBrowseStore.best(of: candidates, matching: LibraryKey.normalize(billing), near: kept),
            "A wrong episode under the right name is worse than no link"
        )
    }

    func testAnEpisodeWithNoHandleIsNeverOffered() {
        let kept = Date()
        let orphan = LotEpisode(
            id: "x", title: billing, slug: "", airedAt: kept, startedAt: kept, endedAt: nil,
            streamURL: nil, tracklist: [], imageURL: nil, thumbnailURLs: [],
            location: nil, genres: [], artists: [], show: nil
        )
        XCTAssertNil(orphan.ref, "Precondition: nothing to point at")
        XCTAssertNil(LotBrowseStore.nearest(of: [orphan], to: kept))
    }

    // MARK: Where the repaired row opens

    /// The exact handle the repair wrote into a real store, checked against
    /// every path that asks where a row opens. The bug was reported twice —
    /// once for the crate page and once for the For You page — because those
    /// two ask different questions, and a fix to one does not reach the other.
    /// `KeptShow` exists for that reason; this pins all of them.
    func testTheRepairedRowOpensTheBroadcastEverywhere() throws {
        let showID = "lot.episode.jadalareign/2026-09-14-1200"

        let direct = BroadcastSource.destination(showID: showID, providerID: LotProvider.providerID)
        XCTAssertEqual(direct, .lotEpisode(show: "jadalareign", episode: "2026-09-14-1200"))

        // And the shows directory is no longer anywhere on the ladder for it.
        let item = keptWhileOnAir()
        crate.migrateLotLiveBroadcast(
            item,
            ref: LotEpisodeRef(show: "jadalareign", episode: "2026-09-14-1200"),
            media: episode(billing, slug: "2026-09-14-1200", show: "jadalareign",
                           airedAt: .now, stream: "https://link.storjshare.io/raw/x").mediaItem()
        )
        XCTAssertEqual(item.showID, showID)
        XCTAssertNotNil(
            item.broadcastMediaItem(),
            "Pressing the card should play the broadcast, not open a directory"
        )
    }

    // MARK: The residency in a billing

    func testTheResidencyIsReadOutOfTheBilling() {
        XCTAssertEqual(LotScheduleEntry.residency(in: billing), "Love From The Sun")
        XCTAssertEqual(LotScheduleEntry.residency(in: "Bar Dance w/ DJ Python"), "Bar Dance")
        XCTAssertEqual(LotScheduleEntry.residency(in: "Nick León presents Tropical Twista"), "Nick León")
        XCTAssertEqual(LotScheduleEntry.residency(in: "Mister Sunday"), "Mister Sunday")
    }
}
