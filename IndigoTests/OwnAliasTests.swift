//
//  OwnAliasTests.swift
//  IndigoTests
//
//  For You does not offer the listener's own artist back under another name
//  their Discogs entry lists -- and does not take a namesake for one.
//

import XCTest
@testable import Indigo

final class OwnAliasTests: XCTestCase {
    private func edge(_ from: MusicNode, _ to: MusicNode, _ kind: RelationshipKind, _ reason: String) -> MusicEdge {
        MusicEdge(from: from, to: to, kind: kind, source: .discogs, reason: reason, confidence: kind.baseConfidence)
    }

    private func walk(_ origin: MusicNode, _ edges: [MusicEdge]) -> IdentityNeighbourhood {
        var set = EdgeSet()
        set.insert(contentsOf: edges)
        return IdentityNeighbourhood(origin: origin, edges: set, keys: [:])
    }

    private func verified(_ id: Int, _ name: String) -> GraphIdentityKey {
        GraphIdentityKey(nodeKey: "discogs:\(id)")!   // name: for reading only
    }

    /// Speedy J's own entry lists "Jochem Paap"; the credit under that name
    /// names entry 4295, the one verified owner of the name here.
    func testTheArtistsOwnAliasAndItsOneOwnerAreKnown() {
        let speedy = MusicNode.artist("Speedy J", discogsID: 823)
        let found = KnownArtistPolicy.ownAliases(
            walks: [walk(speedy, [edge(speedy, .artist("Jochem Paap"), .sameAlias, "Also records as Speedy J")])],
            owners: ["jochem paap": [verified(4295, "Jochem Paap")]])
        XCTAssertEqual(found, [MusicNode.artist("Jochem Paap").id, verified(4295, "Jochem Paap").nodeID])
    }

    /// The entry a collapse folded the alias's name row into, as the walk
    /// carries it.
    func testAnAliasFoldedIntoItsEntryIsStillKnown() {
        let speedy = MusicNode.artist("Speedy J", discogsID: 823)
        var folded = walk(speedy, [])
        folded.aliases = ["artist:jochem paap", "artist:discogs:4295"]
        XCTAssertEqual(KnownArtistPolicy.ownAliases(walks: [folded], owners: [:]),
                       ["artist:jochem paap", "artist:discogs:4295"])
    }

    /// A name two verified entries share here says nothing about which.
    func testANameWithTwoOwnersMakesNeitherKnown() {
        let artist = MusicNode.artist("Anika", discogsID: 1982320)
        let found = KnownArtistPolicy.ownAliases(
            walks: [walk(artist, [edge(artist, .artist("Tune"), .sameAlias, "Also records as Anika")])],
            owners: ["tune": [verified(100, "Tune"), verified(200, "Tune")]])
        XCTAssertEqual(found, [MusicNode.artist("Tune").id])
    }

    /// Groups and members are other bodies of work, not other names; and an
    /// alias reached from a record or a show is not the listener's artist's.
    func testOnlyAnArtistsOwnAliasesCount() {
        let duo = MusicNode.artist("Hype Williams", discogsID: 1874027)
        let record = MusicNode.release("Untitled", discogsID: 2347777)
        let found = KnownArtistPolicy.ownAliases(
            walks: [walk(duo, [edge(duo, .artist("Inga Copeland"), .aliasOrProject, "Makes up Hype Williams")]),
                    walk(record, [edge(record, .artist("Blunt"), .sameAlias, "Also records as Dean Blunt")])],
            owners: [:])
        XCTAssertTrue(found.isEmpty)
    }

    /// Known is excluded before ranking, so the next candidate takes the place.
    func testForYouLeavesAKnownAliasOut() {
        let speedy = MusicNode.artist("Speedy J", discogsID: 823)
        let paap = MusicNode(kind: .artist, key: "discogs:4295", title: "Jochem Paap", discogsID: 4295)
        let kept = PersonalInputs.Kept(node: speedy, addedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                       genreTags: ["techno"], tasteArtistKeys: [speedy.key], sceneArtistKey: speedy.key)
        let personal = PersonalInputs(crate: [kept], plays: [], met: [], artistPlays: [:], haunts: [])
        let nodes = [speedy, paap, MusicNode.artist("Oberman")]
        var knowledge = KnowledgeSnapshot.empty
        knowledge.shared.nodes = nodes
        knowledge.shared.neighbourhoods = [Neighbourhood(origin: 0, edges: [
            KnownEdge(from: 0, to: 1, kind: .producer, source: "discogs", reason: "Written-By, Producer on 808 180 30",
                      confidence: RelationshipKind.producer.baseConfidence, occurrences: 1),
            KnownEdge(from: 0, to: 2, kind: .personnel, source: "discogs", reason: "Bass on Pedestrian Sketches",
                      confidence: RelationshipKind.personnel.baseConfidence, occurrences: 1),
        ])]
        let asOf = Date(timeIntervalSince1970: 1_790_000_100)
        let offers = ExploreRanker.offers(personal: personal, knowledge: knowledge, asOf: asOf, alsoKnown: [paap.id])
        XCTAssertEqual((offers.next + offers.artists).map(\.node.title), ["Oberman"])
    }
}
