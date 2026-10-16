//
//  ForYouArtistEvidenceTests.swift
//  IndigoTests
//
//  Somebody reached only as a producer is offered by the mix only with
//  evidence they are an artist; a player or a labelmate needs none.
//

import XCTest
@testable import Indigo

final class ForYouArtistEvidenceTests: XCTestCase {
    private func suggestion(_ name: String, _ kind: RelationshipKind, _ reason: String, id: Int? = nil) -> ExploreSuggestion {
        ExploreSuggestion(node: .artist(name, discogsID: id), reason: reason, via: "Prefuse 73", kind: kind, corroboration: 1, score: 1)
    }

    func testAProducersCreditIsCreativeAndAPlayersIsNot() {
        XCTAssertTrue(ForYouArtistEvidence.isCreativeRoute(suggestion("Dave Fridmann", .producer, "Producer on The Flaming Lips With Prefuse 73")))
        XCTAssertTrue(ForYouArtistEvidence.isCreativeRoute(suggestion("Vegyn", .producer, "Co-producer on Lucre")))
        XCTAssertFalse(ForYouArtistEvidence.isCreativeRoute(suggestion("Bassist", .personnel, "Bass on Now")))
        XCTAssertFalse(ForYouArtistEvidence.isCreativeRoute(suggestion("Labelmate", .sharedLabel, "Both release on Warp")))
        XCTAssertFalse(ForYouArtistEvidence.isCreativeRoute(suggestion("Bandmate", .collaborator, "Credited together")))
    }

    func testOnlyTheUnvouchedAreLeftOut() {
        var offers = ExploreOffers()
        let producer = suggestion("Dave Fridmann", .producer, "Producer on The Flaming Lips With Prefuse 73")
        let artist = suggestion("Vegyn", .producer, "Co-producer on Lucre")
        offers.next = [producer, artist, suggestion("Bassist", .personnel, "Bass on Now")]
        let kept = ForYouArtistEvidence.kept(offers, unproven: [producer.node, artist.node], vouched: [artist.node.id])
        XCTAssertEqual(kept.next.map(\.node.title), ["Vegyn", "Bassist"])
    }

    /// By Discogs entry when there is one, by a name only one catalogue
    /// artist has otherwise; nothing answered, nothing vouched.
    func testTheCatalogueVouchesByEntryOrByAnUnsharedName() async {
        let onAir = UUID(), alone = UUID(), shared1 = UUID(), shared2 = UUID()
        var source = TrackDiscoverySource.live
        source.cache = TrackDiscoveryCache()
        source.rows = { ids in ids.contains(4209810) ? [4209810: [onAir]] : [:] }
        source.appearances = { rows in
            let json = "[" + rows.filter { $0 != shared2 }.map { #"{"artist_id":"\#($0.uuidString)"}"# }.joined(separator: ",") + "]"
            return try JSONDecoder().decode([TrackDiscoverySource.Row].self, from: Data(json.utf8))
        }
        let nodes: [MusicNode] = [.artist("Vegyn", discogsID: 4209810), .artist("Dave Fridmann", discogsID: 1),
                                  .artist("Inga Copeland"), .artist("Copeland")]
        let vouched = await ForYouArtistEvidence.onRadio(nodes, source: source) { names in
            ["Inga Copeland": [alone], "Copeland": [shared1, shared2]].filter { names.contains($0.key) }
        }
        XCTAssertEqual(vouched, [MusicNode.artist("Vegyn", discogsID: 4209810).id, MusicNode.artist("Inga Copeland").id])

        source.appearances = { _ in throw URLError(.notConnectedToInternet) }
        let offline = await ForYouArtistEvidence.onRadio(nodes, source: source) { _ in [:] }
        XCTAssertTrue(offline.isEmpty, "Unanswered is not evidence")
    }
}
