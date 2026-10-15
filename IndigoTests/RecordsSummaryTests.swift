//
//  RecordsSummaryTests.swift
//  IndigoTests
//
//  "From the records": only what the bundle's fields state, and nothing when
//  they state less than two things.
//

import XCTest
@testable import Indigo

final class RecordsSummaryTests: XCTestCase {
    private func bundle(_ json: String) throws -> ArtistBundle {
        try JSONDecoder().decode(ArtistBundle.self, from: Data(json.utf8))
    }

    func testTheDocumentsFactsInOrderAndNothingElse() throws {
        let b = try bundle("""
        {"artist":{"discogsID":272472,"name":"Magic Carpathians Project"},
         "collaborators":[{"artist":{"discogsID":274469,"name":"Six Organs Of Admittance"},"how":["joint"],"releases":[863079]},
                          {"artist":{"discogsID":56196,"name":"Vibracathedral Orchestra"},"how":["joint"],"releases":[863079]},
                          {"artist":{"discogsID":9,"name":"Tundra (3)"},"how":["joint"],"releases":[1]}],
         "credits":[{"artist":{"discogsID":274470,"name":"Ben Chasny"},"roles":[]},{"artist":{"discogsID":967691,"name":"Anonymous"},"roles":[]},
                    {"artist":{"discogsID":272472,"name":"Magic Carpathians Project"},"roles":[]}],
         "format":"indigo.artist-knowledge/1","genres":[],"stylesAround":[],
         "labels":[{"discogsID":79314,"display":"Mental Telemetry","name":"Mental Telemetry","ownName":false,"placeholder":false,"releases":1},
                   {"discogsID":2,"display":"World Flag Records","name":"World Flag Records","ownName":false,"placeholder":false,"releases":3},
                   {"discogsID":1818,"display":"Not On Label","name":"Not On Label","ownName":false,"placeholder":true,"releases":5}],
         "releases":[{"compilation":false,"id":863079,"masterID":null,"relation":"joint","title":"Trighplane Terraforms No.1","year":2006},
                     {"compilation":false,"id":1,"masterID":null,"relation":"joint","title":"Reindeer Luck","year":2011}],
         "styles":[{"name":"Folk","releases":2},{"name":"Experimental","releases":1}],
         "years":{"first":2006,"last":2011}}
        """)
        let summary = try XCTUnwrap(RecordsSummary.make(b))
        XCTAssertEqual(summary.text, "Records from 2006 to 2011 on World Flag Records and Mental Telemetry. "
                       + "Made records with Six Organs Of Admittance and Tundra and 1 more. "
                       + "One other person is credited on them. Filed under Folk and Experimental.")
        XCTAssertEqual(summary.documents, 2)
    }

    func testOneFactIsNotEnoughToSayAnything() throws {
        let b = try bundle("""
        {"artist":{"discogsID":1,"name":"Kid Sportswear"},"collaborators":[],"credits":[],"format":"indigo.artist-knowledge/1",
         "genres":[],"labels":[],"releases":[{"compilation":false,"id":5,"masterID":null,"relation":"main","title":"EP","year":2019}],
         "styles":[],"stylesAround":[],"years":{"first":2019,"last":2019}}
        """)
        XCTAssertNil(RecordsSummary.make(b), "A year alone is not a profile")
    }
}
