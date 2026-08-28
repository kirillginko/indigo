//
//  CrateTests.swift
//  IndigoTests
//
//  The crate is the one store in the app that isn't a rebuildable cache, so
//  its promises — one press, no duplicates, provenance kept — are pinned here.
//

import XCTest
import SwiftData
@testable import Indigo

final class CrateTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var crate: CrateService!
    private var recordings: RecordingStore!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        crate = CrateService(context: context)
        recordings = RecordingStore(context: context)
    }

    override func tearDown() {
        recordings = nil
        crate = nil
        context = nil
        container = nil
    }

    // MARK: Crating music

    func testCratingIsIdempotent() throws {
        let recording = try recordings.upsert(title: "Rev8617", artistName: "Skee Mask")

        crate.add(recording: recording)
        crate.add(recording: recording)

        XCTAssertEqual(crate.count, 1)
        XCTAssertTrue(crate.contains(recording: recording))
    }

    func testToggleRemoves() throws {
        let recording = try recordings.upsert(title: "Rev8617", artistName: "Skee Mask")

        crate.toggle(recording: recording)
        XCTAssertTrue(crate.contains(recording: recording))
        crate.toggle(recording: recording)
        XCTAssertFalse(crate.contains(recording: recording))
        XCTAssertEqual(crate.count, 0)
    }

    /// Deleting a crate entry must not delete the recording behind it — the
    /// music, and its provenance, outlive the decision to keep it.
    func testRemovingFromCrateKeepsTheRecording() throws {
        let recording = try recordings.upsert(title: "Hubble", artistName: "Actress")
        let item = crate.add(recording: recording)
        crate.remove(item)

        XCTAssertEqual(crate.count, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Recording>()), 1)
    }

    // MARK: Unknown music

    /// The failure flow from the spec: no match, still saveable, provenance
    /// intact.
    func testAnUnidentifiedTrackIsCratableWithItsProvenance() throws {
        let heardAt = Date(timeIntervalSince1970: 1_787_000_000)
        let unknown = try recordings.createUnknown(
            providerID: "nts", showID: "ben-ufo/2026-01-14",
            heardAt: heardAt, offsetSeconds: 4903
        )
        recordings.note(
            appearance: MediaAppearance(
                providerID: "nts", stationID: "nts.1", stationName: "NTS 1",
                showTitle: "Ben UFO", showID: "ben-ufo/2026-01-14",
                heardAt: heardAt, offsetSeconds: 4903, isLive: true, method: .none
            ),
            on: unknown
        )

        let item = crate.add(recording: unknown)

        XCTAssertEqual(crate.count, 1)
        XCTAssertTrue(item.displayTitle.hasPrefix("UNKNOWN/"))
        XCTAssertEqual(item.statusLabel, "Unknown")
        XCTAssertEqual(item.sourceLine, "NTS 1 / Ben UFO @ 01:21:43")
    }

    // MARK: Broadcasts

    func testCratingWhatIsPlayingKeepsTheBroadcast() {
        let episode = MediaItem(
            id: "nts.episode.moxie/2026-08-27", sourceID: "nts", kind: .episode,
            title: "Moxie", subtitle: "27 Aug 2026", detail: "NTS",
            genres: ["House", "Jazz"],
            remoteArtworkURL: URL(string: "https://media.example/moxie.jpg"),
            playbackURL: URL(string: "https://soundcloud.com/nts/moxie")!,
            embedProvider: .soundcloud
        )

        XCTAssertFalse(crate.isCrated(nowPlaying: episode))
        crate.toggle(nowPlaying: episode)
        XCTAssertTrue(crate.isCrated(nowPlaying: episode))
        XCTAssertEqual(crate.count, 1)

        let item = try? XCTUnwrap(crate.items().first)
        XCTAssertEqual(item?.kind, .broadcast)
        XCTAssertEqual(item?.sourceLine, "NTS")
        XCTAssertEqual(item?.genreTags, ["House", "Jazz"])

        // A crated broadcast has to be playable again from the crate alone.
        let replay = try? XCTUnwrap(item?.broadcastMediaItem())
        XCTAssertEqual(replay?.embedProvider, .soundcloud)
        XCTAssertEqual(replay?.playbackURL.absoluteString, "https://soundcloud.com/nts/moxie")
        XCTAssertEqual(replay?.genres, ["House", "Jazz"])

        crate.toggle(nowPlaying: episode)
        XCTAssertEqual(crate.count, 0)
    }

    /// A live station's headline is the show on air, so the crated entry keeps
    /// the show as its title and the station underneath.
    func testCratingALiveStationNamesTheShow() {
        let station = MediaItem(
            id: "nts.1", sourceID: "nts", kind: .radioStation,
            title: "NTS 1", subtitle: "Moxie", detail: "NTS",
            playbackURL: URL(string: "https://stream.example/1")!
        )
        crate.toggle(nowPlaying: station, showTitle: "Moxie")

        let item = crate.items().first
        XCTAssertEqual(item?.displayTitle, "Moxie")
        XCTAssertEqual(item?.displaySubtitle, "NTS 1")
        XCTAssertEqual(item?.isLiveStream, true)
    }

    // MARK: Local files

    func testCratingALocalTrackCreatesAndLinksItsRecording() throws {
        let track = Track(
            path: "/Music/Autechre/Tri Repetae/Bike.flac", relativePath: "Autechre/Tri Repetae/Bike.flac",
            title: "Bike", artist: "Autechre", albumArtist: "Autechre", album: "Tri Repetae",
            genre: "Electronic", trackNumber: 4, discNumber: 1, year: 1995, duration: 477,
            fileModified: Date(), fileSize: 1024, artworkKey: nil, scanGeneration: 1
        )
        context.insert(track)

        crate.toggle(nowPlaying: track.mediaItem())

        XCTAssertEqual(crate.count, 1)
        let item = try XCTUnwrap(crate.items().first)
        XCTAssertEqual(item.kind, .recording)
        XCTAssertEqual(item.displayTitle, "Bike")
        XCTAssertEqual(item.displaySubtitle, "Autechre")
        XCTAssertEqual(item.sourceLine, "Local Library")
        XCTAssertTrue(crate.isCrated(nowPlaying: track.mediaItem()))
    }

    func testExistingLocalCrateEntryBackfillsItsGenre() throws {
        let track = Track(
            path: "/Music/Actress/Splazsh/Hubble.flac", relativePath: "Actress/Splazsh/Hubble.flac",
            title: "Hubble", artist: "Actress", albumArtist: "Actress", album: "Splazsh",
            genre: "Electronic", trackNumber: 3, discNumber: 1, year: 2010, duration: 443,
            fileModified: Date(), fileSize: 1024, artworkKey: nil, scanGeneration: 1
        )
        context.insert(track)
        let recording = try recordings.recording(for: track)
        let legacyItem = CrateItem(recording: recording)
        context.insert(legacyItem)
        try context.save()

        XCTAssertTrue(legacyItem.genreTags.isEmpty)
        crate.backfillLocalGenres()
        XCTAssertEqual(legacyItem.genreTags, ["Electronic"])
    }

    func testCratingAMissingFileReportsRatherThanCrashing() {
        let ghost = MediaItem(
            id: "/Music/gone.flac", sourceID: Track.sourceID, kind: .track,
            title: "Gone", playbackURL: URL(fileURLWithPath: "/Music/gone.flac")
        )
        crate.toggle(nowPlaying: ghost)

        XCTAssertEqual(crate.count, 0)
        XCTAssertNotNil(crate.notice)
    }

    // MARK: Grouping

    func testItemsGroupNewestFirstByDay() throws {
        let old = try recordings.upsert(title: "Old", artistName: "A")
        let new = try recordings.upsert(title: "New", artistName: "B")

        let oldItem = crate.add(recording: old)
        oldItem.addedAt = Calendar.current.date(byAdding: .day, value: -2, to: .now)!
        let newItem = crate.add(recording: new)

        let days = crate.days()
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.first?.label, "Today")
        XCTAssertEqual(days.first?.items.first?.id, newItem.id)
        XCTAssertEqual(days.last?.items.first?.id, oldItem.id)
    }
}
