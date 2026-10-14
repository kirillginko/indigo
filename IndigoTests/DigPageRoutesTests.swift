//
//  DigPageRoutesTests.swift
//  IndigoTests
//
//  How an artist page lays out its routes (`ArtistDigView.Connections`) and
//  what it adds to a walked profile from the catalogue (`DigStore.forPage`):
//  aliases are their own lane whatever else the records say, remixers are not
//  buried in production, same-record routes are shown, rows that lead
//  somewhere come first, and the page's bundle supplies labels the device's
//  records did not.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class DigPageRoutesTests: XCTestCase {
    private func row(_ name: String, _ kind: RelationshipKind, _ detail: String = "", id: Int? = nil, leadsOn: Bool = false) -> RelatedArtist {
        var row = RelatedArtist(name: name, mbid: nil,
                                reasons: [Relationship(kind: kind, source: .discogs, detail: detail, confidence: kind.baseConfidence)],
                                imageURL: nil, discogsID: id)
        row.leadsOn = leadsOn
        return row
    }

    func testEachRouteLandsInTheLaneThatSaysWhatItIs() {
        var alias = row("Rhythim Is Rhythim", .sameAlias, id: 4979)
        alias = RelatedArtist(name: alias.name, mbid: nil,
                              reasons: alias.reasons + [Relationship(kind: .producer, source: .discogs, detail: "Producer on Strings", confidence: 0.8)],
                              imageURL: nil, discogsID: 4979)
        let lanes = ArtistDigView.Connections.split([
            alias,
            row("Escalated Edits", .producer, "Remix on Rise", id: 15149773),
            row("Funk D'Void", .producer, "Producer on Rise, Remix on Fall", id: 1),
            row("Ben Chasny", .personnel, "Performer on Trighplane Terraforms No.1", id: 274470),
            row("Somebody", .sameRelease, "Appears on Compilation", id: 2),
        ])
        XCTAssertEqual(lanes.projects.map(\.name), ["Rhythim Is Rhythim"], "An alias is the same person, whatever else")
        XCTAssertEqual(lanes.remixers.map(\.name), ["Escalated Edits"])
        XCTAssertEqual(lanes.producers.map(\.name), ["Funk D'Void"], "Remixes and other production: production")
        XCTAssertEqual(lanes.personnel.map(\.name), ["Ben Chasny"])
        XCTAssertEqual(lanes.sameRecords.map(\.name), ["Somebody"])
    }

    func testRoutesThatLeadSomewhereComeFirst() {
        let lanes = ArtistDigView.Connections.split([
            row("Adam Davenport", .personnel, id: 535372),
            row("Bridget Hayden", .personnel, id: 535371, leadsOn: true),
            row("Ben Chasny", .personnel, id: 274470, leadsOn: true),
            row("Aleksandra Yaromoya", .personnel, id: 709767),
        ])
        XCTAssertEqual(lanes.personnel.map(\.name), ["Bridget Hayden", "Ben Chasny", "Adam Davenport", "Aleksandra Yaromoya"])
    }
}

/// Label and style neighbours come from search titles, by name only.
final class DiscogsNeighbourSpellingTests: XCTestCase {
    func testAVariantSpellingIsNotOfferedAsSomebodyToOpenByName() {
        let results: [DiscogsSearchResult] = [
            // On Konspiracy Rekords, "Drama Aka Treason*" credits Drama Treason (9087331);
            // the entry named "Drama aka Treason" (10218922) is somebody else's page.
            .init(id: 18204358, title: "Drama Aka Treason* - Barz", coverImage: nil, thumbnail: nil, genre: nil, style: nil, label: nil, year: nil),
            .init(id: 18204502, title: "Young Ghost - Wolf", coverImage: nil, thumbnail: nil, genre: nil, style: nil, label: nil, year: nil),
            .init(id: 18335375, title: "Drama Treason - Operation Cypher", coverImage: nil, thumbnail: nil, genre: nil, style: nil, label: nil, year: nil),
        ]
        let names = DiscogsClient.neighbours(from: results).map(\.name)
        XCTAssertFalse(names.contains("Drama Aka Treason"), "A variant spelling opens nobody")
        XCTAssertTrue(names.contains("Young Ghost"))
        XCTAssertTrue(names.contains("Drama Treason"), "Under their own name they are still offered")
    }
}
