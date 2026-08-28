//
//  RecordingModelTests.swift
//  IndigoTests
//
//  The canonical model is what every later phase reads, so identity — when two
//  claims are the same recording and when they aren't — is pinned down here.
//

import XCTest
import SwiftData
@testable import Indigo

final class RecordingModelTests: XCTestCase {
    private var container: ModelContainer!
    private var store: RecordingStore!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        store = RecordingStore(context: ModelContext(container))
    }

    override func tearDown() {
        store = nil
        container = nil
    }

    private func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try store.context.fetchCount(FetchDescriptor<T>())
    }

    // MARK: Normalisation

    func testTitleNormalisationIgnoresCatalogueCruft() {
        XCTAssertEqual(RecordingKey.normalizeTitle("Rev8617 (Original Mix)"), "rev8617")
        XCTAssertEqual(RecordingKey.normalizeTitle("Rev8617"), "rev8617")
        XCTAssertEqual(RecordingKey.normalizeTitle("Théme From Q [Remastered]"), "theme from q")
        XCTAssertEqual(RecordingKey.normalizeTitle("Hubble - Radio Edit"), "hubble",
                       "A trailing edit marker folds whether it was bracketed or dashed")
        XCTAssertEqual(RecordingKey.normalizeTitle("Radio Edit"), "radio edit",
                       "A title that is only the marker keeps it — stripping would leave nothing")
    }

    func testArtistNormalisationKeepsThePrimaryCredit() {
        XCTAssertEqual(RecordingKey.normalizeArtist("Skee Mask"), "skee mask")
        XCTAssertEqual(RecordingKey.normalizeArtist("Objekt feat. Dawn Richard"), "objekt")
        XCTAssertEqual(RecordingKey.normalizeArtist("Zenker Brothers & Andrea"), "zenker brothers")
    }

    /// Two unidentified recordings are not the same music just because neither
    /// of them has a name. This is the bug that would silently collapse every
    /// white label in the crate into one row.
    func testEmptyMetadataYieldsNoMatchKey() {
        XCTAssertEqual(RecordingKey.match(artist: nil, title: nil), "")
        XCTAssertEqual(RecordingKey.match(artist: "Skee Mask", title: nil), "")
        XCTAssertFalse(RecordingKey.match(artist: nil, title: "Rev8617").isEmpty,
                       "A title alone is still an identity claim")
    }

    // MARK: Dedup

    func testSameMusicFromTwoCataloguesIsOneRecording() throws {
        let first = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let second = try store.upsert(title: "Rev8617 (Original Mix)", artistName: "Skee Mask", albumTitle: "Compro")

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try count(Recording.self), 1)
        XCTAssertEqual(second.albumTitle, "Compro", "The second claim enriches the first")
    }

    func testISRCBeatsDisagreeingText() throws {
        let first = try store.upsert(title: "Rev8617", artistName: "Skee Mask", isrc: "DEUM71800123")
        let second = try store.upsert(title: "REV 8617", artistName: "Skee-Mask", isrc: "DEUM71800123")

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try count(Recording.self), 1)
    }

    func testDifferentMusicStaysSeparate() throws {
        _ = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        _ = try store.upsert(title: "Hubble", artistName: "Actress")
        XCTAssertEqual(try count(Recording.self), 2)
    }

    // MARK: Identification states

    func testIdentityOnlyEverGetsFirmer() throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask", status: .identified)
        recording.apply(status: .probable)
        XCTAssertEqual(recording.identificationStatus, .identified, "A weaker claim must not demote a match")

        let guess = try store.upsert(title: "Theme From Q", artistName: "Objekt", status: .probable)
        guess.apply(status: .identified)
        XCTAssertEqual(guess.identificationStatus, .identified)
    }

    // MARK: Unknown music

    func testUnknownCodeIsStableForTheSameMoment() throws {
        let heardAt = Date(timeIntervalSince1970: 1_787_000_000)
        let first = try store.createUnknown(providerID: "nts", showID: "moxie/2026-08-27",
                                            heardAt: heardAt, offsetSeconds: 4472)
        let again = try store.createUnknown(providerID: "nts", showID: "moxie/2026-08-27",
                                            heardAt: heardAt, offsetSeconds: 4472)

        XCTAssertEqual(first.id, again.id, "Re-running identification must not mint a second unknown")
        XCTAssertEqual(try count(Recording.self), 1)
        XCTAssertEqual(first.displayTitle, "UNKNOWN/\(first.unknownCode ?? "")")
        XCTAssertEqual(first.unknownCode?.count, 5)
    }

    func testDifferentMomentsAreDifferentUnknowns() throws {
        let heardAt = Date(timeIntervalSince1970: 1_787_000_000)
        let first = try store.createUnknown(providerID: "nts", showID: "moxie/2026-08-27",
                                            heardAt: heardAt, offsetSeconds: 4472)
        let later = try store.createUnknown(providerID: "nts", showID: "moxie/2026-08-27",
                                            heardAt: heardAt.addingTimeInterval(600), offsetSeconds: 5072)

        XCTAssertNotEqual(first.id, later.id)
        XCTAssertNotEqual(first.unknownCode, later.unknownCode)
        XCTAssertEqual(try count(Recording.self), 2)
    }

    /// The payoff for keeping unknowns: when a white label finally gets a name,
    /// the fact that it was played months earlier has to survive.
    func testMergingAnUnknownKeepsItsProvenance() throws {
        let heardAt = Date(timeIntervalSince1970: 1_787_000_000)
        let unknown = try store.createUnknown(providerID: "nts", showID: "ben-ufo/2026-01-14",
                                              heardAt: heardAt, offsetSeconds: 4903)
        store.note(
            appearance: MediaAppearance(
                providerID: "nts", stationID: "nts.1", stationName: "NTS 1",
                showTitle: "Ben UFO", showID: "ben-ufo/2026-01-14",
                heardAt: heardAt, offsetSeconds: 4903, isLive: true, method: .none
            ),
            on: unknown
        )

        let named = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        store.merge(unknown, into: named)

        XCTAssertEqual(try count(Recording.self), 1)
        XCTAssertEqual(named.appearances.count, 1)
        XCTAssertEqual(named.appearances.first?.showTitle, "Ben UFO")
        XCTAssertEqual(named.firstAppearance?.offsetLabel, "01:21:43")
    }

    // MARK: Appearances

    /// Live radio re-detects the same track every few seconds. The crate must
    /// show one appearance, not twenty.
    func testRepeatedDetectionsCollapseIntoOneAppearance() throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let start = Date(timeIntervalSince1970: 1_787_000_000)

        for step in 0..<5 {
            store.note(
                appearance: MediaAppearance(
                    providerID: "nts", showTitle: "Moxie", showID: "moxie/2026-08-27",
                    heardAt: start.addingTimeInterval(Double(step) * 23),
                    isLive: true, confidence: 0.7 + Double(step) * 0.05, method: .acoustic
                ),
                on: recording
            )
        }

        XCTAssertEqual(recording.appearances.count, 1)
        let appearance = try XCTUnwrap(recording.appearances.first)
        XCTAssertEqual(appearance.endedAt, start.addingTimeInterval(92))
        XCTAssertEqual(appearance.confidence ?? 0, 0.9, accuracy: 0.001, "Keeps the strongest reading")
    }

    func testASeparateBroadcastIsASeparateAppearance() throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let start = Date(timeIntervalSince1970: 1_787_000_000)

        store.note(appearance: MediaAppearance(providerID: "nts", showID: "moxie/2026-08-27",
                                               heardAt: start, isLive: true, method: .acoustic), on: recording)
        store.note(appearance: MediaAppearance(providerID: "nts", showID: "ben-ufo/2026-08-28",
                                               heardAt: start.addingTimeInterval(30), isLive: true,
                                               method: .acoustic), on: recording)

        XCTAssertEqual(recording.appearances.count, 2, "Same music, two different shows")
    }

    func testProvenanceReadsAsTheSpecRendersIt() {
        let appearance = MediaAppearance(
            providerID: "nts", stationID: "nts.1", stationName: "NTS 1",
            showTitle: "Moxie", showID: "moxie/2026-08-27",
            heardAt: Date(timeIntervalSince1970: 1_787_000_000),
            offsetSeconds: 4472, isLive: true, confidence: 0.94, method: .acoustic
        )
        XCTAssertEqual(appearance.sourceLine, "NTS 1 / Moxie")
        XCTAssertEqual(appearance.offsetLabel, "01:14:32")
        XCTAssertEqual(appearance.method.label, "Acoustic match")
    }

    // MARK: Local library

    func testLocalTrackMapsToOneRecordingAndIsReused() throws {
        let track = Track(
            path: "/Music/Autechre/Tri Repetae/Bike.flac", relativePath: "Autechre/Tri Repetae/Bike.flac",
            title: "Bike", artist: "Autechre", albumArtist: "Autechre", album: "Tri Repetae",
            genre: "Electronic", trackNumber: 4, discNumber: 1, year: 1995, duration: 477,
            fileModified: Date(), fileSize: 1024, artworkKey: nil, scanGeneration: 1
        )
        store.context.insert(track)

        let first = try store.recording(for: track)
        let again = try store.recording(for: track)

        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(try count(Recording.self), 1)
        XCTAssertEqual(first.sources.count, 1)
        XCTAssertEqual(first.sources.first?.kind, .localFile)
        XCTAssertEqual(first.sources.first?.identifier, track.path)
    }

    /// A radio discovery you already own must not become a second recording.
    func testRadioDiscoveryFoldsIntoTheOwnedCopy() throws {
        let track = Track(
            path: "/Music/Skee Mask/Compro/Rev8617.flac", relativePath: "Skee Mask/Compro/Rev8617.flac",
            title: "Rev8617", artist: "Skee Mask", albumArtist: "Skee Mask", album: "Compro",
            genre: "Electronic", trackNumber: 3, discNumber: 1, year: 2018, duration: 366,
            fileModified: Date(), fileSize: 2048, artworkKey: nil, scanGeneration: 1
        )
        store.context.insert(track)
        let owned = try store.recording(for: track)

        let heard = try store.upsert(title: "Rev8617", artistName: "Skee Mask", status: .identified)

        XCTAssertEqual(owned.id, heard.id)
        XCTAssertEqual(try count(Recording.self), 1)
        XCTAssertTrue(heard.sources.contains { $0.kind == .localFile })
    }

    func testLinkingIsIdempotent() throws {
        let recording = try store.upsert(title: "Hubble", artistName: "Actress")
        store.link(recording, toLocalFile: "/Music/Actress/Hubble.flac")
        store.link(recording, toLocalFile: "/Music/Actress/Hubble.flac")
        store.link(recording, toBroadcast: "moxie/2026-08-27", providerID: "nts", offsetSeconds: 183)
        store.link(recording, toBroadcast: "moxie/2026-08-27", providerID: "nts", offsetSeconds: 183)

        XCTAssertEqual(recording.sources.count, 2)
    }
}
