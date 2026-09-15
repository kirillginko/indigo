//
//  CatalogPathKeyTests.swift
//  IndigoTests
//
//  A search has no id to cache under, so it is cached under the request. The
//  Edge Function builds that key when it stores the row and the app builds it
//  again when it reads one, and a disagreement means the app invokes the
//  function every time instead of reading Postgres — twice as slow, silently.
//
//  The expectations below are the literal `resource_id` values the deployed
//  function wrote. Keys are sorted and values are left raw: percent-encoding
//  belongs to the URL, not to a database key, and URLSearchParams and
//  URLComponents disagree about spaces ("+" against "%20").
//

import XCTest
@testable import Indigo

final class CatalogPathKeyTests: XCTestCase {
    private func key(_ path: String, _ pairs: [(String, String)]) -> String {
        MetadataRepository.cacheKey(
            path: path, query: pairs.map { URLQueryItem(name: $0.0, value: $0.1) })
    }

    /// Verbatim from metadata_cache after the function stored this search.
    func testASearchKeyMatchesTheOneTheBackendWrote() {
        XCTAssertEqual(
            key("database/search", [("type", "artist"), ("q", "Skee Mask"), ("per_page", "3")]),
            "database/search?per_page=3&q=Skee Mask&type=artist")
    }

    /// The caller's ordering must not change the key, or the same search lands
    /// on two rows and neither is ever reused.
    func testKeyDoesNotDependOnParameterOrder() {
        let a = key("database/search", [("q", "Aphex Twin"), ("type", "artist")])
        let b = key("database/search", [("type", "artist"), ("q", "Aphex Twin")])
        XCTAssertEqual(a, b)
    }

    func testAPathWithNoQueryIsItsOwnKey() {
        XCTAssertEqual(key("artists/72872", []), "artists/72872")
        XCTAssertEqual(key("releases/249504", []), "releases/249504")
    }

    /// Spaces stay spaces. This is the encoding trap the raw key exists to
    /// avoid — "%20" or "+" here would never match what the function stored.
    func testValuesAreLeftRaw() {
        let value = key("database/search", [("q", "Simon & Garfunkel")])
        XCTAssertEqual(value, "database/search?q=Simon & Garfunkel")
        XCTAssertFalse(value.contains("%20"))
        XCTAssertFalse(value.contains("+"))
    }

    func testAnEmptyValueStillProducesItsPair() {
        XCTAssertEqual(key("database/search", [("q", "")]), "database/search?q=")
    }

    /// The shelf key, which three things have to agree on: the request the app
    /// sends, the row `cacheDiscogsShelf` writes, and the read
    /// `CatalogShelfSource` makes. A disagreement is not an error — it is a
    /// cached shelf nobody ever finds, and a page that goes on waiting the
    /// 2,727ms this exists to remove.
    ///
    /// The literal below is what `discogs.ts` builds:
    /// `${path}?${SHELF_QUERY}`, with SHELF_QUERY sorted the way `resolvePath`
    /// sorts it.
    func testTheShelfKeyMatchesTheOneTheWorkerWrites() {
        XCTAssertEqual(
            MetadataRepository.cacheKey(
                path: DiscogsClient.shelfPath(id: 5087),
                query: DiscogsClient.shelfQuery
            ),
            "artists/5087/releases?per_page=50&sort=year&sort_order=desc"
        )
    }

    /// And the request the app actually sends carries those same three
    /// parameters — a shelf fetched with a different `per_page` is a different
    /// listing, cached under a key the reader will not build.
    func testTheShelfRequestCarriesExactlyWhatTheKeyNames() {
        XCTAssertEqual(
            Set(DiscogsClient.shelfQuery.map(\.name)),
            ["per_page", "sort", "sort_order"]
        )
        XCTAssertEqual(
            DiscogsClient.shelfQuery.first { $0.name == "per_page" }?.value, "50",
            "Fifty is what the worker fetches and what the key says"
        )
    }
}
