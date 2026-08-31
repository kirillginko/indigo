//
//  RadioReleaseTests.swift
//  IndigoTests
//
//  A track heard on the radio arrives as two strings and a timestamp. What it
//  turns out to *be* — the record, the label, the year, the sleeve — is
//  resolved separately, and these pin where that lands: on the recording
//  itself, so a tracklist row and a graph node can draw it without the track
//  having been crated first.
//

import XCTest
import SwiftData
@testable import Indigo

final class RadioReleaseTests: XCTestCase {
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
        store = nil
        context = nil
        container = nil
    }

    @discardableResult
    private func resolve(
        _ recording: Recording,
        release: String? = "Untrue",
        label: String? = "Hyperdub",
        date: String? = "2007-11-05",
        artwork: String? = "https://img.example/untrue.jpg"
    ) -> RecordingMetadata {
        let metadata = RecordingMetadata(recordingID: recording.id)
        metadata.releaseTitle = release
        metadata.labelName = label
        metadata.releaseDate = date
        metadata.artworkURLString = artwork
        context.insert(metadata)
        return metadata
    }

    // MARK: The line a row shows

    func testAResolvedTrackReadsAsRecordLabelAndYear() throws {
        let recording = try store.upsert(title: "Archangel", artistName: "Burial")
        let metadata = resolve(recording)

        XCTAssertEqual(metadata.releaseLine, "Untrue · Hyperdub · 2007")
        XCTAssertEqual(metadata.artworkURL?.absoluteString, "https://img.example/untrue.jpg")
    }

    /// Radio metadata is partial far more often than it is complete. A row
    /// with only a label should say the label, not "· Hyperdub ·".
    func testPartialCatalogueAnswersStillReadCleanly() throws {
        let recording = try store.upsert(title: "Archangel", artistName: "Burial")
        let metadata = resolve(recording, release: nil, date: nil, artwork: nil)

        XCTAssertEqual(metadata.releaseLine, "Hyperdub")
        XCTAssertNil(metadata.artworkURL)
    }

    /// Before the catalogue has answered there is nothing to say, and saying
    /// nothing is the honest state — an empty line reserved for a release
    /// reads as a missing release.
    func testAnUnresolvedTrackSaysNothingRatherThanNearlySomething() throws {
        let recording = try store.upsert(title: "Archangel", artistName: "Burial")
        let metadata = resolve(recording, release: nil, label: nil, date: nil, artwork: nil)

        XCTAssertNil(metadata.releaseLine)
        XCTAssertNil(metadata.artworkURL)
    }

    func testAnEmptyArtworkStringIsNotAURL() throws {
        let recording = try store.upsert(title: "Archangel", artistName: "Burial")
        XCTAssertNil(resolve(recording, artwork: "").artworkURL)
    }

    // MARK: Where it lands

    /// The sleeve used to live on the crate row, which meant a track had to
    /// be kept before it could be seen. It belongs to the recording.
    @MainActor
    func testTheSleeveIsReadableWithoutTheTrackEverBeingCrated() throws {
        let recording = try store.upsert(title: "Archangel", artistName: "Burial")
        resolve(recording)

        let crated = (try? context.fetch(FetchDescriptor<CrateItem>())) ?? []
        XCTAssertTrue(crated.isEmpty, "Nothing has been kept")

        let detail = DigStore(context: context).releaseDetail(for: recording)
        XCTAssertEqual(detail.line, "Untrue · Hyperdub · 2007")
        XCTAssertEqual(detail.artwork?.absoluteString, "https://img.example/untrue.jpg")
    }

    /// MusicBrainz answers one request a second. Asking it again for
    /// something already on the row is the one thing this must never do.
    @MainActor
    func testAnAlreadyAnsweredTrackIsNotAskedAgain() async throws {
        let recording = try store.upsert(title: "Archangel", artistName: "Burial")
        let seeded = resolve(recording)

        let resolved = await DigStore(context: context).resolveRelease(for: recording)

        XCTAssertIdentical(resolved, seeded)
        XCTAssertEqual(resolved?.artworkURLString, "https://img.example/untrue.jpg")
    }

    /// A RADIO list is a list of records. Nodes have to carry the sleeve or
    /// it is a list of strings.
    func testAGraphNodeCarriesTheSleeveOfWhatWasPlayed() throws {
        let recording = try store.upsert(title: "Archangel", artistName: "Burial")
        resolve(recording)
        store.note(appearance: MediaAppearance(
            providerID: "nts", stationName: "NTS 1", showTitle: "Ben UFO",
            showID: "ben-ufo/2026-08-28", heardAt: Date(), offsetSeconds: 300,
            isLive: false, method: .providerTracklist
        ), on: recording)

        let show = MusicNode.broadcast(providerID: "nts", showID: "ben-ufo/2026-08-28", title: "Ben UFO")
        let played = GraphStore(context: context).neighbors(of: show).byDestination
        let track = try XCTUnwrap(played.first { $0.node.recordingID == recording.id })

        XCTAssertEqual(track.node.artworkURL?.absoluteString, "https://img.example/untrue.jpg")
    }

    /// Meeting a node twice must fill the gap rather than lose what was known.
    func testAGraphKeepsTheSleeveWhenTheNodeIsMetAgain() throws {
        let recording = try store.upsert(title: "Archangel", artistName: "Burial")
        var graph = MusicGraph()
        graph.insert(.recording(recording, artwork: URL(string: "https://img.example/untrue.jpg")))
        graph.insert(.recording(recording))

        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertEqual(
            graph.node(MusicNode.recording(recording).id)?.artworkURL?.absoluteString,
            "https://img.example/untrue.jpg"
        )
    }

    // MARK: Credits kept as one string

    /// The bug behind both symptoms. A row imported as one line has no artist,
    /// so DIG has nothing to open — and every catalogue lookup asks after a
    /// track by that name credited to nobody, which nothing has, so it never
    /// gains a release or a sleeve either.
    func testALineKeptWholeIsReadApart() throws {
        let recording = Recording(title: "SPACE AFRIKA - MLN ft. Tony Njoku", status: .probable)
        context.insert(recording)

        XCTAssertTrue(recording.recreditFromTitle())
        XCTAssertEqual(recording.artistName, "SPACE AFRIKA")
        XCTAssertEqual(recording.title, "MLN ft. Tony Njoku")
        XCTAssertEqual(recording.matchKey, RecordingKey.match(artist: "SPACE AFRIKA", title: "MLN ft. Tony Njoku"))
    }

    func testEveryDashStationsActuallyUse() {
        for line in ["A - B", "A — B", "A – B"] {
            let credit = TrackCredit.split(line)
            XCTAssertEqual(credit?.artist, "A", line)
            XCTAssertEqual(credit?.title, "B", line)
        }
    }

    /// Guessing which dash was the credit gets it wrong more often than right,
    /// so a line with two of them is left exactly as it was written.
    func testAnAmbiguousLineIsLeftAlone() throws {
        let recording = Recording(title: "Artist - Title - Extra Mix", status: .probable)
        context.insert(recording)

        XCTAssertFalse(recording.recreditFromTitle())
        XCTAssertEqual(recording.title, "Artist - Title - Extra Mix")
        XCTAssertNil(TrackCredit.split("No separator here"))
        XCTAssertNil(TrackCredit.split(" - Title"), "Nothing on the left is not a credit")
    }

    /// A repair only ever fills a hole. A station that published proper fields
    /// must not have its track renamed because the title contains a dash.
    func testARecordingThatNamesItsArtistIsNeverRewritten() throws {
        let recording = try store.upsert(title: "Papo2oo4 - Live Set", artistName: "Papo2oo4 & YL")

        XCTAssertFalse(recording.recreditFromTitle())
        XCTAssertEqual(recording.title, "Papo2oo4 - Live Set")
        XCTAssertEqual(recording.artistName, "Papo2oo4 & YL")
    }

    /// The symptom the crate actually showed: no DIG button, because there was
    /// no artist to open.
    @MainActor
    func testRepairingACratedRowGivesItSomewhereToDigTo() throws {
        let crate = CrateService(context: context)
        let recording = Recording(title: "SPACE AFRIKA - MLN ft. Tony Njoku", status: .probable)
        context.insert(recording)
        crate.add(recording: recording)

        let dig = DigStore(context: context)
        XCTAssertNil(dig.destination(for: recording), "Nothing to open before the repair")

        XCTAssertEqual(dig.repairRadioCredits(), 1)
        XCTAssertEqual(dig.destination(for: recording), .digArtist(mbid: nil, name: "SPACE AFRIKA"))
    }

    /// Running the Crate's opening pass twice must not keep rewriting rows.
    @MainActor
    func testRepairIsIdempotent() throws {
        let crate = CrateService(context: context)
        let recording = Recording(title: "SPACE AFRIKA - MLN ft. Tony Njoku", status: .probable)
        context.insert(recording)
        crate.add(recording: recording)

        let dig = DigStore(context: context)
        XCTAssertEqual(dig.repairRadioCredits(), 1)
        XCTAssertEqual(dig.repairRadioCredits(), 0)
        XCTAssertEqual(recording.title, "MLN ft. Tony Njoku")
    }
}
