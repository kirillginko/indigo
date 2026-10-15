//
//  DigRecommenderTests.swift
//  IndigoTests
//

import XCTest
@testable import Indigo

final class DigRecommenderTests: XCTestCase {
    private let origin = MusicNode.artist("Eric Kloss", discogsID: 1)

    private func edge(_ name: String, _ id: Int, _ kind: RelationshipKind, _ reason: String, occurrences: Int = 1) -> MusicEdge {
        MusicEdge(from: origin, to: .artist(name, discogsID: id), kind: kind, source: .discogs,
                  reason: reason, confidence: kind.baseConfidence, occurrences: occurrences)
    }

    func testTheReleaseAndRoleAreReadFromTheRoutesOwnWords() {
        XCTAssertEqual(DigRecommender.releaseTitle(in: "Bass on Essence"), "Essence")
        XCTAssertEqual(DigRecommender.releaseTitle(in: "Drums on Live on Mars (A1, B2)"), "Live on Mars")
        XCTAssertEqual(DigRecommender.releaseTitle(in: "Made Weightless Animals together"), "Weightless Animals")
        XCTAssertEqual(DigRecommender.releaseTitle(in: "Appears on Thug :: Remixed"), "Thug :: Remixed")
        XCTAssertEqual(DigRecommender.releaseTitle(in: "Producer on Navigator Travelogue (1 to 4, 6 to 19)"), "Navigator Travelogue")
        XCTAssertEqual(DigRecommender.releaseTitle(in: "Written-By on Don't Spoil The Tension (A1 to B5)"), "Don't Spoil The Tension")
        XCTAssertEqual(DigRecommender.releaseTitle(in: "Remix on Thug :: Remixed (2.17)"), "Thug :: Remixed")
        XCTAssertEqual(DigRecommender.releaseTitle(in: "Vocals on Songs (Live At The Roundhouse)"), "Songs (Live At The Roundhouse)",
                       "A parenthesis that is not tracks is the title's")
        XCTAssertEqual(DigRecommender.releaseTitle(in: "Voice on Stunde Null (II)"), "Stunde Null (II)")
        XCTAssertNil(DigRecommender.releaseTitle(in: "Credited together"))
        XCTAssertEqual(DigRecommender.role(in: "Piano, Electric Piano on Essence"), "Piano, Electric Piano")
        XCTAssertNil(DigRecommender.role(in: "Made Essence together"))
    }

    func testPlayersOnTheRecordComeFirstWithTheRecordToHear() throws {
        let video = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=abc"))
        var lookups = DigRecommender.Lookups()
        lookups.release = { $0 == "Essence" ? (id: 77, year: 1974) : nil }
        lookups.recordings = { $0 == 77 ? [(url: video, title: "Eric Kloss - Essence")] : [] }
        lookups.onward = { _ in 5 }
        let cards = DigRecommender.recommend(from: [
            edge("Buster Williams", 2, .personnel, "Bass on Essence"),
            edge("Some Mastering", 3, .personnel, "Mastered By on Essence"),
            edge("A Labelmate", 4, .sharedLabel, "Releases on Muse Records"),
            edge("Somebody Similar", 5, .sharedStyle, "Shared sound: Post Bop")
        ], origin: origin, lookups: lookups, listener: .init())

        XCTAssertEqual(cards.map(\.artist.title), ["Buster Williams", "A Labelmate", "Somebody Similar"])
        let bass = try XCTUnwrap(cards.first)
        XCTAssertEqual(bass.relationship, .playedOn)
        XCTAssertEqual(bass.evidence, .init(title: "Essence", year: 1974, releaseID: 77))
        XCTAssertEqual(bass.listen, .recording(video, title: "Eric Kloss - Essence"))
        XCTAssertNil(cards[1].evidence, "A label is a neighbourhood: no record is claimed for it")
        XCTAssertEqual(cards[2].relationship, .soundsRelated, "Resemblance says it is resemblance")
        XCTAssertFalse(cards.contains { $0.artist.title == "Some Mastering" }, "Technical credits are never cards")
    }

    func testAJourneyNeverReturnsToWhereItHasBeen() {
        let cards = DigRecommender.recommend(from: [
            edge("Buster Williams", 2, .personnel, "Bass on Essence"),
            edge("Ron Krasinski", 6, .personnel, "Drums on Essence")
        ], origin: origin, lookups: .init(), listener: .init(visited: [MusicNode.artist("Buster Williams", discogsID: 2).id]))
        XCTAssertEqual(cards.map(\.artist.title), ["Ron Krasinski"])
    }

    func testOneSleeveDoesNotFillTheCards() {
        let edges = (0..<5).map { edge("Player \($0)", 10 + $0, .personnel, "Drums on One Record") }
            + [edge("Bandmate", 20, .collaborator, "Made Another Record together")]
        let cards = DigRecommender.recommend(from: edges, origin: origin, lookups: .init(), listener: .init())
        XCTAssertEqual(cards.filter { $0.evidence?.title == "One Record" }.count, 2)
        XCTAssertTrue(cards.contains { $0.artist.title == "Bandmate" })
    }

    func testACardIsAlwaysAVerifiedEntryAndNeverTheSamePersonAgain() {
        let unverified = MusicEdge(from: origin, to: .artist("Deliquecircular"), kind: .collaborator, source: .discogs,
                                   reason: "Credited together", confidence: 0.9, occurrences: 1)
        let cards = DigRecommender.recommend(from: [
            unverified,
            edge("Alan Ginsberg", 7, .personnel, "Words By on Iron Horse"),
            edge("Siobhan Fahey", 8, .personnel, "Vocals on Iron Horse")
        ], origin: origin, lookups: .init(), listener: .init(visitedNames: ["Allen Ginsberg"]))
        XCTAssertEqual(cards.map(\.artist.title), ["Siobhan Fahey"])
    }

    func testARouteThatNamesTheRecordBeatsOneThatDoesNot() {
        let cards = DigRecommender.recommend(from: [
            edge("Abstraxion", 9, .collaborator, "Credited together"),
            edge("Vic Juris", 10, .personnel, "Guitar on Bodies' Warmth")
        ], origin: origin, lookups: .init(), listener: .init())
        XCTAssertEqual(cards.first?.artist.title, "Vic Juris")
    }

    func testAHubLabelIsNotAReason() {
        let hub = (0..<20).map { edge("Session \($0)", 100 + $0, .sharedLabel, "Both release on Daytrotter") }
        let small = edge("Labelmate", 200, .sharedLabel, "Both release on Small Label")
        let cards = DigRecommender.recommend(from: hub + [small], origin: origin, lookups: .init(), listener: .init())
        XCTAssertEqual(cards.map(\.artist.title), ["Labelmate"])
    }
}
