//
//  PresentationOrderTests.swift
//  IndigoTests
//
//  Moving an artist from their name to their Discogs entry must not move them
//  in any list where nothing else separates them from their neighbours.
//

import XCTest
@testable import Indigo

final class PresentationOrderTests: XCTestCase {
    private func identity(_ id: Int, _ title: String) -> MusicNode {
        MusicNode(kind: .artist, key: GraphIdentityKey.discogs(id).nodeKey, title: title)
    }

    func testANodeThatAlwaysWasSortsByItsIDAsBefore() {
        for node in [MusicNode.artist("Vegyn"), .label("Warp"), .release("One Nation", discogsID: 1)] {
            XCTAssertEqual(node.presentationKey, node.id)
        }
    }

    func testAnArtistUnderTheirEntrySortsWhereTheirNameDid() {
        let names = ["Annika Henderson", "Atom", "Attilio Novellino", "Blue Iverson", "Jochem Paap", "Vegyn"]
        let before = names.map { MusicNode.artist($0) }.sorted { $0.presentationKey < $1.presentationKey }.map(\.title)
        let mixed = [identity(3999072, "Annika Henderson"), .artist("Atom"), identity(1720124, "Attilio Novellino"),
                     .artist("Blue Iverson"), identity(4295, "Jochem Paap"), identity(4209810, "Vegyn")]
        let after = mixed.shuffled().sorted { $0.presentationKey < $1.presentationKey }.map(\.title)
        XCTAssertEqual(after, before)
    }

    func testNamesakesStillHaveAnOrder() {
        let duo = identity(1874027, "Hype Williams"), director = identity(82, "Hype Williams")
        XCTAssertNotEqual(duo.presentationKey, director.presentationKey)
        XCTAssertEqual([duo, director].sorted { $0.presentationKey < $1.presentationKey },
                       [director, duo].sorted { $0.presentationKey < $1.presentationKey })
    }

    /// Equal-weight starting points keep their order when one of them moves to
    /// an identity key.
    func testStartingPointsKeepTheirOrder() {
        func personal(_ nodes: [MusicNode]) -> PersonalInputs {
            PersonalInputs(
                crate: nodes.map { PersonalInputs.Kept(node: $0, addedAt: Date(timeIntervalSince1970: 0), genreTags: [],
                                                       tasteArtistKeys: [], sceneArtistKey: nil) },
                plays: [], met: [], artistPlays: [:], haunts: [])
        }
        let named = ExploreRanker.knownGround(personal([.artist("Vegyn"), .artist("Atom"), .artist("Dean Blunt")])).map(\.node.title)
        let keyed = ExploreRanker.knownGround(personal([identity(4209810, "Vegyn"), .artist("Atom"), identity(2419343, "Dean Blunt")])).map(\.node.title)
        XCTAssertEqual(keyed, named)
    }
}
