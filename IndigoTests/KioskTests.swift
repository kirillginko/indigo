//
//  KioskTests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on www.kioskradio.com.
//

import XCTest
@testable import Indigo

final class KioskTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: Episodes

    private let episode = """
    {"sys":{"id":"5gpSUSOsLY0n9xSeYCHqhG"},
     "title":"Outsiders: Honey Trap w/ Amelia Holt &amp; Co",
     "date":"2026-08-27T21:00:00.000Z",
     "linkSoundcloud":"https://soundcloud.com/kioskradio/outsiders-honey-trap-w-7?utm_medium=api&utm_source=id_314564",
     "linkMixcloud":"https://mixcloud.com/KioskRadio/outsiders-honey-trap/",
     "image":{"url":"https://images.ctfassets.net/cp7twrvu7vxo/x/kiosk.jpg"},
     "genresCollection":{"items":[{"name":"Synth Pop"},{"name":"New Wave"},null]},
     "slug":"/episode/2026-08-27/outsiders-honey-trap-w-amelia-holt"}
    """

    func testEpisodeParsesAndPrefersSoundCloud() throws {
        let parsed = try XCTUnwrap(decode(KioskEpisodeDTO.self, episode).asEpisode())

        XCTAssertEqual(parsed.id, "/episode/2026-08-27/outsiders-honey-trap-w-amelia-holt")
        XCTAssertEqual(parsed.title, "Outsiders: Honey Trap w/ Amelia Holt & Co", "Entities must be decoded")
        XCTAssertEqual(parsed.genres, ["Synth Pop", "New Wave"], "Unresolved Contentful links are holes, not failures")
        XCTAssertEqual(parsed.audio?.provider, .soundcloud)
        XCTAssertEqual(
            parsed.audio?.url.absoluteString,
            "https://soundcloud.com/kioskradio/outsiders-honey-trap-w-7",
            "Share tracking must be stripped before the widget sees the link"
        )
    }

    /// Contentful stamps episodes with fractional seconds; the calendar uses a
    /// Brussels offset and none. Both have to parse.
    func testBothTimestampFlavoursParse() {
        XCTAssertNotNil(KioskTimestamp.parse("2026-08-27T21:00:00.000Z"))
        XCTAssertNotNil(KioskTimestamp.parse("2026-08-28T14:00:00+02:00"))
        XCTAssertNil(KioskTimestamp.parse(nil))
        XCTAssertNil(KioskTimestamp.parse("yesterday"))
    }

    func testEpisodeWithoutAudioIsNotPlayable() throws {
        let json = """
        {"title":"Ofra","date":"2026-08-20T10:00:00.000Z","slug":"/episode/2026-08-20/ofra",
         "linkSoundcloud":null,"linkMixcloud":null,"image":{"url":"https://images.example/o.jpg"},
         "genresCollection":{"items":[]}}
        """
        let parsed = try XCTUnwrap(decode(KioskEpisodeDTO.self, json).asEpisode())
        XCTAssertFalse(parsed.isPlayable)
        XCTAssertNil(parsed.mediaItem())
    }

    func testEpisodeFallsBackToMixcloud() throws {
        let json = """
        {"title":"Brokers","date":"2026-08-20T10:00:00.000Z","slug":"/episode/2026-08-20/brokers",
         "linkSoundcloud":null,"linkMixcloud":"https://mixcloud.com/KioskRadio/brokers/",
         "genresCollection":{"items":[]}}
        """
        let parsed = try XCTUnwrap(decode(KioskEpisodeDTO.self, json).asEpisode())
        XCTAssertEqual(parsed.audio?.provider, .mixcloud)
        XCTAssertEqual(parsed.mediaItem()?.embedProvider, .mixcloud)
        XCTAssertEqual(parsed.mediaItem()?.kind, .episode)
    }

    func testEpisodePageCarriesDescriptionTracklistAndResidency() throws {
        let json = """
        {"props":{"pageProps":{"episode":{
          "title":"The Morning Show w/ Shorlax & Rick Shiver",
          "description":"An open-eared morning session.",
          "date":"2025-08-22T00:00:00.000Z",
          "trackList":"Aix Em Klemm - The Luxury Of Dirt\\nAV Moves - Sorry Too Much",
          "slug":"/episode/2025-08-22/the-morning-show",
          "show":{"name":"The Morning Show","slug":"/show/the-morning-show"},
          "genresCollection":{"items":[{"name":"Ambient"}]},
          "linkSoundcloud":"https://soundcloud.com/kioskradio/morning"
        }}}}
        """
        let page = try decode(KioskEpisodePageData.self, json)
        let dto = page.props.pageProps.episode
        let parsed = try XCTUnwrap(dto.asEpisode(fallbackSlug: "fallback"))
        XCTAssertEqual(parsed.title, "The Morning Show w/ Shorlax & Rick Shiver")
        XCTAssertEqual(dto.description, "An open-eared morning session.")
        XCTAssertEqual(dto.trackList?.components(separatedBy: "\n").count, 2)
        XCTAssertEqual(dto.show?.slug, "/show/the-morning-show")
    }

    func testShowPageCarriesRelatedEpisodes() throws {
        let json = """
        {"props":{"pageProps":{
          "show":{"name":"The Morning Show","excerpt":"Weekly on Fridays.","when":"Fridays, 9am"},
          "episodes":[\(episode)]
        }}}
        """
        let page = try decode(KioskShowPageData.self, json)
        XCTAssertEqual(page.props.pageProps.show.excerpt, "Weekly on Fridays.")
        XCTAssertEqual(page.props.pageProps.episodes?.compactMap { $0.asEpisode() }.count, 1)
    }

    // MARK: Moods

    /// The playlists only exist inside the page's `__NEXT_DATA__` island, and
    /// the sections around them are a different shape entirely — decoding has
    /// to walk past those rather than fail on them.
    func testMoodsSurviveHeterogeneousSections() throws {
        let html = """
        <html><head><title>Moods</title></head><body><div id="__next">…</div>
        <script id="__NEXT_DATA__" type="application/json">
        {"props":{"pageProps":{"page":{"sectionsCollection":{"items":[
          {"__typename":"SectionTextHeader","title":"Moods","dark":false},
          {"__typename":"SectionPlaylistGrid","title":"Main Playlist Grid","playlistsCollection":{"items":[
            {"sys":{"id":"5zHHBwKhqlDhdUcqc3ZxkT"},"title":"Quiet Quitting",
             "image":{"url":"https://images.example/quiet.gif"},
             "episodesCollection":{"items":[
               {"title":"Jo G","date":"2026-07-09T14:00:00.000Z","slug":"/episode/2026-07-09/jo-g",
                "linkSoundcloud":"https://soundcloud.com/kioskradio/jo-g?utm_medium=api",
                "genresCollection":{"items":[{"name":"Balearic"}]}},
               {"title":"Jo G","date":"2026-07-09T14:00:00.000Z","slug":"/episode/2026-07-09/jo-g",
                "linkSoundcloud":"https://soundcloud.com/kioskradio/jo-g","genresCollection":{"items":[]}},
               null
             ]}}
          ]}}
        ]}}}},"buildId":"abc","page":"/[page]"}
        </script></body></html>
        """

        let payload = try XCTUnwrap(KioskAPI.nextDataPayload(in: html))
        let moods = try decode(KioskNextData.self, payload).playlists.compactMap { $0.asMood() }

        XCTAssertEqual(moods.count, 1)
        XCTAssertEqual(moods[0].title, "Quiet Quitting")
        XCTAssertEqual(moods[0].episodes.count, 1, "The same show filed twice is one entry")
        XCTAssertEqual(moods[0].episodes[0].title, "Jo G")
        XCTAssertEqual(moods[0].mediaItems().count, 1)
    }

    func testMissingNextDataIslandIsReported() {
        XCTAssertNil(KioskAPI.nextDataPayload(in: "<html><body>Down for maintenance</body></html>"))
    }

    // MARK: Schedule

    private let calendar = """
    [{"id":0,"summary":"Adriaan de Roover","start":"2026-08-28T14:00:00+02:00",
      "end":"2026-08-28T15:00:00+02:00","timezone":"Europe/Brussels"},
     {"id":1,"summary":"Slagwerk w/ La Bug","start":"2026-08-28T15:00:00+02:00",
      "end":"2026-08-28T16:00:00+02:00","timezone":"Europe/Brussels"}]
    """

    func testScheduleEntriesParse() throws {
        let entries = try decode([KioskCalendarEntryDTO].self, calendar).compactMap { $0.asScheduleEntry() }

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].title, "Slagwerk w/ La Bug")
        XCTAssertEqual(entries[1].showName, "Slagwerk", "Guest billing isn't part of the residency name")
        XCTAssertEqual(entries[0].showName, "Adriaan de Roover")
        XCTAssertTrue(entries[0].contains(entries[0].startsAt))
        XCTAssertFalse(entries[0].contains(entries[0].endsAt), "A slot ends where the next one starts")
    }

    func testEntriesWithoutUsableTimesAreDropped() throws {
        let json = """
        [{"id":0,"summary":"Broken","start":null,"end":"2026-08-28T15:00:00+02:00"},
         {"id":1,"summary":"","start":"2026-08-28T15:00:00+02:00","end":"2026-08-28T16:00:00+02:00"},
         {"id":2,"summary":"Backwards","start":"2026-08-28T16:00:00+02:00","end":"2026-08-28T15:00:00+02:00"}]
        """
        let entries = try decode([KioskCalendarEntryDTO].self, json).compactMap { $0.asScheduleEntry() }
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: Search

    func testSearchResponseYieldsEpisodesAndShows() throws {
        let json = """
        {"showCollection":{"items":[{"name":"Slagwerk","photo":{"url":"https://images.example/s.jpg"}},null]},
         "labelCollection":{"items":[]},
         "episodeCollection":{"items":[
           {"title":"Slagwerk w/ La Bug","date":"2026-08-28T13:00:00.000Z",
            "slug":"/episode/2026-08-28/slagwerk-w-la-bug",
            "linkSoundcloud":"https://soundcloud.com/kioskradio/slagwerk","genresCollection":{"items":[]}}]}}
        """
        let response = try decode(KioskSearchResponse.self, json)

        XCTAssertEqual(response.showCollection?.items.first?.name, "Slagwerk")
        let episodes = (response.episodeCollection?.items ?? []).compactMap { $0.asEpisode() }
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].mediaItem()?.id, episodes[0].mediaID)
        XCTAssertEqual(episodes[0].mediaID, "kiosk.episode./episode/2026-08-28/slagwerk-w-la-bug")
    }
}
