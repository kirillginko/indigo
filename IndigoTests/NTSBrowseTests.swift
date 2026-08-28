//
//  NTSBrowseTests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on www.nts.live/api/v2.
//

import XCTest
@testable import Indigo

final class NTSBrowseTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: Tracklist shape

    /// NTS sends `"tracklist": {...}` when there is one and `"tracklist": []`
    /// when there isn't. Decoding it as one fixed shape throws on every
    /// episode that hasn't aired yet.
    private let publishedEpisode = """
    {"status":"published","name":"Scary Things w/ Nav","description":"UK drill.",
     "episode_alias":"scary-things-13th-august-2026","show_alias":"scary-things",
     "broadcast":"2026-08-13T17:00:00+00:00","location_long":"London","location_short":"LDN",
     "genres":[{"id":"g1","value":"UK Drill"}],"moods":[{"id":"m1","value":"MAXIMUM EFFORT"}],
     "media":{"picture_large":"https://media.example/1600.jpg"},
     "mixcloud":"https://www.mixcloud.com/NTSRadio/scary-things/",
     "audio_sources":[{"url":"https://soundcloud.com/x/scary-things","source":"soundcloud"}],
     "embeds":{"tracklist":{"metadata":{"resultset":{"count":2,"offset":0,"limit":2}},
       "results":[
         {"artist":"Fimiguerrero","title":"Mind The Gap","uid":"a1","offset":13,"duration":105},
         {"artist":"Lancey Foux","title":"Blackbirds &amp; Co","uid":"a2","offset":125,"duration":195}]}}}
    """

    private let pendingEpisode = """
    {"status":"pending","name":"Scary Things w/ Nav","episode_alias":"scary-things-27th-august-2026",
     "show_alias":"scary-things","broadcast":"2026-08-27T17:00:00+00:00",
     "media":{},"audio_sources":[],"embeds":{"tracklist":[]}}
    """

    func testPublishedEpisodeParsesItsTracklist() throws {
        let detail = try XCTUnwrap(decode(NTSEpisodeDTO.self, publishedEpisode).asDetail())

        XCTAssertEqual(detail.tracklist.count, 2)
        XCTAssertEqual(detail.tracklist[0].title, "Mind The Gap")
        XCTAssertEqual(detail.tracklist[0].artist, "Fimiguerrero")
        XCTAssertEqual(detail.tracklist[0].offsetLabel, "0:13")
        XCTAssertEqual(detail.tracklist[1].title, "Blackbirds & Co", "Entities must be decoded")
        XCTAssertEqual(detail.tracklist[1].offsetLabel, "2:05")
        XCTAssertTrue(detail.summary.isPublished)
    }

    func testEmptyTracklistArrayDoesNotFailDecoding() throws {
        let detail = try XCTUnwrap(decode(NTSEpisodeDTO.self, pendingEpisode).asDetail())
        XCTAssertTrue(detail.tracklist.isEmpty)
        XCTAssertFalse(detail.summary.isPublished)
    }

    func testOffsetEstimateIsUsedWhenTheExactOffsetIsMissing() throws {
        let json = """
        {"status":"published","name":"X","episode_alias":"x-1","show_alias":"x",
         "embeds":{"tracklist":{"results":[
           {"artist":"A","title":"Untimed","uid":"u1","offset":null,"offset_estimate":null},
           {"artist":"B","title":"Estimated","uid":"u2","offset":null,"offset_estimate":154}]}}}
        """
        let detail = try XCTUnwrap(decode(NTSEpisodeDTO.self, json).asDetail())
        XCTAssertNil(detail.tracklist[0].offsetLabel, "No offset at all means no timestamp")
        XCTAssertEqual(detail.tracklist[1].offsetLabel, "2:34")
    }

    func testAudioSourcesBecomeExternalLinks() throws {
        let detail = try XCTUnwrap(decode(NTSEpisodeDTO.self, publishedEpisode).asDetail())
        XCTAssertEqual(detail.audio.map(\.displayName), ["SoundCloud"])
    }

    func testMixcloudIsUsedWhenThereAreNoAudioSources() throws {
        let json = """
        {"status":"published","name":"X","episode_alias":"x-1","show_alias":"x",
         "audio_sources":[],"mixcloud":"https://www.mixcloud.com/NTSRadio/x/","embeds":{"tracklist":[]}}
        """
        let detail = try XCTUnwrap(decode(NTSEpisodeDTO.self, json).asDetail())
        XCTAssertEqual(detail.audio.map(\.displayName), ["Mixcloud"])
    }

    func testEpisodeWithoutAliasesIsDropped() throws {
        let json = """
        {"status":"published","name":"Orphan","embeds":{"tracklist":[]}}
        """
        XCTAssertNil(try decode(NTSEpisodeDTO.self, json).asDetail())
    }

    // MARK: Pages

    func testShowPageDecodesAndReportsTotal() throws {
        let json = """
        {"metadata":{"resultset":{"count":1732,"offset":0,"limit":12}},
         "results":[{"name":"100 Elements w/ YL ","description":"Beats.","show_alias":"100-elements",
                     "location_long":"New York","location_short":"NYC",
                     "genres":[{"id":"g","value":"Hip Hop "}],
                     "media":{"picture_medium":"https://media.example/400.jpg"}}]}
        """
        let page = try decode(NTSPage<NTSShowDTO>.self, json)
        XCTAssertEqual(page.total, 1732)

        let show = try XCTUnwrap(page.results.first?.asSummary())
        XCTAssertEqual(show.alias, "100-elements")
        XCTAssertEqual(show.name, "100 Elements w/ YL", "Trailing whitespace should be trimmed")
        XCTAssertEqual(show.location, "New York")
        XCTAssertEqual(show.genres, ["Hip Hop "])
    }

    func testMixtapeMapsToAPlayableStream() throws {
        let json = """
        {"results":[{"mixtape_alias":"poolside","title":"Poolside",
          "subtitle":"Balearic, boogie, and sophisti-pop.",
          "description":"Sun-kissed mixes.",
          "audio_stream_endpoint":"https://stream-mixtape-geo.ntslive.net/mixtape4",
          "media":{"picture_large":"https://media.example/pool.jpg"}}]}
        """
        let page = try decode(NTSPage<NTSMixtapeDTO>.self, json)
        let mixtape = try XCTUnwrap(page.results.first?.asMixtape())
        XCTAssertEqual(mixtape.alias, "poolside")
        XCTAssertEqual(mixtape.streamURL.absoluteString,
                       "https://stream-mixtape-geo.ntslive.net/mixtape4")
    }

    func testMixtapeWithoutAStreamIsDropped() throws {
        let json = """
        {"results":[{"mixtape_alias":"broken","title":"Broken"}]}
        """
        let page = try decode(NTSPage<NTSMixtapeDTO>.self, json)
        XCTAssertNil(page.results.first?.asMixtape())
    }

    // MARK: Episode references

    func testEpisodeRefRoundTrip() throws {
        XCTAssertEqual(NTSEpisodeRef.encode(show: "scary-things", episode: "st-1"),
                       "scary-things/st-1")

        let decoded = try XCTUnwrap(NTSEpisodeRef.decode("scary-things/st-1"))
        XCTAssertEqual(decoded.show, "scary-things")
        XCTAssertEqual(decoded.episode, "st-1")

        XCTAssertNil(NTSEpisodeRef.encode(show: "x", episode: nil))
        XCTAssertNil(NTSEpisodeRef.decode("no-slash"))
    }

    /// Episode aliases contain slashes nowhere, but dates do contain hyphens —
    /// splitting must stop after the first separator.
    func testEpisodeRefKeepsTrailingSegments() throws {
        let decoded = try XCTUnwrap(NTSEpisodeRef.decode("show/episode-27th-august-2026"))
        XCTAssertEqual(decoded.episode, "episode-27th-august-2026")
    }

    // MARK: Live payload still maps

    func testLiveShowCarriesAnEpisodeReference() throws {
        let json = """
        {"results":[{"channel_name":"1","now":{"broadcast_title":"SCARY THINGS",
          "start_timestamp":"2026-08-27T18:00:00+01:00","end_timestamp":"2026-08-27T20:00:00+01:00",
          "embeds":{"details":{"name":"Scary Things","show_alias":"scary-things",
                    "episode_alias":"scary-things-27th-august-2026"}}}}]}
        """
        let response = try decode(NTSLiveResponse.self, json)
        let show = try XCTUnwrap(response.results.first?.now?.asRadioShow())
        XCTAssertEqual(show.detailID, "scary-things/scary-things-27th-august-2026")
    }
}

// MARK: - Paging behaviour

@MainActor
final class NTSBrowseStoreTests: XCTestCase {
    /// Offset paging over a feed that keeps changing hands back items you have
    /// already seen; the grid must not end up with duplicate ids.
    // async on purpose: see the note in PlaybackCoordinatorTests about releasing
    // app-module main-actor objects inside a synchronous XCTest method.
    func testMediaItemForMixtapeIsALiveStream() async throws {
        let store = NTSBrowseStore()
        let mixtape = NTSMixtape(
            alias: "poolside", title: "Poolside", subtitle: "Balearic",
            summary: nil, artworkURL: nil,
            streamURL: URL(string: "https://stream-mixtape-geo.ntslive.net/mixtape4")!,
            credits: []
        )
        let item = store.mediaItem(for: mixtape)

        XCTAssertTrue(item.isLive)
        XCTAssertEqual(item.kind, MediaKind.radioStation)
        XCTAssertEqual(item.title, "Poolside")
        XCTAssertEqual(item.detail, "NTS Mixtape")
        XCTAssertTrue(item.id.hasPrefix("nts.mixtape."))
        XCTAssertNil(item.duration, "A mixtape never ends")
    }

    func testEmptyFeedWantsAFirstPageThenStops() {
        var feed = NTSBrowseStore.Feed<NTSShowSummary>()
        XCTAssertTrue(feed.hasMore, "An untouched feed must be allowed to load once")

        feed.hasLoadedOnce = true
        feed.total = 0
        XCTAssertFalse(feed.hasMore)

        feed.total = 24
        feed.items = []
        XCTAssertTrue(feed.hasMore)
    }
}
