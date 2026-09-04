//
//  RadioGraphTests.swift
//  IndigoTests
//
//  The edges radio derives (4G) and what a label page can say about them (§10).
//
//  The spec is explicit that a recommendation must never be opaque, so what is
//  pinned here is mostly the sentence a relationship produces. A count of
//  independent broadcasts is a reason; a confidence of 0.87 is not, and an edge
//  that lost its evidence on the way through the decoder would silently become
//  the second thing.
//

import XCTest
@testable import Indigo

final class RadioGraphTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - artist_radio_relations

    private let relations = """
    [
      {
        "relationship_type": "played_by",
        "entity_type": "radio_show",
        "entity_id": "6E2E4F4E-0000-4000-8000-0000000000A1",
        "title": "Ben UFO",
        "station": "NTS",
        "provider": "nts",
        "external_id": "ben-ufo",
        "evidence_count": 12,
        "confidence": 0.86,
        "metadata": {"episodes": 8, "appearances": 12}
      },
      {
        "relationship_type": "radio_neighbor",
        "entity_type": "artist",
        "entity_id": "6E2E4F4E-0000-4000-8000-0000000000B2",
        "title": "Objekt",
        "station": null,
        "provider": null,
        "external_id": null,
        "evidence_count": 4,
        "confidence": 0.8,
        "metadata": {"adjacencies": 4, "episodes": 3}
      },
      {
        "relationship_type": "radio_neighbor",
        "entity_type": "artist",
        "entity_id": "6E2E4F4E-0000-4000-8000-0000000000B3",
        "title": "Pearson Sound",
        "station": null,
        "provider": null,
        "external_id": null,
        "evidence_count": 1,
        "confidence": 0.65,
        "metadata": {"adjacencies": 1, "episodes": 1}
      }
    ]
    """

    func testAnEdgeArrivesWithTheEvidenceItWasDerivedFrom() throws {
        let edges = try decode([Catalog.RadioRelation].self, relations)

        XCTAssertEqual(edges.count, 3)
        XCTAssertEqual(edges[0].evidenceCount, 12)
        XCTAssertEqual(edges[0].metadata?.episodes, 8)
        XCTAssertEqual(edges[1].metadata?.adjacencies, 4)
    }

    /// The line the page renders instead of a score.
    func testEveryEdgeCanSayWhyItIsThere() throws {
        let edges = try decode([Catalog.RadioRelation].self, relations)

        XCTAssertEqual(edges[0].reason, "Played in 8 broadcasts")
        XCTAssertEqual(edges[1].reason, "Played back to back 4 times")
        XCTAssertEqual(edges[2].reason, "Played back to back once",
                       "One is still evidence, and it should read like English")
    }

    func testAShowEdgeNamesTheShowAndAnArtistEdgeNamesTheArtist() throws {
        let edges = try decode([Catalog.RadioRelation].self, relations)

        XCTAssertEqual(edges[0].displayName, "Ben UFO")
        XCTAssertEqual(edges[0].entityType, "radio_show")
        XCTAssertEqual(edges[1].displayName, "Objekt")
        XCTAssertEqual(edges[1].entityType, "artist")
    }

    /// Two edges of different kinds can point at the same entity — a show that
    /// plays an artist, and later an artist who is also a show name. Identity
    /// has to carry the kind or one would replace the other in a ForEach.
    func testAnEdgesIdentityIncludesWhatKindOfEdgeItIs() throws {
        let edges = try decode([Catalog.RadioRelation].self, relations)

        XCTAssertNotEqual(edges[0].id, edges[1].id)
        XCTAssertEqual(Set(edges.map(\.id)).count, edges.count)
    }

    // MARK: - label_radio_summary

    func testALabelSummaryDecodesAndSaysWhatItCounted() throws {
        let summary = try decode(Catalog.LabelRadioSummary.self, """
        {
          "label_id": "6E2E4F4E-0000-4000-8000-0000000000C1",
          "derivation": "artist_roster",
          "appearance_count": 184,
          "episode_count": 96,
          "show_count": 39,
          "artist_count": 26,
          "first_appearance_at": "2019-02-03T13:00:00+00:00",
          "latest_appearance_at": "2026-06-12T20:00:00+00:00",
          "top_shows": [{
            "show_id": "6E2E4F4E-0000-4000-8000-0000000000A1",
            "provider": "nts", "external_id": "ben-ufo",
            "title": "Ben UFO", "station": "NTS",
            "host_name": null, "appearance_count": 21
          }],
          "top_artists": [{
            "artist_id": "6E2E4F4E-0000-4000-8000-0000000000B1",
            "name": "Skee Mask", "appearance_count": 47
          }]
        }
        """)

        XCTAssertEqual(summary.appearanceCount, 184)
        XCTAssertEqual(summary.showCount, 39)
        XCTAssertEqual(summary.artistCount, 26)
        XCTAssertEqual(summary.topArtists.first?.name, "Skee Mask")
        XCTAssertEqual(summary.topShows.first?.displayName, "Ben UFO")
        XCTAssertTrue(
            summary.isViaRoster,
            "Counted from the roster, so the page has to be able to say so rather than "
            + "implying Indigo matched the pressings"
        )
    }

    func testALabelNobodyHasPlayedReadsAsEmpty() throws {
        let summary = try decode(Catalog.LabelRadioSummary.self, """
        {
          "label_id": "6E2E4F4E-0000-4000-8000-0000000000C1",
          "derivation": "artist_roster",
          "appearance_count": 0, "episode_count": 0, "show_count": 0, "artist_count": 0,
          "first_appearance_at": null, "latest_appearance_at": null,
          "top_shows": [], "top_artists": []
        }
        """)

        XCTAssertTrue(summary.isEmpty)
        XCTAssertTrue(summary.topArtists.isEmpty)
    }
}
