//
//  ListeningCrateTests.swift
//  IndigoTests
//
//  Keeping a track heard through a provider's own player. Crated as a
//  recording rather than as a link, because that is what it is — a piece of
//  music that happens to be reachable through YouTube today.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ListeningCrateTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var crate: CrateService!

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

    private var link: URL { URL(string: "https://www.youtube.com/watch?v=irfj8pQwhno")! }

    func testAKeptTrackBecomesARecording() throws {
        let recording = try XCTUnwrap(crate.toggle(
            listening: link, title: "Rev8617", artist: "Skee Mask", release: "Compro"
        ))

        XCTAssertEqual(recording.title, "Rev8617")
        XCTAssertEqual(recording.artistName, "Skee Mask")
        XCTAssertEqual(recording.albumTitle, "Compro")
        XCTAssertTrue(crate.isCrated(listening: link))
    }

    /// Titles on these uploads are written by whoever posted them, so the same
    /// credit recovery a radio tracklist gets applies here.
    func testAnUploadersTitleIsReadApart() throws {
        let recording = try XCTUnwrap(crate.toggle(
            listening: link, title: "Skee Mask - Rev8617", artist: nil
        ))
        XCTAssertEqual(recording.artistName, "Skee Mask")
        XCTAssertEqual(recording.title, "Rev8617")
    }

    func testKeepingIsATogglesAndDoesNotDuplicate() throws {
        _ = crate.toggle(listening: link, title: "Rev8617", artist: "Skee Mask")
        XCTAssertTrue(crate.isCrated(listening: link))

        XCTAssertNil(crate.toggle(listening: link, title: "Rev8617", artist: "Skee Mask"),
                     "Second press lets it go")
        XCTAssertFalse(crate.isCrated(listening: link))

        _ = crate.toggle(listening: link, title: "Rev8617", artist: "Skee Mask")
        let recordings = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        XCTAssertEqual(recordings.count, 1, "One recording, however often it is toggled")
    }

    /// The point of filing it as a recording: it becomes playable, diggable,
    /// and gains better sources later.
    func testAKeptTrackIsPlayableFromTheCrate() throws {
        let recording = try XCTUnwrap(crate.toggle(
            listening: link, title: "Rev8617", artist: "Skee Mask"
        ))
        let source = try XCTUnwrap(SourceResolver(context: context).best(recording))

        XCTAssertEqual(source.kind, .streamingLink)
        guard case .play(let item) = source.action else {
            return XCTFail("A kept link should play, not navigate")
        }
        XCTAssertEqual(item.embedProvider, .youtube)
        XCTAssertEqual(item.playbackURL, link)
    }

    /// Somebody's own file and somebody's radio show are both better than a
    /// video of it. The order is the whole reason the resolver exists.
    func testALinkRanksBelowTheRealThing() throws {
        let store = RecordingStore(context: context)
        let recording = try XCTUnwrap(crate.toggle(
            listening: link, title: "Rev8617", artist: "Skee Mask"
        ))
        store.note(appearance: MediaAppearance(
            providerID: "nts", showTitle: "Ben UFO", showID: "ben-ufo/1",
            heardAt: Date(), offsetSeconds: 300, isLive: false, method: .providerTracklist
        ), on: recording)

        let ordered = SourceResolver(context: context).resolve(recording)
        XCTAssertEqual(ordered.first?.kind, .broadcastAppearance,
                       "Hearing it inside the show it was played in comes first")
        XCTAssertTrue(ordered.contains { $0.kind == .streamingLink })
    }

    /// The same upload crated from a release page and from an artist page is
    /// one recording.
    func testTheSameUploadKeptTwiceIsOneRecording() throws {
        _ = crate.toggle(listening: link, title: "Rev8617", artist: "Skee Mask", release: "Compro")
        crate.toggle(recording: try XCTUnwrap(crate.recording(forListening: link)))

        let again = try XCTUnwrap(crate.toggle(
            listening: link, title: "Rev8617", artist: "Skee Mask", release: "Pool"
        ))
        XCTAssertEqual(again.albumTitle, "Compro", "What it was first filed as stands")
        XCTAssertEqual(((try? context.fetch(FetchDescriptor<Recording>())) ?? []).count, 1)
    }
}
