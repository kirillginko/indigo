//
//  UserDataInvariantsTests.swift
//  IndigoTests
//
//  The redundant fields in the synced rows cannot disagree with the parts they
//  are made of: tested on values, on a store the app wrote, and on a store the
//  migration produced.
//

import XCTest
import SwiftData
@testable import Indigo

final class UserDataInvariantsTests: XCTestCase {
    private func event(node: MusicNode) -> EventValue {
        EventValue(id: UUID(), at: Date(), nodeID: node.id, nodeKindRaw: node.kind.rawValue,
                   nodeKey: node.key, title: node.title)
    }

    // MARK: Values

    func testARowMadeFromANodeSatisfiesEveryInvariant() {
        for node in [MusicNode.artist("Skee Mask"), .label("Ilian Tape"), .station(providerID: "nts", stationID: "nts.1"),
                     .broadcast(providerID: "nts", showID: "a/b", title: "A")] {
            XCTAssertEqual(UserDataInvariants.problems(in: event(node: node)), [], node.id)
            let visit = VisitValue(id: UUID(), nodeID: node.id, kindRaw: node.kind.rawValue, visits: 1,
                                   firstVisitedAt: Date(timeIntervalSince1970: 1), lastVisitedAt: Date(timeIntervalSince1970: 2))
            XCTAssertEqual(UserDataInvariants.problems(in: visit), [], node.id)
        }
        let step = StepValue(id: UUID(), identity: DigStep.canonicalIdentity(from: "artist:a", to: "artist:b"),
                             fromNodeID: "artist:a", toNodeID: "artist:b", count: 1, lastAt: Date())
        XCTAssertEqual(UserDataInvariants.problems(in: step), [])
    }

    func testAnEventWhoseNodeIDDisagreesWithItsPartsIsCaught() {
        var bad = event(node: .artist("Skee Mask"))
        bad.nodeID = "label:skee mask"
        XCTAssertEqual(UserDataInvariants.problems(in: bad).count, 1)
        bad = event(node: .artist("Skee Mask")); bad.nodeKindRaw = "label"
        XCTAssertFalse(UserDataInvariants.problems(in: bad).isEmpty)
    }

    func testAVisitWhoseKindDisagreesWithItsNodeIsCaught() {
        let bad = VisitValue(id: UUID(), nodeID: "artist:x", kindRaw: "label", visits: 1,
                             firstVisitedAt: Date(), lastVisitedAt: Date())
        XCTAssertFalse(UserDataInvariants.problems(in: bad).isEmpty)
    }

    func testAStepWhoseIdentityDisagreesWithItsEndsIsCaught() {
        let bad = StepValue(id: UUID(), identity: "artist:a→artist:c", fromNodeID: "artist:a", toNodeID: "artist:b",
                            count: 1, lastAt: Date())
        XCTAssertFalse(UserDataInvariants.problems(in: bad).isEmpty)
    }

    func testTheCanonicalFormsAreTheOnesTheModelsWrite() {
        let node = MusicNode.artist("Skee Mask")
        XCTAssertEqual(DigVisit(node: node).nodeID, node.id)
        XCTAssertEqual(ListeningEvent(node: node, action: .played).nodeID, node.id)
        XCTAssertEqual(DigStep(from: "artist:a", to: "artist:b").identity, DigStep.canonicalIdentity(from: "artist:a", to: "artist:b"))
        XCTAssertEqual(MusicNode.kindRaw(ofID: "recording:a\u{1F}b#X"), "recording")
    }

    // MARK: A store the app wrote

    func testRowsWrittenByTheAppAreConsistentWithThemselves() throws {
        let container = try Persistence.makeSplitContainer(userData: nil, local: nil)
        let context = ModelContext(container)
        let recording = try RecordingStore(context: context).upsert(title: "Rev8617", artistName: "Skee Mask")
        let log = ListeningLog(context: context, writable: true)
        log.record(MusicNode.recording(recording), action: .played, seconds: 90)
        log.record(.station(providerID: "nts", stationID: "nts.1"), action: .played, seconds: 30)
        let history = DigHistory(context: context, writable: true)
        history.record(.artist("Skee Mask"))
        history.record(MusicNode.recording(recording), from: .artist("Skee Mask"))
        _ = CrateService(context: context, writable: true).add(recording: recording)
        try context.save()

        XCTAssertEqual(UserDataInvariants.violations(in: context).map(\.description), [])
    }

    // MARK: A store the migration made

    func testRowsTheMigrationMadeFromAnOldStoreAreConsistentWithThemselves() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserDataInvariantsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let layout = StoreLayout(directory: directory)
        try LegacyStoreFixture.make(in: layout)

        let container = try SplitMigration(layout: layout).run()

        XCTAssertEqual(UserDataInvariants.violations(in: ModelContext(container)).map(\.description), [])
    }
}
