//
//  RecordingIdentityTests.swift
//  IndigoTests
//
//  Step 3.1. No two recordings in a store may answer to the same identity.
//  The audit of a real store found four that did: an old aggregate recording
//  ("Unreleased" by one artist, merged from every show) had been coded from its
//  first appearance, which is the same moment as one of the placeholders beside
//  it, so both were `key#code`.
//

import XCTest
import SwiftData
@testable import Indigo

final class RecordingIdentityTests: XCTestCase {
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

    private let show = "100-elements/100-elements-25th-march-2026"
    private let aired = Date(timeIntervalSince1970: 1_774_371_600)

    private func appearance(_ recording: Recording, offset: Double) {
        let appearance = MediaAppearance(
            providerID: "nts", stationName: "NTS", showTitle: "100 Elements", showID: show,
            heardAt: aired.addingTimeInterval(offset), offsetSeconds: offset,
            isLive: false, method: .providerTracklist)
        context.insert(appearance)
        appearance.recording = recording
    }

    /// The aggregate an older version made: one identified recording holding
    /// every appearance of the key.
    private func aggregate(offsets: [Double]) -> Recording {
        let rec = Recording(title: "Unreleased", artistName: "Papo2oo4", status: .identified)
        context.insert(rec)
        for offset in offsets { appearance(rec, offset: offset) }
        return rec
    }

    /// A placeholder made the way the radio engine makes one now.
    private func placeholder(offset: Double) -> Recording {
        let rec = Recording(
            title: "Unreleased", artistName: "Papo2oo4", status: .probable,
            unknownCode: RecordingKey.unknownCode(
                providerID: "nts", showID: show,
                heardAt: aired.addingTimeInterval(offset), offsetSeconds: offset))
        context.insert(rec)
        appearance(rec, offset: offset)
        return rec
    }

    // MARK: The identity function

    func testAnIdentityIsBuiltAndReadOnlyHere() {
        XCTAssertEqual(RecordingIdentity(matchKey: "a b", unknownCode: nil).key, "a b")
        XCTAssertEqual(RecordingIdentity(matchKey: "a b", unknownCode: "EAE1B").key, "a b#EAE1B")
        XCTAssertEqual(RecordingIdentity(unnamedCode: "8F42A").key, "8F42A")
        XCTAssertTrue(RecordingIdentity(matchKey: "", unknownCode: nil).isEmpty)
        XCTAssertTrue(RecordingIdentity(matchKey: "", unknownCode: "").isEmpty, "an empty code is no code")
    }

    func testAnIdentityReadsBackWhatItWrote() throws {
        for identity in [
            RecordingIdentity(matchKey: "boards of canadaaquarius", unknownCode: nil),
            RecordingIdentity(matchKey: "papo2oo4unreleased", unknownCode: "EAE1B")
        ] {
            XCTAssertEqual(RecordingIdentity(key: identity.key), identity)
        }
        XCTAssertNil(RecordingIdentity(key: ""))
    }

    func testAMatchKeyNeverContainsTheSeparator() {
        for title in ["Track #1", "#", "a#b#c", "Unreleased (#7)"] {
            XCTAssertFalse(RecordingKey.match(artist: "X#Y", title: title).contains("#"))
        }
    }

    func testANodeNamesTheSameIdentityAsItsRecording() throws {
        let named = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let node = MusicNode.recording(named)
        XCTAssertEqual(RecordingIdentity(node: node), RecordingIdentity(named))

        let unnamed = try store.createUnknown(
            providerID: "nts", showID: "x/y", heardAt: aired, offsetSeconds: 60)
        XCTAssertEqual(RecordingIdentity(node: MusicNode.recording(unnamed)), RecordingIdentity(unnamed))
        XCTAssertNil(RecordingIdentity(node: .artist("Skee Mask")))
    }

    // MARK: The collision found in the real store

    func testAnAggregateCodedFromItsFirstAppearanceCollidesWithTheSameMomentsPlaceholder() throws {
        let aggregate = aggregate(offsets: [8, 278, 904, 2542])
        let atEight = placeholder(offset: 8)
        _ = placeholder(offset: 278)
        // What the first version of the repair did to the aggregate.
        aggregate.unknownCode = atEight.unknownCode
        XCTAssertEqual(store.identityCollisions().count, 1, "the bug, reproduced")

        let result = store.repairIdentities()

        XCTAssertEqual(result.cleared, 1)
        XCTAssertNil(aggregate.unknownCode, "an identified recording stays key-only")
        XCTAssertNotNil(atEight.unknownCode, "the placeholder keeps the code its moment gave it")
        XCTAssertTrue(store.identityCollisions().isEmpty)
    }

    func testRepairingIsRepeatable() throws {
        let aggregate = aggregate(offsets: [8, 278])
        aggregate.unknownCode = placeholder(offset: 8).unknownCode
        store.repairIdentities()
        let again = store.repairIdentities()
        XCTAssertEqual(again.cleared, 0)
        XCTAssertEqual(again.assigned, 0)
    }

    func testAnAggregateAndItsPlaceholdersAreNeverGivenTheSameCode() throws {
        let aggregate = aggregate(offsets: [8, 278, 904])
        let twins = [placeholder(offset: 8), placeholder(offset: 278), placeholder(offset: 904)]
        for twin in twins { twin.unknownCode = nil }

        store.repairIdentities()

        XCTAssertNil(aggregate.unknownCode)
        XCTAssertEqual(Set(twins.compactMap(\.unknownCode)).count, 3)
        XCTAssertTrue(store.identityCollisions().isEmpty)
    }

    // MARK: The invariant, over a whole store

    func testNoTwoRecordingsInAStoreShareAnIdentity() throws {
        let aggregate = aggregate(offsets: [8, 278, 904])
        aggregate.unknownCode = RecordingKey.unknownCode(
            providerID: "nts", showID: show, heardAt: aired.addingTimeInterval(8), offsetSeconds: 8)
        _ = placeholder(offset: 8); _ = placeholder(offset: 278); _ = placeholder(offset: 904)
        // Same key, no appearance to take a code from.
        for _ in 0..<2 {
            let bare = Recording(title: "Untitled", artistName: "Somebody", status: .probable)
            context.insert(bare)
        }
        // And the ordinary ones.
        _ = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        _ = try store.upsert(title: "Aquarius", artistName: "Boards of Canada")
        _ = try store.createUnknown(providerID: "nts", showID: "a/b", heardAt: aired, offsetSeconds: 5)
        _ = try store.createUnknown(providerID: "nts", showID: "a/b", heardAt: aired, offsetSeconds: 500)
        let local = try store.upsert(title: "Bike", artistName: "Autechre")
        store.link(local, toLocalFile: "/Music/Autechre/Bike.flac")

        store.repairIdentities()

        XCTAssertTrue(store.identityCollisions().isEmpty,
                      "\(store.identityCollisions().keys.sorted())")
    }

    // MARK: Nothing later puts two recordings on one identity

    func testApplyingToAPlaceholderKeepsItsCodeEvenWhenItBecomesIdentified() throws {
        let aggregate = aggregate(offsets: [8])
        let twin = placeholder(offset: 8)
        let code = try XCTUnwrap(twin.unknownCode)

        twin.apply(albumTitle: "Compro", status: .identified)

        XCTAssertEqual(twin.unknownCode, code)
        XCTAssertNil(aggregate.unknownCode)
        XCTAssertTrue(store.identityCollisions().isEmpty)
    }

    func testNamingMusicNobodyNamedStillEndsItsCode() throws {
        let unnamed = try store.createUnknown(
            providerID: "nts", showID: "a/b", heardAt: aired, offsetSeconds: 5)
        XCTAssertNotNil(unnamed.unknownCode)

        unnamed.apply(title: "Rev8617", artistName: "Skee Mask", status: .identified)

        XCTAssertNil(unnamed.unknownCode)
        XCTAssertFalse(unnamed.matchKey.isEmpty)
    }

    func testAnUpsertDoesNotHijackAPlaceholder() throws {
        let twin = placeholder(offset: 8)
        let before = twin.identificationStatus

        let made = try store.upsert(title: "Unreleased", artistName: "Papo2oo4")

        XCTAssertNotEqual(made.id, twin.id)
        XCTAssertNil(made.unknownCode)
        XCTAssertEqual(twin.identificationStatus, before)
        XCTAssertTrue(store.identityCollisions().isEmpty)
    }

    // MARK: What resolves, deterministically

    func testTheCratedPlaceholderResolvesToItselfWhicheverWayTheStoreWasBuilt() throws {
        for aggregateFirst in [true, false] {
            let local = try ModelContainer(
                for: Persistence.schema,
                configurations: ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true))
            let ctx = ModelContext(local)
            let rs = RecordingStore(context: ctx)

            func make(_ status: IdentificationStatus, code: String?) -> Recording {
                let rec = Recording(title: "Unreleased", artistName: "Papo2oo4", status: status, unknownCode: code)
                ctx.insert(rec)
                return rec
            }
            let wrong = aggregateFirst ? make(.identified, code: nil) : nil
            let placeholder = make(.probable, code: "EAE1B")
            let late = aggregateFirst ? nil : make(.identified, code: nil)
            _ = (wrong, late)
            rs.repairIdentities()

            let crate = CrateService(context: ctx)
            let item = try XCTUnwrap(crate.add(recording: placeholder))

            XCTAssertEqual(CrateRecordings(context: ctx).recording(for: item)?.id, placeholder.id)
            XCTAssertEqual(CrateRecordings(context: ctx).crateItem(for: placeholder)?.id, item.id)
            let aggregate = try XCTUnwrap([wrong, late].compactMap { $0 }.first)
            XCTAssertNil(crate.item(for: aggregate), "the key-only recording was not crated")
            XCTAssertFalse(crate.contains(recording: aggregate))
        }
    }

    func testAVisitsRecordingHasAnIdentityNoOtherRecordingHas() throws {
        let aggregate = aggregate(offsets: [8, 278])
        let visited = placeholder(offset: 8)
        // The old repair coded the aggregate from the same moment.
        aggregate.unknownCode = visited.unknownCode
        XCTAssertEqual(store.identityCollisions().count, 1)
        store.repairIdentities()

        // The visit kept a recording id and the key as its node id.
        let visit = DigVisit(node: MusicNode(
            kind: .recording, key: aggregate.matchKey, title: "Unreleased"))
        visit.legacyRecordingID = visited.id
        context.insert(visit)

        let resolved = try XCTUnwrap(store.recording(id: try XCTUnwrap(visit.legacyRecordingID)))
        let identity = RecordingIdentity(resolved)
        let sharing = (try context.fetch(FetchDescriptor<Recording>()))
            .filter { RecordingIdentity($0) == identity }
        XCTAssertEqual(sharing.count, 1)
        XCTAssertNotEqual(identity, RecordingIdentity(aggregate))
    }
}
