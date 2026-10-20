import XCTest
@testable import Indigo

/// An artist's styles come from their own records, not from whatever else a
/// search for their name turns up.
///
/// AnD, two techno producers, were stored as Indie Rock, Folk Rock and
/// Hardcore Hip-Hop: "AnD" as the text of a credit also matches And And And
/// and A.n.D., and every hit's styles were taken. For You then said their
/// record led "Toward Folk".
final class ArtistStylesTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func shelf() throws -> [DiscogsArtistRelease] {
        try decode(DiscogsArtistReleases.self, #"""
        {"releases":[
          {"id":500,"title":"Cosmic Microwave Background","type":"master","main_release":5001,"role":"Main"},
          {"id":600,"title":"Bleeding Edge","type":"release","role":"Main"}
        ]}
        """#).releases ?? []
    }

    private func search() throws -> [DiscogsSearchResult] {
        try decode(DiscogsSearchResponse.self, #"""
        {"results":[
          {"id":9270486,"title":"And And And - The Failure","style":["Indie Rock","Folk Rock"],"genre":["Rock"]},
          {"id":5002,"master_id":500,"title":"AnD - Cosmic Microwave Background","style":["Techno"],"genre":["Electronic"]},
          {"id":600,"title":"AnD - Bleeding Edge","style":["Industrial","Techno"],"genre":["Electronic"]},
          {"id":1456904,"title":"A.n.D.* - Something","style":["Hardcore Hip-Hop"],"genre":["Hip Hop"]}
        ]}
        """#).results ?? []
    }

    func testOnlyTheShelfsRecordsLendTheirStyles() throws {
        let own = DiscogsEnricher.ownRecords(in: try search(), shelf: try shelf())
        XCTAssertEqual(own.compactMap(\.id).sorted(), [600, 5002])
        let styles = Set(own.flatMap { $0.style ?? [] })
        XCTAssertEqual(styles, ["Techno", "Industrial"])
    }

    func testANameWithNoOwnHitsHasNoStylesRatherThanANamesakes() throws {
        let strangers = try search().filter { $0.id == 9270486 || $0.id == 1456904 }
        XCTAssertTrue(DiscogsEnricher.ownRecords(in: strangers, shelf: try shelf()).isEmpty)
    }
}
