//
//  CrateSnapshotTests.swift
//  IndigoTests
//
//  Step 3 of the iCloud plan. A crate row keeps what it is on its own fields,
//  so that it is the same on every device; each device finds its own
//  `Recording` for it. What is pinned here is that nothing a row used to say
//  through its `Recording` is lost by that, and that a row from another device
//  still plays.
//

import XCTest
import SwiftData
@testable import Indigo

final class CrateSnapshotTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private func recording(
        _ title: String, _ artist: String, album: String? = nil,
        status: IdentificationStatus = .identified
    ) throws -> Recording {
        try RecordingStore(context: context).upsert(
            title: title, artistName: artist, albumTitle: album, status: status)
    }

    private func link(_ recording: Recording, _ url: String, provider: String = "youtube") {
        let source = RecordingSource(kind: .streamingLink, identifier: url, providerID: provider)
        context.insert(source)
        source.recording = recording
    }

    private func heard(_ recording: Recording, provider: String = "nts", station: String? = "NTS 1",
                       show: String? = "Moxie", showID: String? = "nts.episode.moxie/ep1",
                       offset: Double? = 4903) {
        let appearance = MediaAppearance(
            providerID: provider, stationName: station, showTitle: show, showID: showID,
            offsetSeconds: offset, isLive: false, method: .providerTracklist)
        context.insert(appearance)
        appearance.recording = recording
    }

    // MARK: What a row keeps

    func testARowKeepsWhatItsRecordingSaid() throws {
        let rec = try recording("Rev8617", "Skee Mask", album: "Compro")
        link(rec, "https://www.youtube.com/watch?v=abc")
        heard(rec)

        let item = CrateItem(snapshot: CrateSnapshot.capture(rec))

        XCTAssertEqual(item.matchKey, rec.matchKey)
        XCTAssertEqual(item.displayTitle, rec.displayTitle)
        XCTAssertEqual(item.displaySubtitle, rec.displayArtist)
        XCTAssertEqual(item.albumTitle, "Compro")
        XCTAssertEqual(item.statusLabel, "Match")
        XCTAssertEqual(item.playbackURLString, "https://www.youtube.com/watch?v=abc")
        XCTAssertEqual(item.embedProviderRaw, "youtube")
    }

    func testTheSourceLineReadsTheSameAsItDidFromTheAppearance() throws {
        let rec = try recording("Rev8617", "Skee Mask")
        heard(rec)
        let appearance = try XCTUnwrap(rec.firstAppearance)
        let before = appearance.sourceLine + " @ " + (appearance.offsetLabel ?? "")

        let item = CrateItem(snapshot: CrateSnapshot.capture(rec))

        XCTAssertEqual(item.sourceLine, before)
        XCTAssertEqual(item.sourceLine, "NTS 1 / Moxie @ 01:21:43")
    }

    func testAFileFromTheLibraryReadsAsLocalLibrary() throws {
        let rec = try recording("Bike", "Autechre")
        let file = RecordingSource(kind: .localFile, identifier: "/Music/Autechre/Bike.flac")
        context.insert(file)
        file.recording = rec

        let item = CrateItem(snapshot: CrateSnapshot.capture(rec))

        XCTAssertEqual(item.sourceLine, "Local Library")
        XCTAssertNil(item.playbackURLString, "a path on this Mac is not something to keep")
    }

    func testMusicNobodyNamedIsIdentifiedByItsCode() throws {
        let rec = try RecordingStore(context: context).createUnknown(
            providerID: "nts", showID: "nts.episode.x/y", heardAt: Date(), offsetSeconds: 120)

        let item = CrateItem(snapshot: CrateSnapshot.capture(rec))

        XCTAssertTrue(item.matchKey.isEmpty)
        XCTAssertEqual(item.recordingIdentity, rec.unknownCode)
        XCTAssertEqual(item.displayTitle, rec.displayTitle)
        XCTAssertEqual(item.node?.kind, .unknownRecording)
        XCTAssertEqual(item.statusLabel, "Unknown")
    }

    // MARK: Finding the row, and the recording

    func testTheCrateFindsARowByKeyNotByAnObject() throws {
        let rec = try recording("Rev8617", "Skee Mask")
        let crate = CrateService(context: context)
        let item = try XCTUnwrap(crate.add(recording: rec))

        XCTAssertTrue(crate.contains(recording: rec))
        XCTAssertEqual(crate.item(for: rec)?.id, item.id)
    }

    func testCratingTheSameThingTwiceIsOneRow() throws {
        let rec = try recording("Rev8617", "Skee Mask")
        let crate = CrateService(context: context)
        crate.add(recording: rec)
        crate.add(recording: rec)
        XCTAssertEqual(crate.count, 1)
    }

    func testAnotherDevicesRowResolvesToThisDevicesOwnRecording() throws {
        let rec = try recording("Rev8617", "Skee Mask", album: "Compro")
        link(rec, "https://www.youtube.com/watch?v=abc")
        let item = CrateItem(snapshot: CrateSnapshot.capture(rec))
        context.insert(item)

        // This device has never seen the recording.
        context.delete(rec)
        try context.save()
        let resolver = CrateRecordings(context: context)
        XCTAssertNil(resolver.recording(for: item))

        let made = try XCTUnwrap(resolver.resolve(item))

        XCTAssertEqual(made.matchKey, item.matchKey)
        XCTAssertEqual(made.title, "Rev8617")
        XCTAssertEqual(made.albumTitle, "Compro")
        XCTAssertEqual(made.sources.filter { $0.kind == .streamingLink }.count, 1)
        XCTAssertEqual(resolver.resolve(item)?.id, made.id, "resolving again finds it, it does not make a second")
    }

    // MARK: Playing a row with no recording behind it

    func testARowFromAnotherDeviceStillPlaysItsLink() throws {
        let rec = try recording("Rev8617", "Skee Mask")
        link(rec, "https://www.youtube.com/watch?v=abc")
        let item = CrateItem(snapshot: CrateSnapshot.capture(rec))
        context.insert(item)
        context.delete(rec)
        try context.save()

        let source = SourceResolver(context: context).best(item)

        guard case .play(let media)? = source?.action else {
            return XCTFail("expected a playable source, got \(String(describing: source))")
        }
        XCTAssertEqual(media.playbackURL.absoluteString, "https://www.youtube.com/watch?v=abc")
        XCTAssertEqual(media.title, "Rev8617")
    }

    // MARK: A recording row is not a broadcast row

    func testATrackHeardInAShowDoesNotMakeThatShowCrated() throws {
        let rec = try recording("Rev8617", "Skee Mask")
        heard(rec, provider: "nts", showID: "nts.episode.moxie/ep1")
        let crate = CrateService(context: context)
        crate.add(recording: rec)

        XCTAssertNil(crate.item(forBroadcast: "nts.episode.moxie/ep1", providerID: "nts"))
        XCTAssertFalse(crate.contains(broadcast: "nts.episode.moxie/ep1", providerID: "nts"))

        crate.add(
            broadcast: "nts.episode.moxie/ep1", providerID: "nts", title: "Moxie", subtitle: nil,
            artworkURL: nil, playbackURL: nil, embedProvider: nil)
        XCTAssertEqual(crate.count, 2, "the show is crated as well as the track, not instead of it")
    }

    // MARK: The backfill


    // MARK: Placeholders share a key and are still different recordings

    /// Three "Unreleased" tracks by one artist, made before placeholders had
    /// codes: one match key, three recordings.
    private func legacyPlaceholders() -> [Recording] {
        (0..<3).map { index in
            let rec = Recording(title: "Unreleased", artistName: "Papo2oo4", status: .probable)
            context.insert(rec)
            heard(rec, showID: "nts.episode.papo/mix", offset: Double(index) * 900)
            return rec
        }
    }

    func testPlaceholdersWithOneKeyAreGivenCodesThatTellThemApart() throws {
        let twins = legacyPlaceholders()
        XCTAssertEqual(Set(twins.map(\.matchKey)).count, 1)

        XCTAssertEqual(RecordingStore(context: context).assignPlaceholderCodes(), 3)

        XCTAssertEqual(Set(twins.compactMap(\.unknownCode)).count, 3)
        XCTAssertEqual(RecordingStore(context: context).assignPlaceholderCodes(), 0, "once")
    }

    func testCratingOnePlaceholderDoesNotCrateItsTwins() throws {
        let twins = legacyPlaceholders()
        let crate = CrateService(context: context)

        crate.add(recording: twins[1])

        XCTAssertTrue(crate.contains(recording: twins[1]))
        XCTAssertFalse(crate.contains(recording: twins[0]))
        XCTAssertFalse(crate.contains(recording: twins[2]))
        XCTAssertEqual(crate.item(for: twins[1])?.id, crate.items().first?.id)
        XCTAssertNil(crate.item(for: twins[0]))
    }

}
