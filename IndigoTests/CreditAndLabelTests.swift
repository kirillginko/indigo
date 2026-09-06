//
//  CreditAndLabelTests.swift
//  IndigoTests
//
//  Three things reported together, all of them the same mistake in different
//  clothes: taking a catalogue's filing convention for a fact about music.
//
//  A duo written "Andrew Cyrille - Anthony Braxton" is two people and was
//  being filed as a third who does not exist. A self-released record is filed
//  under whoever made it, which made artists their own record labels. And a
//  record with no label is filed under words like "Self-Titled", which made
//  two strangers labelmates.
//

import XCTest
import SwiftData
@testable import Indigo

final class CreditAndLabelTests: XCTestCase {

    // MARK: Two people are two people

    func testACreditJoinedByADashIsTwoArtists() {
        XCTAssertEqual(
            ArtistName.split("Andrew Cyrille - Anthony Braxton"),
            ["Andrew Cyrille", "Anthony Braxton"]
        )
        XCTAssertEqual(
            RecordingKey.creditedArtists("ANDREW CYRILLE - ANTHONY BRAXTON"),
            ["andrew cyrille", "anthony braxton"]
        )
    }

    func testACreditJoinedByASlashIsTwoArtists() {
        XCTAssertEqual(ArtistName.split("Kelly Moran / Prurient"), ["Kelly Moran", "Prurient"])
    }

    func testAHyphenInsideANameBelongsToTheName() {
        // Spaced separators only. Jean-Michel Jarre is one person.
        XCTAssertEqual(ArtistName.split("Jean-Michel Jarre"), ["Jean-Michel Jarre"])
        XCTAssertEqual(RecordingKey.creditedArtists("Jean-Michel Jarre"), ["jean michel jarre"])
    }

    func testTheSamePersonNamedTwiceInACreditIsNamedOnce() {
        XCTAssertEqual(ArtistName.split("Anthony Braxton & anthony braxton"), ["Anthony Braxton"])
    }

    func testAPlaceholderInACreditIsNotAPerson() {
        XCTAssertEqual(ArtistName.split("Various - Anthony Braxton"), ["Anthony Braxton"])
    }

    func testSplittingKeepsTheSpellingSomebodyWrote() {
        // `creditedArtists` answers in normalised form, which comparisons
        // want. A page has to show a name a person actually typed.
        XCTAssertEqual(ArtistName.split("ANDREW CYRILLE").first, "ANDREW CYRILLE")
        XCTAssertEqual(RecordingKey.creditedArtists("ANDREW CYRILLE").first, "andrew cyrille")
    }

    // MARK: An artist is not a label

    func testAnArtistIsNotTheirOwnImprint() {
        XCTAssertTrue(LabelName.isOwnName("Dean Blunt", artist: "Dean Blunt"))
        XCTAssertTrue(LabelName.isOwnName("DEAN BLUNT", artist: "Dean Blunt"))
        // Filed under one member of a duo.
        XCTAssertTrue(LabelName.isOwnName("Anthony Braxton", artist: "Andrew Cyrille - Anthony Braxton"))
    }

    func testARealImprintIsNotTheArtist() {
        XCTAssertFalse(LabelName.isOwnName("Hyperdub", artist: "Burial"))
        XCTAssertFalse(LabelName.isOwnName(nil, artist: "Burial"))
        XCTAssertFalse(LabelName.isOwnName("Hyperdub", artist: nil))
        XCTAssertFalse(LabelName.isOwnName("", artist: ""))
    }

    // MARK: The absence of a label, spelled a dozen ways

    func testWordsThatMeanNoLabelAreNotLabels() {
        for name in ["Self-Titled", "self titled", "Self Released", "Self-Release",
                     "Independent", "Independently Released", "DIY", "Private Press",
                     "Own Label", "Bootleg", "No Label", "White Label"] {
            XCTAssertFalse(LabelName.isRealLabel(name), name)
        }
    }

    func testRealImprintsStillSurviveTheWiderList() {
        for name in ["Hyperdub", "World Music", "Rough Trade", "Ilian Tape",
                     "Warp Records", "Label", "On-U Sound", "Music From Memory"] {
            XCTAssertTrue(LabelName.isRealLabel(name), name)
        }
    }

    // MARK: What was written down under the old rules

    func testAStoredAnswerIsRetiredWhenTheRulesChange() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)

        let node = MusicNode.artist("Dean Blunt")
        // An answer written by an older build, which believed things the app
        // no longer believes.
        context.insert(GraphSnapshot(nodeID: node.id, builderVersion: GraphStore.builderVersion - 1))
        let stale = MusicEdge(
            from: node, to: .label("World Music (8)"), kind: .sharedLabel,
            source: .discogs, reason: "Releases on World Music (8)", confidence: 0.8
        )
        context.insert(StoredEdge(from: node, edge: stale))
        try context.save()

        // A sentence no code left in the app could produce must not survive
        // because it was once written down.
        let edges = GraphStore(context: context).neighbors(of: node).all
        XCTAssertFalse(edges.contains { $0.reason.contains("World Music (8)") })
    }

    func testAStoredAnswerFromThisVersionIsKept() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)

        let node = MusicNode.artist("Dean Blunt")
        context.insert(GraphSnapshot(nodeID: node.id, builderVersion: GraphStore.builderVersion))
        let edge = MusicEdge(
            from: node, to: .label("Hyperdub"), kind: .sharedLabel,
            source: .discogs, reason: "Releases on Hyperdub", confidence: 0.8
        )
        context.insert(StoredEdge(from: node, edge: edge))
        try context.save()

        let edges = GraphStore(context: context).neighbors(of: node).all
        XCTAssertTrue(edges.contains { $0.to.title == "Hyperdub" })
    }
}
