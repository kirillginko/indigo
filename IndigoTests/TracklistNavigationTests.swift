//
//  TracklistNavigationTests.swift
//  IndigoTests
//
//  A tracklist is the point at which somebody wants to dig, so every line on it
//  has to lead somewhere. It did not: the title and the credit were both plain
//  text, and ingesting a tracklist creates an artist for every name no
//  catalogue has — so the rows opened nothing, and the artists radio had just
//  invented had no door into them at all.
//
//  Nothing here draws a view. What is pinned is the thing a row needs before it
//  can be a link: a recording to open, and a credit worth linking.
//

import XCTest
import SwiftData
@testable import Indigo

final class TracklistNavigationTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    /// The episode from the screenshot that started this: a Villalobos
    /// variation credited to two artists, a one-word alias, and an entry with
    /// no artist at all.
    private func episode() -> NTSEpisodeDetail {
        NTSEpisodeDetail(
            summary: NTSEpisodeSummary(
                showAlias: "moxie", episodeAlias: "2026-09-03",
                name: "Moxie", summary: nil, location: nil,
                genres: [], moods: [], artworkURL: nil,
                broadcastAt: Date(timeIntervalSince1970: 1_788_000_000), isPublished: true
            ),
            tracklist: [
                NTSTracklistEntry(id: "1", artist: "Valentina Goncharova", title: "Zen Garden", offset: 0),
                NTSTracklistEntry(id: "2", artist: "Persona", title: "Monte", offset: 260),
                NTSTracklistEntry(id: "3", artist: "Tolouse Low Trax", title: "Gang 6", offset: 373),
                NTSTracklistEntry(id: "4", artist: "Goat (jp), Ricardo Villalobos",
                                  title: "Orin (Ricardo Villalobos Variation)", offset: 486),
                NTSTracklistEntry(id: "5", artist: "Unknown Artist", title: "Untitled", offset: 600)
            ],
            audio: []
        )
    }

    /// The precondition for the title being a link. Without a recording behind
    /// the row there is nothing to open, and the row stays text.
    func testEveryTracklistEntryResolvesToSomethingOpenable() throws {
        let detail = episode()
        let engine = RadioNeighborhoodEngine(context: context)
        engine.ingest(detail)

        for entry in detail.tracklist {
            let recording = engine.recording(for: entry, in: detail)
            XCTAssertNotNil(recording, "\(entry.title) has no recording, so its row cannot be opened")
        }
    }

    /// Including the one nobody identified. An unnamed record is still a
    /// record, and losing it is the failure this app exists to avoid.
    func testAnUnidentifiedTrackIsStillOpenable() throws {
        let detail = episode()
        let engine = RadioNeighborhoodEngine(context: context)
        engine.ingest(detail)

        let unknown = try XCTUnwrap(detail.tracklist.first { $0.artist == "Unknown Artist" })
        let recording = try XCTUnwrap(engine.recording(for: unknown, in: detail))

        XCTAssertNil(recording.displayArtist, "A placeholder credit is not an artist")
        XCTAssertTrue(recording.displayTitle.isEmpty == false)
    }

    /// Which credits become links. A placeholder must not, or every episode
    /// where a selector did not say would point at one imaginary artist.
    func testOnlyRealCreditsBecomeLinks() {
        XCTAssertTrue(ArtistName.isRealArtist("Valentina Goncharova"))
        XCTAssertTrue(ArtistName.isRealArtist("Tolouse Low Trax"))
        XCTAssertTrue(ArtistName.isRealArtist("Goat (jp), Ricardo Villalobos"))

        XCTAssertFalse(ArtistName.isRealArtist("Unknown Artist"))
        XCTAssertFalse(ArtistName.isRealArtist(""))
        XCTAssertFalse(ArtistName.isRealArtist(nil))
    }

    /// Re-rendering must not multiply the rows behind the links. A tracklist
    /// redraws on every hover, and the resolver runs per render.
    func testReRenderingATracklistDoesNotMultiplyItsRecordings() throws {
        let detail = episode()
        let engine = RadioNeighborhoodEngine(context: context)

        engine.ingest(detail)
        let first = try context.fetch(FetchDescriptor<Recording>()).count
        engine.ingest(detail)
        engine.ingest(detail)
        let after = try context.fetch(FetchDescriptor<Recording>()).count

        XCTAssertEqual(first, after, "A redraw created new recordings behind the rows")
        XCTAssertEqual(after, detail.tracklist.count)
    }
}
