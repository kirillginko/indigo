//
//  CashmereTests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on backstage.cashmereradio.com.
//  Cashmere is WordPress read through WPGraphQL, so everything arrives as
//  edges and nodes and the fields the station cares about hang off `acf`.
//

import XCTest
@testable import Indigo

final class CashmereTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Episodes

    private let episode = """
    {"databaseId":33480,"slug":"faulendes-holz-faul5-w-excel-rose",
     "title":"Faulendes Holz FAUL5 w/excel rose","uri":"/episode/faulendes-holz-faul5-w-excel-rose/",
     "dateGmt":"2026-08-28T19:52:33",
     "content":"<p>&quot;Faulendes Holz&quot; is about obscurity.</p>\\n<p>Today w/ excel rose.</p>",
     "acf":{"episodeDate":"20260611",
            "episodeMixcloudLink":"https://mixcloud.com/CashmereRadio/faulendes-holz-faul5-wexcel-rose-11062026/",
            "episodeFilterGenre":["Krautrock","Wave",""],
            "episodeFilterMood":["Informative"],
            "episodeFilterFocuseddiverse":"Diverse"},
     "categories":{"edges":[{"node":{"databaseId":318,"name":"Faulendes Holz","slug":"faulendes-holz","count":5}}]},
     "featuredImage":{"node":{"sourceUrl":"https://media.cashmereradio.com/x.jpg","altText":"x"}}}
    """

    func testEpisodeParsesIntoSomethingPlayable() throws {
        let parsed = try XCTUnwrap(decode(CashmereEpisodeDTO.self, episode).asEpisode())

        XCTAssertEqual(parsed.slug, "faulendes-holz-faul5-w-excel-rose")
        XCTAssertEqual(parsed.title, "Faulendes Holz FAUL5 w/excel rose")
        XCTAssertTrue(parsed.isPlayable)
        XCTAssertEqual(parsed.genres, ["Krautrock", "Wave"], "A blank genre is not a genre")
        XCTAssertEqual(parsed.moods, ["Informative"])
        XCTAssertEqual(parsed.showName, "Faulendes Holz")
        XCTAssertEqual(parsed.showSlug, "faulendes-holz")
        XCTAssertEqual(parsed.summary, "\"Faulendes Holz\" is about obscurity.\nToday w/ excel rose.")
    }

    /// The station stamps the date it went out; WordPress stamps the date the
    /// page happened to be published, months later.
    func testBroadcastDateBeatsThePublishDate() throws {
        let parsed = try XCTUnwrap(decode(CashmereEpisodeDTO.self, episode).asEpisode())
        XCTAssertEqual(parsed.airedLabel, "11 Jun 2026")

        let noAirDate = """
        {"slug":"x","title":"X","dateGmt":"2026-08-28T19:52:33","acf":{"episodeDate":null}}
        """
        let fallback = try XCTUnwrap(decode(CashmereEpisodeDTO.self, noAirDate).asEpisode())
        XCTAssertEqual(fallback.airedLabel, "28 Aug 2026", "Without one, the publish date is all there is")
    }

    /// Cashmere archives to Mixcloud, so an episode plays through the hosted
    /// widget rather than from the station.
    func testEpisodePlaysThroughTheMixcloudWidget() throws {
        let parsed = try XCTUnwrap(decode(CashmereEpisodeDTO.self, episode).asEpisode())
        let item = try XCTUnwrap(parsed.mediaItem())

        XCTAssertEqual(item.embedProvider, .mixcloud)
        XCTAssertEqual(item.kind, .episode)
        XCTAssertEqual(parsed.mediaID, "cashmere.episode.faulendes-holz-faul5-w-excel-rose")
        XCTAssertEqual(item.genres, ["Krautrock", "Wave"])
    }

    /// Some Mixcloud links are written into WordPress without a scheme.
    func testMixcloudLinksWithoutASchemeStillResolve() throws {
        let json = """
        {"slug":"x","title":"X","acf":{"episodeMixcloudLink":"mixcloud.com/CashmereRadio/a-show/"}}
        """
        let parsed = try XCTUnwrap(decode(CashmereEpisodeDTO.self, json).asEpisode())

        XCTAssertEqual(parsed.mixcloudURL?.absoluteString, "https://mixcloud.com/CashmereRadio/a-show/")
        XCTAssertTrue(parsed.isPlayable)
    }

    func testAnEpisodeWithNoRecordingIsStillAnEpisode() throws {
        let json = """
        {"slug":"x","title":"Not yet uploaded","acf":{"episodeMixcloudLink":"  "}}
        """
        let parsed = try XCTUnwrap(decode(CashmereEpisodeDTO.self, json).asEpisode())

        XCTAssertFalse(parsed.isPlayable)
        XCTAssertNil(parsed.mediaItem(), "Nothing to hand the player")
    }

    func testAnEpisodeWithoutATitleIsNotAnEpisode() throws {
        XCTAssertNil(try decode(CashmereEpisodeDTO.self, #"{"slug":"x","title":""}"#).asEpisode())
        XCTAssertNil(try decode(CashmereEpisodeDTO.self, #"{"title":"Orphan"}"#).asEpisode())
    }

    // MARK: - Shows and streams

    func testCategoriesAreTheShows() throws {
        let json = #"{"databaseId":318,"name":"12’ Bar Ramblin’","slug":"12-bar-ramblin","count":72}"#
        let show = try XCTUnwrap(decode(CategoryDTO.self, json).asShow())

        XCTAssertEqual(show.name, "12’ Bar Ramblin’")
        XCTAssertEqual(show.slug, "12-bar-ramblin")
        XCTAssertEqual(show.episodeCount, 72)
    }

    func testStreamsNeedAnAddressToBeStreams() throws {
        let good = #"{"databaseId":1,"title":"Cashmere Flume","slug":"cashmere-flume","acf":{"mp3Stream":"https://flume.cashmereradio.com/listen/x/stream.mp3"}}"#
        let stream = try XCTUnwrap(decode(CashmereStreamDTO.self, good).asStream())
        XCTAssertEqual(stream.title, "Cashmere Flume")
        XCTAssertEqual(stream.url.host, "flume.cashmereradio.com")

        let empty = #"{"title":"Broken","slug":"broken","acf":{"mp3Stream":""}}"#
        XCTAssertNil(try decode(CashmereStreamDTO.self, empty).asStream())
    }

    // MARK: - The GraphQL envelope

    func testConnectionsFlattenToNodes() throws {
        let json = """
        {"pageInfo":{"hasNextPage":true,"endCursor":"YXJyYXk6MzM0NzQ="},
         "edges":[{"node":{"slug":"a","title":"A"}},{"node":{"slug":"b","title":"B"}}]}
        """
        let connection = try decode(CashmereConnection<CashmereEpisodeDTO>.self, json)

        XCTAssertEqual(connection.nodes.compactMap(\.slug), ["a", "b"])
        XCTAssertEqual(connection.pageInfo?.hasNextPage, true)
        XCTAssertEqual(connection.pageInfo?.endCursor, "YXJyYXk6MzM0NzQ=")
    }

    func testGraphQLErrorsAreCarriedRatherThanSwallowed() throws {
        let json = """
        {"errors":[{"message":"Variable \\"$search\\" is never used."}]}
        """
        struct Payload: Decodable, Sendable { let episodes: CashmereConnection<CashmereEpisodeDTO>? }
        let response = try decode(CashmereResponse<Payload>.self, json)

        XCTAssertNil(response.data)
        XCTAssertEqual(response.errors?.first?.message, "Variable \"$search\" is never used.")
    }

    // MARK: - Live

    /// Airtime is shared with dublab, but Cashmere runs on Berlin time and
    /// points its show links at its own site.
    func testLiveInfoReadsBerlinTimeAndTheShowLink() throws {
        let json = """
        {"station":{"timezone":"Europe/Berlin"},
         "shows":{"previous":[],
                  "current":{"name":"deep fried dj","starts":"2026-08-29 16:30:00",
                             "ends":"2026-08-29 18:00:00",
                             "url":"https://cashmereradio.com/shows/deep-fried-dj"},
                  "next":[{"name":"Morphing Fields","starts":"2026-08-29 18:00:00","ends":"2026-08-29 19:00:00"}]},
         "tracks":{"current":{"metadata":{"track_title":"OBSCURED Episode 51","artist_name":"Cashmere"}}}}
        """
        let parsed = try decode(AirtimeLiveInfoDTO.self, json)
        let zone = parsed.timeZone(default: "Europe/Berlin")

        XCTAssertEqual(zone.identifier, "Europe/Berlin")
        XCTAssertEqual(parsed.shows?.current?.name, "deep fried dj")
        XCTAssertEqual(parsed.shows?.next.count, 1)
        XCTAssertNotNil(AirtimeTimestamp.parse(parsed.shows?.current?.starts, zone: zone))
        XCTAssertEqual(parsed.tracks?.current?.metadata?.track_title, "OBSCURED Episode 51")
    }

    func testOnAirReportsHowFarThroughTheShowIs() {
        let start = Date.now.addingTimeInterval(-900)
        let onAir = CashmereOnAir(
            showName: "deep fried dj",
            showStartsAt: start,
            showEndsAt: start.addingTimeInterval(1800),
            showSlug: "deep-fried-dj",
            trackTitle: "OBSCURED",
            trackArtist: nil,
            upNext: []
        )
        XCTAssertEqual(try XCTUnwrap(onAir.elapsedFraction), 0.5, accuracy: 0.02)
        XCTAssertEqual(onAir.asRadioShow()?.location, "Berlin")
        XCTAssertEqual(onAir.asRadioShow()?.detailID, "deep-fried-dj")
    }

    func testSearchNeedsTwoCharactersToBeASearch() {
        XCTAssertFalse(CashmereBrowseStore.isSearchTerm(""))
        XCTAssertFalse(CashmereBrowseStore.isSearchTerm("j"))
        XCTAssertFalse(CashmereBrowseStore.isSearchTerm("  j  "), "Whitespace is not a character")
        XCTAssertTrue(CashmereBrowseStore.isSearchTerm("jazz"))
    }
}
