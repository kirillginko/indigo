//
//  ContributorRoleTests.swift
//  IndigoTests
//
//  The contributor taxonomy, and For You recommending people for what they
//  played, wrote or produced -- never only for engineering somebody's record.
//

import XCTest
import SwiftData
@testable import Indigo

final class ContributorRoleTests: XCTestCase {
    // MARK: Roles

    func testPlayersSingersWritersAndBandsAreMusical() {
        for role in ["Bass", "Double Bass", "Drums", "Piano", "Vocals", "Vocals [Featuring]", "Featuring",
                     "Tenor Saxophone", "Conductor", "Directed By", "Musical Director", "Concertmaster",
                     "Synthesizer", "Electronics", "Tape", "Tape Loops", "Field Recording", "Performer",
                     "Written-By", "Composed By", "Music By", "Lyrics By", "Arranged By", "Orchestrated By",
                     "Score", "Guitar [Session]", "MC"] {
            XCTAssertEqual(ContributorRole.of(credit: role), .musical, role)
        }
    }

    func testProducersRemixersAndDJsAreCreativeAndNeverTechnical() {
        for role in ["Producer", "Co-producer", "Additional Production", "Remix", "Remixed By", "Re-edit",
                     "DJ Mix", "Mixed By [DJ Mix]", "Programmed By", "Drum Programming", "Beats", "Turntables",
                     "Sampler", "Sound Designer"] {
            XCTAssertEqual(ContributorRole.of(credit: role), .creative, role)
        }
    }

    func testEngineeringSleevesAndPaperworkAreTechnical() {
        for role in ["Engineer", "Engineer [Assistant]", "Recorded By", "Recorded By [Field Recordings]",
                     "Mixed By", "Mix", "Mixing Engineer", "Mastered By", "Remastered By", "Pre-Mastered By",
                     "Lacquer Cut By", "Cut By", "DMM", "Edited By", "Transferred By", "Restoration", "Tape Op",
                     "Programmed By [Technical]", "Executive-Producer", "Producer [Executive]",
                     "Recording Supervisor", "Coordinator", "A&R", "Management", "Compiled By",
                     "Art Direction, Graphic Design", "Design", "Artwork", "Photography By", "Liner Notes",
                     "Video Director", "Layout", "Interviewer"] {
            XCTAssertEqual(ContributorRole.of(credit: role), .technical, role)
        }
    }

    /// Somebody credited with several jobs is reached through the best one.
    func testTheStrongestJobWins() {
        XCTAssertEqual(ContributorRole.of(credit: "Bass, Engineer"), .musical)
        XCTAssertEqual(ContributorRole.of(credit: "Mixed By, Producer"), .creative)
        XCTAssertEqual(ContributorRole.of(credit: "Written-By, Mixed By"), .musical)
        XCTAssertEqual(ContributorRole.of(credit: "Mixed By, Mastered By"), .technical)
        XCTAssertEqual(ContributorRole.of(credit: "Producer [Additional, Co-producer], Engineer"), .creative)
        XCTAssertNil(ContributorRole.of(credit: nil))
        XCTAssertNil(ContributorRole.of(credit: " "))
    }

    // MARK: Relationships

    private func edge(_ kind: RelationshipKind, _ reason: String) -> MusicEdge {
        MusicEdge(from: .artist("Anika"), to: .artist("Somebody"), kind: kind, source: .discogs,
                  reason: reason, confidence: kind.baseConfidence)
    }

    func testARelationshipIsClassifiedByTheJobItStates() {
        // A mix credit is filed as a producer edge by the graph's older
        // sorting; the stated job is what decides.
        XCTAssertEqual(ContributorRole.of(edge: edge(.producer, "Mixed By on Abyss")), .technical)
        XCTAssertEqual(ContributorRole.of(edge: edge(.personnel, "Mastered By on Pool (A1, B2)")), .technical)
        XCTAssertEqual(ContributorRole.of(edge: edge(.collaborator, "Mixed By, Mastered By on Pool")), .technical)
        XCTAssertEqual(ContributorRole.of(edge: edge(.producer, "Co-producer on Lucre")), .creative)
        XCTAssertEqual(ContributorRole.of(edge: edge(.personnel, "Bass on Now (A1)")), .musical)
        // Named as the record's artists: musical.
        XCTAssertEqual(ContributorRole.of(edge: edge(.collaborator, "Credited together")), .musical)
        XCTAssertEqual(ContributorRole.of(edge: edge(.collaborator, "Made Pool together")), .musical)
        XCTAssertEqual(ContributorRole.of(edge: edge(.sameRelease, "Appears on Pool")), .musical)
        XCTAssertEqual(ContributorRole.of(edge: edge(.aliasOrProject, "Member of Hype Williams")), .musical)
        // Not a credit between people at all.
        XCTAssertNil(ContributorRole.of(edge: edge(.sharedLabel, "Both release on Stroom")))
        XCTAssertNil(ContributorRole.of(edge: edge(.playedInShow, "Played on NTS")))
        XCTAssertTrue(ContributorRole.canRecommend(edge(.sharedLabel, "Both release on Stroom")))
        XCTAssertFalse(ContributorRole.canRecommend(edge(.producer, "Mixed By on Abyss")))
    }

    // MARK: For You

    private let asOf = Date(timeIntervalSince1970: 1_790_000_100)

    private func offers(_ edges: [MusicEdge], origin: MusicNode) -> [ExploreSuggestion] {
        let kept = PersonalInputs.Kept(node: origin, addedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                       genreTags: ["ambient"], tasteArtistKeys: [origin.key], sceneArtistKey: origin.key)
        let personal = PersonalInputs(crate: [kept], plays: [], met: [], artistPlays: [:], haunts: [])
        var nodes: [MusicNode] = [origin]
        func index(_ node: MusicNode) -> Int {
            if let found = nodes.firstIndex(of: node) { return found }
            nodes.append(node)
            return nodes.count - 1
        }
        let stated = edges.map { edge in
            KnownEdge(from: index(edge.from), to: index(edge.to), kind: edge.kind,
                               source: edge.source.rawValue, reason: edge.reason,
                               confidence: edge.confidence, occurrences: edge.occurrences)
        }
        var knowledge = KnowledgeSnapshot.empty
        knowledge.shared.nodes = nodes
        knowledge.shared.neighbourhoods = [Neighbourhood(origin: 0, edges: stated)]
        let found = ExploreRanker.offers(personal: personal, knowledge: knowledge, asOf: asOf)
        return found.next + found.shows + found.artists
    }

    private func credit(_ origin: MusicNode, _ name: String, _ kind: RelationshipKind, _ reason: String) -> MusicEdge {
        MusicEdge(from: origin, to: .artist(name), kind: kind, source: .discogs, reason: reason,
                  confidence: kind.baseConfidence)
    }

    /// The four For You recommended on one real history, each reached only
    /// by a mix credit; and the players and producers beside them.
    func testForYouNoLongerRecommendsSomebodyOnlyForMixingARecord() {
        let record = MusicNode.release("Abyss", discogsID: 1)
        let found = offers([
            credit(record, "Mix Engineer", .producer, "Mixed By on Abyss"),
            credit(record, "Mastering House", .personnel, "Mastered By on Abyss (A1)"),
            credit(record, "Session Drummer", .personnel, "Drums on Abyss"),
            credit(record, "Co Producer", .producer, "Co-producer on Abyss"),
            credit(record, "Sleeve Person", .personnel, "Compiled By on Abyss"),
        ], origin: record)
        let names = Set(found.map(\.node.title))
        XCTAssertEqual(names, ["Session Drummer", "Co Producer"])
    }

    /// The relationship, not the person: an engineer who also played on a
    /// record the listener keeps is recommended as the player.
    func testAnEngineerWhoAlsoPlayedIsRecommendedForPlaying() {
        let record = MusicNode.release("Now", discogsID: 2)
        let found = offers([
            credit(record, "Atom", .producer, "Mixed By on Now"),
            credit(record, "Atom", .personnel, "Synthesizer on Now (B1)"),
        ], origin: record)
        XCTAssertEqual(found.map(\.node.title), ["Atom"])
        XCTAssertEqual(found.first?.reason, "Synthesizer on Now (B1)")
    }

    /// A label or a show is not a credit, and an engineer reached through
    /// one is reached as anybody else would be.
    func testOtherRoutesAreUntouched() {
        let artist = MusicNode.artist("Anika")
        let found = offers([
            credit(artist, "Labelmate", .sharedLabel, "Both release on Stroom"),
            credit(artist, "Bandmate", .collaborator, "Credited together"),
        ], origin: artist)
        XCTAssertEqual(Set(found.map(\.node.title)), ["Labelmate", "Bandmate"])
    }

    /// The same inputs, the same answer, on every device.
    func testItIsAPureFunctionOfItsInputs() {
        let record = MusicNode.release("Abyss", discogsID: 1)
        let edges = [credit(record, "A", .producer, "Mixed By, Producer on Abyss"),
                     credit(record, "B", .personnel, "Engineer [Assistant], Vocals on Abyss"),
                     credit(record, "C", .personnel, "Recorded By on Abyss")]
        let first = offers(edges, origin: record)
        let second = offers(edges.reversed(), origin: record)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.score), second.map(\.score))
        XCTAssertEqual(Set(first.map(\.node.title)), ["A", "B"])
    }
}
