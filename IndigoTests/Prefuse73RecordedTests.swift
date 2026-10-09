//
//  Prefuse73RecordedTests.swift
//  IndigoTests
//
//  The before and after, on what Discogs actually returned for "Prefuse73" on
//  2026-10-09 through Indigo's backend: both searches as recorded (cut to id,
//  type and title), and Prefuse 73's own entry from `ArtistIdentityFixtures`.
//

import XCTest
@testable import Indigo

final class Prefuse73RecordedTests: XCTestCase {
    /// `database/search?q=Prefuse73&type=artist&per_page=5`, the lookup's own search.
    static let headSearch = #"{"pagination": {"page": 1, "pages": 3, "per_page": 5, "items": 15}, "results": [{"id": 3722, "type": "artist", "title": "Prefuse 73"}, {"id": 111148, "type": "artist", "title": "Soarse Spoken"}, {"id": 3838, "type": "artist", "title": "Savath & Savalas"}, {"id": 1827101, "type": "artist", "title": "VOICEsVOICEs"}, {"id": 3452158, "type": "artist", "title": "Sons Of The Morning"}]}"#

    /// The same with `per_page=50`: fifteen matches, all on one page.
    static let checkSearch = #"{"pagination": {"page": 1, "pages": 1, "per_page": 50, "items": 15}, "results": [{"id": 3722, "type": "artist", "title": "Prefuse 73"}, {"id": 111148, "type": "artist", "title": "Soarse Spoken"}, {"id": 3838, "type": "artist", "title": "Savath & Savalas"}, {"id": 1827101, "type": "artist", "title": "VOICEsVOICEs"}, {"id": 3452158, "type": "artist", "title": "Sons Of The Morning"}, {"id": 8582, "type": "artist", "title": "Mia Doi Todd"}, {"id": 94742, "type": "artist", "title": "Ganucheau"}, {"id": 159053, "type": "artist", "title": "LebLaze"}, {"id": 940760, "type": "artist", "title": "DJ Proof"}, {"id": 16685896, "type": "artist", "title": "ジェシカ (2)"}, {"id": 91118, "type": "artist", "title": "Seely"}, {"id": 1250634, "type": "artist", "title": "Daylight's For The Birds"}, {"id": 210843, "type": "artist", "title": "Isaiah Owens"}, {"id": 3427255, "type": "artist", "title": "Turtle Island"}, {"id": 675892, "type": "artist", "title": "FILLL"}]}"#

    private struct Recorded: DiscogsTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url?.absoluteString ?? ""
            let body: String
            if url.contains("database/search"), url.contains("per_page=50") { body = Prefuse73RecordedTests.checkSearch }
            else if url.contains("database/search") { body = Prefuse73RecordedTests.headSearch }
            else if url.hasSuffix("artists/3722") { body = ArtistIdentityFixtures.entries[3722]! }
            else { body = "{}" }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    /// Before: the filing-name match, which was the whole lookup, finds nobody
    /// in the search Discogs returned — so the page opened empty.
    func testBeforeTheRecordedSearchMatchedNobody() throws {
        let search = try JSONDecoder().decode(DiscogsSearchResponse.self, from: Data(Self.headSearch.utf8))
        XCTAssertEqual(search.results?.first?.id, 3722, "Discogs ranked him first")
        XCTAssertTrue(DiscogsClient.artistMatches(name: "Prefuse73", results: search.results ?? []).isEmpty)
    }

    /// After: the same responses find Prefuse 73.
    func testAfterTheRecordedSearchFindsPrefuse73() async throws {
        let lookup = try await DiscogsClient(transport: Recorded(), token: "t").artistLookup(named: "Prefuse73")

        XCTAssertEqual(lookup.head?.id, 3722)
        XCTAssertEqual(lookup.head?.title, "Prefuse 73")
        XCTAssertEqual(lookup.spelling?.verdict, .variation(3722))
        XCTAssertEqual(lookup.spelling?.resultCount, 15)
    }
}
