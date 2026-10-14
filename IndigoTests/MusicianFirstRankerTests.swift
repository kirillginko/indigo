//
//  MusicianFirstRankerTests.swift
//  IndigoTests
//
//  One obscure jazz record crated today, on top of weeks of electronic
//  music: today's interest leads, and the collection is still there.
//

import XCTest
@testable import Indigo

final class MusicianFirstRankerTests: XCTestCase {
    private let asOf = Date(timeIntervalSince1970: 1_790_000_000)
    private func daysAgo(_ days: Double) -> Date { asOf.addingTimeInterval(-days * 86_400) }

    /// Forty electronic records kept over two months and played, one jazz
    /// record crated today.
    private func listener() -> PersonalInputs {
        var crate: [PersonalInputs.Kept] = []
        var met: [PersonalInputs.Met] = []
        for index in 0..<40 {
            let artist = "Electronic \(index % 20)"
            let node = MusicNode.release("Record \(index)", discogsID: 1_000 + index)
            let added = daysAgo(20 + Double(index))
            crate.append(.init(node: node, addedAt: added, genreTags: ["electronic"],
                               tasteArtistKeys: [RecordingKey.normalizeArtist(artist)],
                               sceneArtistKey: RecordingKey.normalizeArtist(artist)))
            met.append(.init(node: node, weight: 1.5 + Double(index % 5), lastAt: added))
        }
        let jazz = MusicNode.release("Obscure Jazz Record", discogsID: 9_999)
        crate.append(.init(node: jazz, addedAt: daysAgo(0.1), genreTags: ["jazz"],
                           tasteArtistKeys: ["obscure trio"], sceneArtistKey: "obscure trio"))
        met.append(.init(node: jazz, weight: 1.5, lastAt: daysAgo(0.1)))
        return PersonalInputs(crate: crate.sorted(by: PersonalInputs.newestFirst), plays: [],
                              met: met.sorted { $0.node.id < $1.node.id }, artistPlays: [:], haunts: [])
    }

    func testTodaysRecordLeadsAndTheCollectionStays() {
        let origins = MusicianFirstRanker.startingPoints(listener(), asOf: asOf)
        XCTAssertEqual(origins.count, 12)
        XCTAssertEqual(origins.first?.node.title, "Obscure Jazz Record", "What they are into today comes first")
        XCTAssertEqual(origins.first?.half, .now)
        let overTime = origins.filter { $0.half == .overTime }
        XCTAssertGreaterThanOrEqual(overTime.count, 8, "Most of the walk still starts from the collection")
        XCTAssertTrue(overTime.allSatisfy { $0.node.title.hasPrefix("Record") })
    }

    func testOneArtistCannotFillTheCollectionHalf() {
        var personal = listener()
        // Twenty more records by one artist, played a lot.
        for index in 0..<20 {
            let node = MusicNode.release("Prolific \(index)", discogsID: 5_000 + index)
            personal.crate.append(.init(node: node, addedAt: daysAgo(30), genreTags: ["electronic"],
                                        tasteArtistKeys: ["prolific"], sceneArtistKey: "prolific"))
            personal.met.append(.init(node: node, weight: 20, lastAt: daysAgo(30)))
        }
        let origins = MusicianFirstRanker.startingPoints(personal, asOf: asOf)
        XCTAssertLessThanOrEqual(origins.filter { $0.node.title.hasPrefix("Prolific") }.count, MusicianFirstRanker.perArtist)
    }

    func testTheSameRowsGiveTheSameStartingPoints() {
        let one = MusicianFirstRanker.startingPoints(listener(), asOf: asOf)
        var shuffled = listener()
        shuffled.met.reverse()
        shuffled.crate.reverse()
        XCTAssertEqual(one, MusicianFirstRanker.startingPoints(shuffled, asOf: asOf))
    }

    func testAPlayerOutranksALabelmateAndADeadEndIsDemoted() {
        let personal = listener()
        let jazz = MusicNode.release("Obscure Jazz Record", discogsID: 9_999)
        let bassist = MusicNode.artist("The Bassist", discogsID: 1)
        let labelmate = MusicNode.artist("A Labelmate", discogsID: 2)
        let deadEnd = MusicNode.artist("The Drummer", discogsID: 3)
        let nodes = [jazz, bassist, labelmate, deadEnd]
        func edge(_ to: Int, _ kind: RelationshipKind, _ reason: String) -> KnownEdge {
            KnownEdge(from: 0, to: to, kind: kind, source: RelationshipSource.discogs.rawValue,
                      reason: reason, confidence: kind.baseConfidence, occurrences: 1)
        }
        let knowledge = KnowledgeSnapshot(
            shared: SharedKnowledge(
                nodes: nodes,
                neighbourhoods: [Neighbourhood(origin: 0, edges: [
                    edge(1, .personnel, "Double Bass on Obscure Jazz Record"),
                    edge(2, .sharedLabel, "Releases on Some Label"),
                    edge(3, .personnel, "Drums on Obscure Jazz Record")
                ])],
                shows: [], artistTags: [:], scenes: nil),
            deviceLocal: .empty)
        let ranked = MusicianFirstRanker.suggestions(
            personal: personal, knowledge: knowledge, taste: TasteProfile.empty, asOf: asOf,
            onward: [bassist.id: 5, deadEnd.id: 0, labelmate.id: 5])
        XCTAssertEqual(ranked.map(\.node.title), ["The Bassist", "The Drummer", "A Labelmate"])
        let drummer = ranked.first { $0.node.title == "The Drummer" }
        let bass = ranked.first { $0.node.title == "The Bassist" }
        XCTAssertLessThan(drummer?.score ?? 1, bass?.score ?? 0, "A route with nowhere further to go ranks lower")
    }
}
