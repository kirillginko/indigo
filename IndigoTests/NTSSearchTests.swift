//
//  NTSSearchTests.swift
//  IndigoTests
//
//  Payloads trimmed from https://www.nts.live/api/v2/search?...&version=2
//

import XCTest
@testable import Indigo

final class NTSSearchTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    private let payload = """
    {"metadata":{"resultset":{"count":1461,"offset":0,"limit":36}},
     "results":[
      {"article_type":"episode","title":"In Focus: Aphex Twin","artists":[],
       "article":{"path":"/shows/in-focus/episodes/aphex-twin-18th-august-2021"},
       "description":{"highlight_html":"Selected by Unified Goods, celebrating <em>Aphex</em> Twin &amp; friends"},
       "image":{"medium":"https://media.example/400.jpg"},
       "local_date":"27 Aug 2021","location":"London",
       "genres":[{"id":"g","name":"Glitch"}],"track_uid":null},
      {"article_type":"track","title":"Falling Free (Aphex Twin Remix)",
       "artists":[{"name":"Curve","role":""},{"name":"Aphex Twin","role":"Remix"}],
       "article":{"path":"/shows/early-bird/episodes/early-bird-25th-april-2025",
                  "title":"The Early Bird Show w/ Jack Rollo"},
       "description":{},"image":{},"local_date":"25 Apr 2025","location":"",
       "genres":[],"track_uid":"c8ece704"},
      {"article_type":"show","title":"Floating Points","artists":[],
       "article":{"path":"/shows/floating-points"},
       "description":{"highlight_html":"Sam Shepherd a.k.a <em>Floating</em> <em>Points</em>."},
       "image":{"medium":"https://media.example/fp.jpg"},
       "local_date":"18 Dec 2023","location":"London",
       "genres":[{"id":"t","name":"Techno"}],"track_uid":null}
     ]}
    """

    private func results() throws -> [NTSSearchResult] {
        let response = try decode(NTSSearchResponse.self, payload)
        return response.results.enumerated().compactMap { $1.asResult(index: $0) }
    }

    func testDecodesMixedResultTypes() throws {
        let items = try results()
        XCTAssertEqual(items.map(\.kind), [.episode, .track, .show])
        XCTAssertEqual(items.map(\.kindLabel), ["Episode", "Track", "Show"])
    }

    func testEpisodeResultRoutesToItsTracklist() throws {
        let episode = try results()[0]
        XCTAssertEqual(episode.destination,
                       .ntsEpisode(show: "in-focus", episode: "aphex-twin-18th-august-2021"))
        XCTAssertEqual(episode.location, "London")
        XCTAssertEqual(episode.genres, ["Glitch"])
    }

    /// The point of track search: it tells you which broadcast played the track.
    func testTrackResultRoutesToTheEpisodeThatPlayedIt() throws {
        let track = try results()[1]
        XCTAssertEqual(track.destination,
                       .ntsEpisode(show: "early-bird", episode: "early-bird-25th-april-2025"))
        XCTAssertEqual(track.artists, ["Curve", "Aphex Twin"])
        XCTAssertEqual(track.contextTitle, "The Early Bird Show w/ Jack Rollo")
        XCTAssertNil(track.location, "Empty strings should not become a location")
    }

    func testShowResultRoutesToTheShowPage() throws {
        let show = try results()[2]
        XCTAssertEqual(show.destination, .ntsShow(alias: "floating-points"))

        let summary = try XCTUnwrap(show.asShowSummary())
        XCTAssertEqual(summary.alias, "floating-points")
        XCTAssertEqual(summary.genres, ["Techno"])
    }

    func testResultIdsAreUniqueAcrossRepeatedTracks() throws {
        let items = try results()
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    }

    // MARK: Highlights

    func testHighlightSplitsMatchedTerms() {
        let runs = HighlightRun.parse("Sam Shepherd a.k.a <em>Floating</em> <em>Points</em>.")
        XCTAssertEqual(runs.map(\.text), ["Sam Shepherd a.k.a ", "Floating", " ", "Points", "."])
        XCTAssertEqual(runs.map(\.isMatch), [false, true, false, true, false])
    }

    func testHighlightStripsOtherTagsAndDecodesEntities() {
        let runs = HighlightRun.parse("<p>Digga D &amp; <em>Nav</em></p>")
        XCTAssertEqual(runs.map(\.text).joined(), "Digga D & Nav")
        XCTAssertTrue(runs.contains { $0.isMatch && $0.text == "Nav" })
    }

    func testHighlightHandlesUnbalancedMarkup() {
        let runs = HighlightRun.parse("broken <em>tail")
        XCTAssertEqual(runs.map(\.text).joined(), "broken tail")
    }

    func testHighlightOfNothingIsEmpty() {
        XCTAssertTrue(HighlightRun.parse(nil).isEmpty)
        XCTAssertTrue(HighlightRun.parse("").isEmpty)
    }

    // MARK: Paths

    func testSitePathParsing() throws {
        let episode = try XCTUnwrap(NTSSitePath.parse("/shows/in-focus/episodes/aphex-twin-2021"))
        XCTAssertEqual(episode.show, "in-focus")
        XCTAssertEqual(episode.episode, "aphex-twin-2021")

        let show = try XCTUnwrap(NTSSitePath.parse("/shows/floating-points"))
        XCTAssertEqual(show.show, "floating-points")
        XCTAssertNil(show.episode)

        XCTAssertNil(NTSSitePath.parse("/artists/aphex-twin"))
        XCTAssertNil(NTSSitePath.parse(""))
        XCTAssertNil(NTSSitePath.parse("/shows/"))
    }

    /// An artist result has no show path, so it must not pretend to be tappable.
    func testResultWithoutAShowPathHasNoDestination() throws {
        let json = """
        {"results":[{"article_type":"artist","title":"Aphex Twin","artists":[],
                     "article":{"path":"/artists/aphex-twin"},"description":{},"image":{}}]}
        """
        let response = try decode(NTSSearchResponse.self, json)
        let result = try XCTUnwrap(response.results.first?.asResult(index: 0))
        XCTAssertEqual(result.kind, .artist)
        XCTAssertNil(result.destination)
        XCTAssertNil(result.asShowSummary())
    }

    // MARK: Scope

    func testScopeQueryValues() {
        XCTAssertNil(NTSSearchScope.all.queryValue, "`all` must not send a types filter")
        XCTAssertEqual(NTSSearchScope.show.queryValue, "show")
        XCTAssertEqual(NTSSearchScope.episode.queryValue, "episode")
        XCTAssertEqual(NTSSearchScope.track.queryValue, "track")
    }

    // MARK: Mixtape credits

    func testMixtapeCreditsLinkToShows() throws {
        let json = """
        {"mixtape_alias":"poolside","title":"Poolside","subtitle":"Balearic.",
         "audio_stream_endpoint":"https://stream-mixtape-geo.ntslive.net/mixtape4",
         "credits":[{"name":"All Styles All Smiles","path":"/shows/all-styles-all-smiles"},
                    {"name":"Nowhere","path":""},
                    {"name":"  ","path":"/shows/ignored"}]}
        """
        let mixtape = try XCTUnwrap(decode(NTSMixtapeDTO.self, json).asMixtape())
        XCTAssertEqual(mixtape.credits.count, 2, "Blank names are dropped")
        XCTAssertEqual(mixtape.credits[0].destination, .ntsShow(alias: "all-styles-all-smiles"))
        XCTAssertNil(mixtape.credits[1].destination, "A credit with no path isn't tappable")
    }

    /// NTS files one-off guest sets under /shows/guests/episodes/..., so many
    /// credits share the show alias. Keying identity on the alias made ForEach
    /// silently drop every credit after the first.
    func testCreditsSharingAShowStayDistinct() throws {
        let json = """
        {"mixtape_alias":"poolside","title":"Poolside",
         "audio_stream_endpoint":"https://stream-mixtape-geo.ntslive.net/mixtape4",
         "credits":[{"name":"DJ Young Kiera","path":"/shows/guests/episodes/dj-young-kiera-2019"},
                    {"name":"Let's Get Yachts","path":"/shows/guests/episodes/lets-get-yachts-2017"},
                    {"name":"Michael Franks","path":"/shows/guests/episodes/michael-franks-2016"}]}
        """
        let mixtape = try XCTUnwrap(decode(NTSMixtapeDTO.self, json).asMixtape())
        XCTAssertEqual(mixtape.credits.count, 3)
        XCTAssertEqual(Set(mixtape.credits.map(\.id)).count, 3, "Credit ids must be unique")
        XCTAssertEqual(mixtape.credits[1].destination,
                       .ntsEpisode(show: "guests", episode: "lets-get-yachts-2017"),
                       "A credit naming one broadcast should open that broadcast")
    }

    func testRepeatedTrackInOneEpisodeKeepsDistinctRows() throws {
        let json = """
        {"status":"published","name":"X","episode_alias":"x-1","show_alias":"x",
         "embeds":{"tracklist":{"results":[
           {"artist":"A","title":"Reprise","uid":"same","offset":10},
           {"artist":"A","title":"Reprise","uid":"same","offset":3000}]}}}
        """
        let detail = try XCTUnwrap(decode(NTSEpisodeDTO.self, json).asDetail())
        XCTAssertEqual(detail.tracklist.count, 2)
        XCTAssertEqual(Set(detail.tracklist.map(\.id)).count, 2)
    }
}
