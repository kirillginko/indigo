//
//  SourceResolverTests.swift
//  IndigoTests
//
//  The resolver's contract: local always wins, a broadcast is a fallback, and
//  "nothing to play" is a real answer rather than a crash.
//

import XCTest
import SwiftData
@testable import Indigo

final class SourceResolverTests: XCTestCase {
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

    @discardableResult
    private func makeTrack(
        path: String, title: String, artist: String,
        duration: Double = 300, isrc: String? = nil
    ) -> Track {
        let track = Track(
            path: path, relativePath: String(path.dropFirst()),
            title: title, artist: artist, albumArtist: artist, album: "Album",
            genre: "Electronic", trackNumber: 1, discNumber: 1, year: 2018,
            duration: duration, fileModified: Date(), fileSize: 1024,
            isrc: isrc, artworkKey: nil, scanGeneration: 1
        )
        context.insert(track)
        return track
    }

    // MARK: Priority

    func testLocalFileBeatsBroadcast() throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        makeTrack(path: "/Music/Rev8617.flac", title: "Rev8617", artist: "Skee Mask")
        store.link(recording, toBroadcast: "moxie/2026-08-27", providerID: "nts", offsetSeconds: 4472)

        let sources = SourceResolver(context: context).resolve(recording)

        XCTAssertGreaterThanOrEqual(sources.count, 2)
        XCTAssertEqual(sources.first?.kind, .localFile)
        XCTAssertEqual(sources.first?.label, "Local")
        XCTAssertEqual(sources.first?.detail, "FLAC")
        XCTAssertTrue(sources.first?.isPlayable == true)
    }

    func testBroadcastIsUsedWhenNothingIsOwned() throws {
        let recording = try store.upsert(title: "Theme From Q", artistName: "Objekt")
        store.link(recording, toBroadcast: "ben-ufo/2026-08-28", providerID: "nts", offsetSeconds: 3600)

        let best = try XCTUnwrap(SourceResolver(context: context).best(recording))

        XCTAssertEqual(best.kind, .broadcastAppearance)
        XCTAssertEqual(best.label, "NTS")
        guard case .openBroadcast(let page, let offset) = best.action else {
            return XCTFail("A recording inside a set should open that set")
        }
        XCTAssertEqual(page, .ntsEpisode(show: "ben-ufo", episode: "2026-08-28"))
        XCTAssertEqual(offset, 3600)
        XCTAssertFalse(best.isPlayable, "Opening a show is navigation, not playback")
    }

    /// The third branch of the spec's flow chart has to be reachable.
    func testUnknownMusicWithNoSourcesReportsUnavailable() throws {
        let unknown = try store.createUnknown(
            providerID: "nts", showID: nil,
            heardAt: Date(timeIntervalSince1970: 1_787_000_000), offsetSeconds: nil
        )
        let resolver = SourceResolver(context: context)

        XCTAssertTrue(resolver.resolve(unknown).isEmpty)
        XCTAssertNil(resolver.best(unknown))
        XCTAssertTrue(resolver.isUnavailable(unknown))
    }

    // MARK: The match ladder

    func testISRCOutranksDisagreeingText() throws {
        let recording = try store.upsert(
            title: "Rev8617", artistName: "Skee Mask", isrc: "DEUM71800123"
        )
        makeTrack(path: "/Music/wrong-name.mp3", title: "Track 03", artist: "Unknown",
                  isrc: "DEUM71800123")
        makeTrack(path: "/Music/decoy.mp3", title: "Rev8617", artist: "Skee Mask")

        let match = try XCTUnwrap(LocalFileSource(context: context).findMatch(for: recording))
        XCTAssertEqual(match.rung, .isrc)
        XCTAssertEqual(match.track.path, "/Music/wrong-name.mp3")
        XCTAssertTrue(match.rung.isExact)
    }

    /// The same title by the same artist can be an edit, a live take, or a
    /// twelve-minute remix. Duration is what separates them.
    func testDurationPicksTheRightCopy() throws {
        let recording = try store.upsert(
            title: "Rev8617", artistName: "Skee Mask", durationSeconds: 366
        )
        makeTrack(path: "/Music/extended.flac", title: "Rev8617", artist: "Skee Mask", duration: 742)
        makeTrack(path: "/Music/album.flac", title: "Rev8617", artist: "Skee Mask", duration: 364)

        let match = try XCTUnwrap(LocalFileSource(context: context).findMatch(for: recording))
        XCTAssertEqual(match.rung, .artistTitleAndDuration)
        XCTAssertEqual(match.track.path, "/Music/album.flac")
    }

    func testFuzzyTitleMatchIsTheLastRung() throws {
        let recording = try store.upsert(title: "Hubble", artistName: "Actress")
        // Filed under a compilation credit, so the artist disagrees.
        makeTrack(path: "/Music/various.mp3", title: "Hubble", artist: "Various Artists")

        let match = try XCTUnwrap(LocalFileSource(context: context).findMatch(for: recording))
        XCTAssertEqual(match.rung, .fuzzyTitle)
        XCTAssertFalse(match.rung.isExact)
    }

    /// Resolving is not free, so a hit is written back as a link.
    func testAMatchIsRememberedSoItIsFoundOnceOnly() throws {
        let recording = try store.upsert(title: "Bike", artistName: "Autechre")
        makeTrack(path: "/Music/Bike.flac", title: "Bike", artist: "Autechre")

        XCTAssertTrue(recording.sources.isEmpty)
        _ = LocalFileSource(context: context).resolvedTrack(for: recording)
        XCTAssertEqual(recording.sources.filter { $0.kind == .localFile }.count, 1)

        _ = LocalFileSource(context: context).resolvedTrack(for: recording)
        XCTAssertEqual(recording.sources.filter { $0.kind == .localFile }.count, 1,
                       "Resolving twice must not add a second link")
    }

    func testNoLocalCopyYieldsNoLocalSource() throws {
        let recording = try store.upsert(title: "Nothing I Own", artistName: "Nobody")
        makeTrack(path: "/Music/different.flac", title: "Something Else", artist: "Someone")

        XCTAssertTrue(LocalFileSource(context: context).sources(for: recording).isEmpty)
    }
}
