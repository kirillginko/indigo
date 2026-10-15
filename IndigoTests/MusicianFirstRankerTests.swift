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

// MARK: - A new crate item, and what leads on

final class MusicianFirstBalanceTests: XCTestCase {
    private let asOf = Date(timeIntervalSince1970: 1_790_000_000)
    private func daysAgo(_ days: Double) -> Date { asOf.addingTimeInterval(-days * 86_400) }

    /// Twelve kept artists over two months, each with two collaborators.
    private func world(adding jazz: Bool) -> (PersonalInputs, KnowledgeSnapshot) {
        var crate: [PersonalInputs.Kept] = []
        var met: [PersonalInputs.Met] = []
        var nodes: [MusicNode] = []
        var neighbourhoods: [Neighbourhood] = []
        func origin(_ node: MusicNode, _ friends: [(String, RelationshipKind, String)], added: Date, tag: String) {
            crate.append(.init(node: node, addedAt: added, genreTags: [tag], tasteArtistKeys: [node.key], sceneArtistKey: node.key))
            met.append(.init(node: node, weight: 1.5, lastAt: added))
            let at = nodes.count
            nodes.append(node)
            var edges: [KnownEdge] = []
            for (name, kind, reason) in friends {
                nodes.append(.artist(name, discogsID: 10_000 + nodes.count))
                edges.append(KnownEdge(from: at, to: nodes.count - 1, kind: kind, source: RelationshipSource.discogs.rawValue,
                                       reason: reason, confidence: kind.baseConfidence, occurrences: 1))
            }
            neighbourhoods.append(Neighbourhood(origin: at, edges: edges))
        }
        for index in 0..<12 {
            origin(.artist("Electronic \(index)", discogsID: 100 + index),
                   [("Partner \(index)a", .collaborator, "Credited together"), ("Partner \(index)b", .collaborator, "Credited together")],
                   added: daysAgo(15 + Double(index) * 4), tag: "electronic")
        }
        if jazz {
            origin(.release("Obscure Jazz Record", discogsID: 9_999),
                   [("The Pianist", .personnel, "Piano on Obscure Jazz Record"), ("The Drummer", .personnel, "Drums on Obscure Jazz Record")],
                   added: asOf, tag: "jazz")
        }
        let personal = PersonalInputs(crate: crate.sorted(by: PersonalInputs.newestFirst), plays: [],
                                      met: met.sorted { $0.node.id < $1.node.id }, artistPlays: [:], haunts: [])
        let knowledge = KnowledgeSnapshot(
            shared: SharedKnowledge(nodes: nodes, neighbourhoods: neighbourhoods, shows: [], artistTags: [:], scenes: nil),
            deviceLocal: .empty)
        return (personal, knowledge)
    }

    func testANewCrateItemChangesSomeOffersWithoutReplacingTheRest() {
        let (before, beforeKnowledge) = world(adding: false)
        let (after, afterKnowledge) = world(adding: true)
        let old = MusicianFirstRanker.suggestions(personal: before, knowledge: beforeKnowledge, taste: .empty, asOf: asOf)
        let new = MusicianFirstRanker.suggestions(personal: after, knowledge: afterKnowledge, taste: .empty, asOf: asOf)
        XCTAssertEqual(old.count, 12)
        XCTAssertTrue(new.contains { $0.node.title == "The Pianist" }, "Today's record leads somewhere at once")
        let kept = Set(old.map(\.id)).intersection(new.map(\.id)).count
        XCTAssertGreaterThanOrEqual(kept, 8, "Most of what was offered for the collection is still offered")
        XCTAssertLessThan(kept, 12, "And something did change")
    }

    func testABundleSaysHowManyMusiciansLeadOnAndWhoIsOnlyTechnical() throws {
        let json = #"""
        {"artist":{"discogsID":1,"name":"Someone"},"collaborators":[
          {"artist":{"discogsID":2,"name":"Bandmate"},"how":["joint"],"releases":[10]},
          {"artist":{"discogsID":3,"name":"Desk"},"how":["Mixed By"],"releases":[11]}],
         "credits":[
          {"artist":{"discogsID":4,"name":"Bassist"},"roles":[{"kind":"performance","releases":[{"id":10,"tracks":[]},{"id":12,"tracks":[]}],"role":"Bass"}]},
          {"artist":{"discogsID":5,"name":"Mastering"},"roles":[{"kind":"engineering","releases":[{"id":10,"tracks":[]}],"role":"Mastered By"}]},
          {"artist":{"discogsID":194,"name":"Various"},"roles":[{"kind":"performance","releases":[{"id":10,"tracks":[]}],"role":"Vocals"}]}],
         "format":"indigo.artist-knowledge/1","genres":[],"labels":[],"releases":[],"styles":[],"stylesAround":[]}
        """#
        let bundle = try JSONDecoder().decode(ArtistBundle.self, from: Data(json.utf8))
        let potential = DiscoveryPotential.of(bundle)
        XCTAssertEqual(potential.musicians, 2, "The bandmate and the bassist; not the stand-in")
        XCTAssertEqual(potential.supportingReleases, 2)
        XCTAssertEqual(potential.technical, [3, 5])
        XCTAssertFalse(potential.technicalOnly)
        XCTAssertEqual(potential.version, DiscoveryPotential.currentVersion)
    }
}
