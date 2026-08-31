//
//  MusicGraphTests.swift
//  IndigoTests
//
//  Phase 3A. The graph is the thing every later mode stands on — DEEP ranks
//  over it, RADIO adds to it, TRAILS walks it — so what it promises is pinned
//  here: that nodes keep their identity, that edges keep their reasons, and
//  that a pile of weak coincidences never outranks a fact.
//

import XCTest
import SwiftData
@testable import Indigo

final class MusicGraphTests: XCTestCase {
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

    // MARK: Confidence

    /// The reason the old summed weight had to go. Six thin coincidences used
    /// to total 3.4 and outrank one shared label at 0.9 — so DIG ranked the
    /// artist it could barely justify above the one it could.
    func testManyWeakReasonsDoNotOutrankOneStrongOne() {
        let coincidences = ConfidenceMath.combined(Array(repeating: 0.3, count: 6))
        let sharedLabel = ConfidenceMath.combined([0.9])

        XCTAssertGreaterThan(sharedLabel, coincidences)
        XCTAssertLessThan(coincidences, 1, "Accumulation must never reach certainty on its own")
    }

    func testIndependentReasonsEachRemoveAShareOfTheDoubt() {
        XCTAssertEqual(ConfidenceMath.combined([0.5, 0.5]), 0.75, accuracy: 0.0001)
        XCTAssertEqual(ConfidenceMath.combined([]), 0, accuracy: 0.0001)
        XCTAssertEqual(ConfidenceMath.combined([1.0, 0.4]), 1, accuracy: 0.0001)
    }

    /// Eleven shared shows is much stronger than one and only a little
    /// stronger than eight.
    func testRepeatedEvidenceGrowsButSaturates() {
        let once = ConfidenceMath.reinforced(0.6, occurrences: 1)
        let eight = ConfidenceMath.reinforced(0.6, occurrences: 8)
        let eleven = ConfidenceMath.reinforced(0.6, occurrences: 11)
        let absurd = ConfidenceMath.reinforced(0.6, occurrences: 5_000)

        XCTAssertEqual(once, 0.6, accuracy: 0.0001)
        XCTAssertGreaterThan(eight, once)
        XCTAssertGreaterThan(eleven, eight)
        XCTAssertLessThan(eleven - eight, eight - once, "Each repeat is worth less than the last")
        XCTAssertLessThan(absurd, 1, "Volume alone cannot manufacture certainty")
    }

    func testConfidenceBands() {
        XCTAssertEqual(RelationshipConfidence.band(0.9), .high)
        XCTAssertEqual(RelationshipConfidence.band(0.6), .medium)
        XCTAssertEqual(RelationshipConfidence.band(0.2), .low)
        XCTAssertGreaterThan(RelationshipConfidence.high, RelationshipConfidence.low)
    }

    // MARK: Node identity

    func testTheSameArtistSpelledDifferentlyIsOneNode() {
        XCTAssertEqual(MusicNode.artist("Skee Mask").id, MusicNode.artist("skee  mask").id)
        XCTAssertNotEqual(MusicNode.artist("Stenny").id, MusicNode.artist("Skee Mask").id)
    }

    /// A title is a guess at identity and an ID is identity. Two different
    /// white labels both called "Untitled" must not become one record.
    func testUntitledReleasesDoNotCollapseIntoEachOther() {
        let first = MusicNode.release("Untitled", discogsID: 1001)
        let second = MusicNode.release("Untitled", discogsID: 2002)
        XCTAssertNotEqual(first.id, second.id)

        let unresolved = MusicNode.release("Untitled")
        XCTAssertNotEqual(unresolved.id, first.id)
    }

    func testCatalogNumbersSurviveHowPeopleWriteThem() {
        XCTAssertEqual(MusicNode.catalogNumber("IT 001").id, MusicNode.catalogNumber("it-001").id)
        XCTAssertEqual(CatalogNumber.split("ITLP09")?.prefix, "ITLP")
        XCTAssertEqual(CatalogNumber.split("ITLP09")?.number, 9)
        XCTAssertNil(CatalogNumber.split("WHITELABEL"), "No number is not a catalogue position")
        XCTAssertNil(CatalogNumber.split("12345"), "No prefix is not a label's mark")
    }

    /// The point of the whole model: music nobody could name is a node, not a
    /// gap where a node should have been.
    func testUnnamedMusicIsAFirstClassNode() {
        let unknown = Recording(status: .unknown, unknownCode: "8F42A")
        let node = MusicNode.recording(unknown)

        XCTAssertEqual(node.kind, .unknownRecording)
        XCTAssertTrue(node.isUnidentified)
        XCTAssertEqual(node.title, "UNKNOWN/8F42A")
        XCTAssertEqual(node.handle, "8F42A")

        let named = Recording(title: "Rev8617", artistName: "Skee Mask", status: .identified)
        XCTAssertEqual(MusicNode.recording(named).kind, .recording)
        XCTAssertFalse(MusicNode.recording(named).isUnidentified)
    }

    func testNodesKnowWhereTheyOpen() {
        XCTAssertEqual(
            MusicNode.artist("Skee Mask", mbid: "abc").destination,
            .digArtist(mbid: "abc", name: "Skee Mask")
        )
        XCTAssertEqual(MusicNode.release("Untrue", discogsID: 42).destination,
                       .digRelease(id: 42, title: "Untrue"))
        // A style is a lens, not a place. Saying so is better than a page
        // that opens onto nothing.
        XCTAssertNil(MusicNode.style("dub techno").destination)
    }

    // MARK: Edges

    func testAnEdgeSeenTwiceIsBetterEvidenceNotASecondReason() {
        var set = EdgeSet()
        let edge = MusicEdge(
            from: .artist("Skee Mask"), to: .artist("Stenny"), kind: .sharedBroadcast,
            source: .radio, reason: "Played in the same show", confidence: 0.6
        )
        set.insert(edge)
        set.insert(edge)

        XCTAssertEqual(set.all.count, 1)
        XCTAssertEqual(set.all.first?.occurrences, 2)
        XCTAssertGreaterThan(set.all.first?.weight ?? 0, 0.6)
    }

    func testDifferentReasonsForTheSamePairBothSurvive() {
        var set = EdgeSet()
        set.insert(MusicEdge(from: .artist("Skee Mask"), to: .artist("Stenny"),
                             kind: .sharedLabel, source: .discogs,
                             reason: "Both release on Ilian Tape", confidence: 0.8))
        set.insert(MusicEdge(from: .artist("Skee Mask"), to: .artist("Stenny"),
                             kind: .sharedBroadcast, source: .radio,
                             reason: "Played in 4 of the same shows", confidence: 0.7))

        let destinations = set.byDestination
        XCTAssertEqual(destinations.count, 1)
        XCTAssertEqual(destinations.first?.edges.count, 2)
        XCTAssertGreaterThan(destinations.first?.confidence ?? 0, 0.8,
                             "Two independent reasons are worth more than either alone")
    }

    // MARK: Graph

    /// Sharing a label is not something one artist does to another, so a
    /// connection written in one direction has to be walkable from the other.
    func testConnectionsAreWalkableFromEitherEnd() {
        var graph = MusicGraph()
        let skeeMask = MusicNode.artist("Skee Mask")
        let stenny = MusicNode.artist("Stenny")
        graph.connect(from: skeeMask, to: stenny, reason: Relationship(
            kind: .sharedLabel, source: .discogs,
            detail: "Both release on Ilian Tape", confidence: 0.85
        ))

        XCTAssertEqual(graph.connections(from: skeeMask).map(\.to.title), ["Stenny"])
        XCTAssertEqual(graph.connections(from: stenny).map(\.to.title), ["Skee Mask"])
        XCTAssertEqual(graph.connectionCount, 1, "One fact, counted once")
    }

    /// A name often arrives before its identifier does. Meeting the node
    /// again must fill the gap rather than overwrite what was already known.
    func testMeetingANodeAgainAccumulatesWhatIsKnown() {
        var graph = MusicGraph()
        graph.insert(.artist("Skee Mask"))
        graph.insert(.artist("Skee Mask", mbid: "mb-1"))

        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertEqual(graph.node(MusicNode.artist("Skee Mask").id)?.mbid, "mb-1")
    }

    func testEveryConnectionCanSayWhy() throws {
        var graph = MusicGraph()
        let subject = MusicNode.artist("Skee Mask")
        graph.connect(from: subject, to: .artist("Stenny"), reason: Relationship(
            kind: .sharedBroadcast, source: .radio,
            detail: "Played in 11 of the same shows", confidence: 0.82
        ))
        graph.connect(from: subject, to: .artist("Stenny"), reason: Relationship(
            kind: .sharedLabel, source: .discogs,
            detail: "Both release on Ilian Tape", confidence: 0.8
        ))

        let connection = try XCTUnwrap(graph.connections(from: subject).first)
        let why = try XCTUnwrap(connection.why)
        XCTAssertEqual(why.headline, "Played in 11 of the same shows")
        XCTAssertEqual(why.supporting.first?.text, "Both release on Ilian Tape")
        XCTAssertEqual(why.confidence, .high)
        XCTAssertEqual(why.summary(), "Played in 11 of the same shows · Both release on Ilian Tape")
    }

    func testGraphsFromDifferentEnginesFoldIntoOne() {
        var radio = MusicGraph()
        radio.connect(from: .artist("Skee Mask"), to: .artist("Ploy"), reason: Relationship(
            kind: .sharedBroadcast, source: .radio, detail: "Same show", confidence: 0.7
        ))
        var catalogue = MusicGraph()
        catalogue.connect(from: .artist("Skee Mask"), to: .label("Ilian Tape"), reason: Relationship(
            kind: .sharedLabel, source: .discogs, detail: "Releases on Ilian Tape", confidence: 0.9
        ))

        radio.absorb(catalogue)
        let reached = radio.connections(from: .artist("Skee Mask"))
        XCTAssertEqual(Set(reached.map(\.to.kind)), [.artist, .label])
        XCTAssertEqual(radio.connections(from: .artist("Skee Mask"), kind: .label).first?.to.title,
                       "Ilian Tape")
    }
}
