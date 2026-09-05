//
//  IdaTests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on strapi.idaidaida.net. Two things
//  about IDA are unlike the other stations Indigo reads, and most of this is
//  about them: it broadcasts on two channels at once, and it stores its audio
//  links as bare paths rather than addresses — a good many of them carrying
//  Estonian letters, which `URL(string:)` refuses outright.
//

import XCTest
@testable import Indigo

final class IdaTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Episodes

    private let episode = """
    {"id":24797,"title":"USVA 02-09-2026","slug":"usva-02-09-2026","subtitle":null,
     "isRepeat":false,"start":"2026-09-02T12:00:00.000Z","end":"2026-09-02T13:00:00.000Z",
     "mixcloud":"IDA_RAADIO/usva-020926/","soundcloud":"ida_radio/usva-02-09-26",
     "tracklist":"Arcologies - Spirals in Time and Space [Omni Music 2024]\\n\\nKoda - The Deep [Dee Jay 1994]\\n\\n- Dillinja - The Angels Fell\\n",
     "show":{"id":18,"slug":"usva","title":"USVA","artist":"DJ USVA","alternativeArtistName":null,
             "featuredImage":{"url":"https://ida-radio.fra1.digitaloceanspaces.com/uploads/show.jpg",
                              "formats":{"thumbnail":{"url":"https://x/thumb.jpg","width":156},
                                         "small":{"url":"https://x/small.jpg","width":500},
                                         "large":{"url":"https://x/large.jpg","width":1000}}}},
     "genres":[{"id":1,"title":"Drum & bass","slug":"dnb"},{"id":2,"title":"","slug":"blank"}],
     "channel":{"id":2,"title":"Helsinki","slug":"helsinki"},
     "featuredImage":null}
    """

    func testEpisodeParses() throws {
        let parsed = try XCTUnwrap(decode(IdaEpisodeDTO.self, episode).asEpisode())

        XCTAssertEqual(parsed.slug, "usva-02-09-2026")
        XCTAssertEqual(parsed.title, "USVA 02-09-2026")
        XCTAssertEqual(parsed.showSlug, "usva")
        XCTAssertEqual(parsed.showTitle, "USVA")
        XCTAssertEqual(parsed.showArtist, "DJ USVA")
        XCTAssertEqual(parsed.genres, ["Drum & bass"], "A blank genre is not a genre")
        XCTAssertEqual(parsed.channel, .helsinki)
        XCTAssertEqual(parsed.broadcastLabel, "2 Sep 2026")
        XCTAssertTrue(parsed.isPlayable)
    }

    /// IDA publishes no duration; the slot it scheduled is the only length it
    /// states, and it schedules to the hour.
    func testDurationComesFromTheSlot() throws {
        let parsed = try XCTUnwrap(decode(IdaEpisodeDTO.self, episode).asEpisode())
        XCTAssertEqual(try XCTUnwrap(parsed.duration), 3600, accuracy: 1)
    }

    /// Most episodes carry no picture of their own — IDA art-directs the show,
    /// not the week — so the grid would be all placeholder without this.
    func testEpisodeInheritsTheShowsArtwork() throws {
        let parsed = try XCTUnwrap(decode(IdaEpisodeDTO.self, episode).asEpisode())
        XCTAssertEqual(
            parsed.imageURL?.absoluteString,
            "https://ida-radio.fra1.digitaloceanspaces.com/uploads/show.jpg"
        )
    }

    /// The smallest derivative wide enough for the tile, rather than the
    /// original upload — which for IDA is routinely a 3000px camera JPEG.
    func testThumbnailPicksTheSmallestSufficientSize() throws {
        let parsed = try XCTUnwrap(decode(IdaEpisodeDTO.self, episode).asEpisode())
        XCTAssertEqual(parsed.thumbnailURL?.absoluteString, "https://x/small.jpg")
    }

    // MARK: - Playback

    /// SoundCloud's widget seeks where Mixcloud's does not, so it leads — and
    /// the copy IDA also published rides along rather than being dropped.
    func testSoundCloudLeadsWithMixcloudAsTheFallback() throws {
        let parsed = try XCTUnwrap(decode(IdaEpisodeDTO.self, episode).asEpisode())
        let item = try XCTUnwrap(parsed.mediaItem())

        XCTAssertEqual(item.id, "ida.episode.usva-02-09-2026")
        XCTAssertEqual(item.sourceID, "ida")
        XCTAssertEqual(item.embedProvider, .soundcloud)
        XCTAssertEqual(item.playbackURL.absoluteString, "https://soundcloud.com/ida_radio/usva-02-09-26")
        XCTAssertEqual(item.alternateEmbedProvider, .mixcloud)
        XCTAssertEqual(
            item.alternatePlaybackURL?.absoluteString,
            "https://www.mixcloud.com/IDA_RAADIO/usva-020926/"
        )
    }

    func testMixcloudIsUsedWhenThereIsNoSoundCloud() throws {
        let json = episode.replacingOccurrences(
            of: "\"soundcloud\":\"ida_radio/usva-02-09-26\"",
            with: "\"soundcloud\":null"
        )
        let parsed = try XCTUnwrap(decode(IdaEpisodeDTO.self, json).asEpisode())
        let item = try XCTUnwrap(parsed.mediaItem())

        XCTAssertEqual(item.embedProvider, .mixcloud)
        XCTAssertNil(item.alternatePlaybackURL, "There is nothing left to fall back to")
    }

    /// IDA schedules further ahead than it broadcasts, so an episode with no
    /// recording yet is normal — and must not look playable.
    func testAnEpisodeWithNoRecordingIsNotPlayable() throws {
        let json = episode
            .replacingOccurrences(of: "\"soundcloud\":\"ida_radio/usva-02-09-26\"", with: "\"soundcloud\":null")
            .replacingOccurrences(of: "\"mixcloud\":\"IDA_RAADIO/usva-020926/\"", with: "\"mixcloud\":null")
        let parsed = try XCTUnwrap(decode(IdaEpisodeDTO.self, json).asEpisode())

        XCTAssertFalse(parsed.isPlayable)
        XCTAssertNil(parsed.mediaItem())
    }

    // MARK: - Links

    /// The station's Estonian titles reach the paths it stores, and
    /// `URL(string:)` returns nil for those outright — which silently cost
    /// every such episode its audio until the path was encoded.
    func testEstonianLettersInAPathStillMakeAURL() {
        let url = IdaLink.mixcloud("IDA_RAADIO/müra-020926/")
        XCTAssertEqual(url?.absoluteString, "https://www.mixcloud.com/IDA_RAADIO/m%C3%BCra-020926/")

        let other = IdaLink.mixcloud("IDA_RAADIO/vojaaž-020926/")
        XCTAssertEqual(other?.absoluteString, "https://www.mixcloud.com/IDA_RAADIO/vojaa%C5%BE-020926/")
    }

    func testLinksTolerateTheShapesTheFieldActuallyHolds() {
        XCTAssertNil(IdaLink.soundcloud(nil))
        XCTAssertNil(IdaLink.soundcloud(""))
        XCTAssertNil(IdaLink.soundcloud("   "))
        XCTAssertEqual(
            IdaLink.soundcloud("/ida_radio/show")?.absoluteString,
            "https://soundcloud.com/ida_radio/show",
            "A leading slash must not become a double one"
        )
        XCTAssertEqual(
            IdaLink.mixcloud("https://www.mixcloud.com/IDA_RAADIO/already/")?.absoluteString,
            "https://www.mixcloud.com/IDA_RAADIO/already/",
            "A handful of records were entered as full addresses"
        )
    }

    // MARK: - Prose

    /// IDA writes in three languages and fills in whichever it has. A show
    /// with only an Estonian note has something to say.
    func testDescriptionPrefersEnglishButFallsBack() {
        XCTAssertEqual(
            IdaText.description(english: "In English", estonian: "Eesti keeles", finnish: nil),
            "In English"
        )
        XCTAssertEqual(
            IdaText.description(english: nil, estonian: "Eesti keeles", finnish: "Suomeksi"),
            "Eesti keeles"
        )
        XCTAssertEqual(
            IdaText.description(english: "   ", estonian: nil, finnish: "Suomeksi"),
            "Suomeksi",
            "A field of whitespace is not a description"
        )
        XCTAssertNil(IdaText.description(english: nil, estonian: nil, finnish: nil))
    }

    /// IDA logs a track a paragraph, so the blank lines between them must not
    /// become empty rows.
    func testTracklistIsOnePerLineWithBulletsStripped() throws {
        let parsed = try XCTUnwrap(decode(IdaEpisodeDTO.self, episode).asEpisode())

        XCTAssertEqual(parsed.tracks, [
            "Arcologies - Spirals in Time and Space [Omni Music 2024]",
            "Koda - The Deep [Dee Jay 1994]",
            "Dillinja - The Angels Fell"
        ])
    }

    // MARK: - Live

    private let live = """
    {"tallinn":{"id":24886,"title":"Fiktsioon 02-09-2026","slug":"fiktsioon-02-09-2026",
      "start":"2026-09-02T13:00:00.000Z","end":"2026-09-02T14:00:00.000Z","isRepeat":false,
      "subtitle":null,"streamSrc":"https://broadcast.idaidaida.net:8000/stream",
      "genres":[{"id":147,"title":"Breaks","slug":"breaks"}],
      "channel":{"id":1,"title":"Tallinn","slug":"tallinn"},
      "show":{"id":299,"slug":"fiktsioon","title":"Fiktsioon","artist":"Paul Sild"},
      "featuredImage":null},
     "helsinki":{"id":24798,"title":"D1VARI 02-09-2026","slug":"d1vari-02-09-2026",
      "start":"2026-09-02T13:00:00.000Z","end":"2026-09-02T14:00:00.000Z","isRepeat":false,
      "subtitle":null,"streamSrc":"https://broadcast.idaidaida.net:8030/stream",
      "genres":[],"channel":{"id":2,"title":"Helsinki","slug":"helsinki"},
      "show":{"id":507,"slug":"d1vari","title":"D1VARI","artist":"D1VARI"},
      "featuredImage":null},
     "nextTallinn":{"id":24887,"start":"2026-09-02T14:00:00.000Z",
                    "show":{"id":540,"slug":"joga-donk","title":"joga donk"}},
     "nextHelsinki":{"id":24799,"start":"2026-09-02T14:00:00.000Z",
                     "show":{"id":353,"slug":"sporadic","title":"Sporadic"}}}
    """

    /// Both channels come back in one call, each with its own stream — which
    /// is the only place IDA publishes those addresses.
    func testLiveCarriesBothChannelsAndBothStreams() throws {
        let parsed = try decode(IdaLiveDTO.self, live).asLive()

        let tallinn = try XCTUnwrap(parsed.channels[.tallinn])
        XCTAssertEqual(tallinn.episode?.title, "Fiktsioon 02-09-2026")
        XCTAssertEqual(tallinn.episode?.showArtist, "Paul Sild")
        XCTAssertEqual(tallinn.streamURL?.absoluteString, "https://broadcast.idaidaida.net:8000/stream")
        XCTAssertEqual(tallinn.nextTitle, "joga donk")
        XCTAssertTrue(tallinn.isOnAir)

        let helsinki = try XCTUnwrap(parsed.channels[.helsinki])
        XCTAssertEqual(helsinki.episode?.title, "D1VARI 02-09-2026")
        XCTAssertEqual(helsinki.streamURL?.absoluteString, "https://broadcast.idaidaida.net:8030/stream")
        XCTAssertEqual(helsinki.nextTitle, "Sporadic")
        XCTAssertNotEqual(
            tallinn.streamURL, helsinki.streamURL,
            "Two channels means two schedules, not one relayed twice"
        )
    }

    /// The bar asks "what is on this station?" by source, and answers for
    /// IDA by finding the channel behind the playing id and reading its
    /// state. That lookup is what `PlayerBarView.liveShow` and
    /// `MiniPlayerView.liveShow` were missing: IDA fell through to asking NTS
    /// about an IDA channel id, got nothing, and so had no picture in the
    /// bar, no show title, and no way to open the panel — which is gated on
    /// there being a show at all.
    ///
    /// This pins the lookup. The two `liveShow` switches themselves are not
    /// reachable from a test here.
    func testAPlayingChannelCanBeTracedBackToWhatIsOnIt() throws {
        let parsed = try decode(IdaLiveDTO.self, live).asLive()

        for channel in [IdaChannel.tallinn, IdaChannel.helsinki] {
            // The id the player carries for a live IDA stream.
            let stationID = channel.stationID
            let found = try XCTUnwrap(
                IdaChannel.allCases.first { $0.stationID == stationID },
                "The station id has to lead back to its channel"
            )
            XCTAssertEqual(found, channel)

            let state = try XCTUnwrap(parsed.channels[found])
            let show = try XCTUnwrap(
                state.asRadioShow(city: found.city),
                "A channel that is on air is showing something"
            )
            XCTAssertFalse(show.title.isEmpty, "Which the bar shows instead of the channel name")
        }

        // And why the station's own mark has to be a real image: IDA
        // publishes `featuredImage: null` for a channel that is on air, so
        // there is often nothing else for the bar to show.
        for channel in [IdaChannel.tallinn, IdaChannel.helsinki] {
            let state = try XCTUnwrap(parsed.channels[channel])
            XCTAssertNil(state.episode?.imageURL, "Nothing published for what is on")
        }
    }

    /// A channel that is off air must still be listenable, so the station
    /// falls back to the published address rather than losing the stream.
    func testAChannelOffAirStillHasAStream() throws {
        let json = live.replacingOccurrences(of: "\"helsinki\":{", with: "\"helsinki\":null,\"unused\":{")
        let parsed = try decode(IdaLiveDTO.self, json).asLive()

        let helsinki = try XCTUnwrap(parsed.channels[.helsinki])
        XCTAssertFalse(helsinki.isOnAir)
        XCTAssertNil(helsinki.streamURL)
        XCTAssertEqual(
            IdaChannel.helsinki.fallbackStream.absoluteString,
            "https://broadcast.idaidaida.net:8030/stream"
        )
    }

    func testChannelsMapFromTheirSlugs() {
        XCTAssertEqual(IdaChannel.named("tallinn"), .tallinn)
        XCTAssertEqual(IdaChannel.named("Helsinki"), .helsinki)
        // IDA has run pop-up channels with no slug at all.
        XCTAssertNil(IdaChannel.named(nil))
        XCTAssertNil(IdaChannel.named("soca"))
    }

    /// IDA is an Estonian station, but the Helsinki studio is not in Estonia —
    /// which is what the page said when the country was written once for both.
    func testEachChannelCarriesItsOwnCountry() {
        XCTAssertEqual(IdaChannel.tallinn.location, "Tallinn, Estonia")
        XCTAssertEqual(IdaChannel.helsinki.location, "Helsinki, Finland")
    }

    /// The station ids are what the player and the sidebar key off, and the
    /// crate stores them — so they are not free to drift.
    func testStationIdentitiesAreStable() {
        XCTAssertEqual(IdaChannel.tallinn.stationID, "ida.tallinn")
        XCTAssertEqual(IdaChannel.helsinki.stationID, "ida.helsinki")
        XCTAssertEqual(IdaProvider.providerID, "ida")
    }

    // MARK: - Shows

    private let show = """
    {"id":418,"title":"(new) music w/ kulla","slug":"new-music-w-kulla","artist":null,
     "alternativeTitle":null,"alternativeArtistName":"kulla",
     "contentEst":"Klassikalise muusika valdkonnas.","contentEng":"When classical music is spoken about.",
     "contentFin":null,"archived":true,
     "genres":[{"id":158,"title":"Classical","slug":"classical"}],
     "channel":{"id":1,"title":"Tallinn","slug":"tallinn"},
     "featuredImage":{"url":"https://x/full.jpg","formats":{"small":{"url":"https://x/small.jpg","width":500}}}}
    """

    func testShowParses() throws {
        let parsed = try XCTUnwrap(decode(IdaShowDTO.self, show).asShow())

        XCTAssertEqual(parsed.slug, "new-music-w-kulla")
        XCTAssertEqual(parsed.title, "(new) music w/ kulla")
        XCTAssertEqual(parsed.artist, "kulla", "The alternative name stands in when there is no artist")
        XCTAssertEqual(parsed.summary, "When classical music is spoken about.")
        XCTAssertEqual(parsed.genres, ["Classical"])
        XCTAssertEqual(parsed.channel, .tallinn)
        XCTAssertTrue(parsed.isArchived, "IDA marks a finished show rather than deleting it")
    }

    /// `archived` is absent on most records rather than false.
    func testAShowWithNoArchivedFlagIsRunning() throws {
        let json = show.replacingOccurrences(of: "\"archived\":true", with: "\"archived\":null")
        let parsed = try XCTUnwrap(decode(IdaShowDTO.self, json).asShow())
        XCTAssertFalse(parsed.isArchived)
    }

    // MARK: - Genres

    /// IDA files the same tag under more than one capitalisation, and Strapi
    /// sorts capitals ahead of lowercase — which would show the listener two
    /// "Ambient"s and strand a run of genres at the bottom of the menu.
    func testGenresFoldDuplicatesAndSortAsRead() throws {
        let json = """
        {"data":[{"id":1,"title":"Techno","slug":"techno"},
                 {"id":2,"title":"ambient","slug":"ambient-lower"},
                 {"id":3,"title":"Ambient","slug":"ambient"},
                 {"id":4,"title":"  ","slug":"blank"},
                 {"id":5,"title":"breaks","slug":"breaks"}]}
        """
        let rows = try decode(IdaListResponse<IdaGenreDTO>.self, json).data
        var seen = Set<String>()
        let genres = rows
            .compactMap { $0.asGenre() }
            .filter { seen.insert($0.name.lowercased()).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        XCTAssertEqual(genres.map(\.name), ["ambient", "breaks", "Techno"])
    }

    // MARK: - Envelope

    /// Strapi answers a listing with the total alongside the rows, which is
    /// what tells the archive whether there is more to walk.
    func testListingEnvelopeCarriesTheTotal() throws {
        let json = """
        {"data":[],"meta":{"pagination":{"start":0,"limit":24,"total":20685}}}
        """
        let parsed = try decode(IdaListResponse<IdaEpisodeDTO>.self, json)
        XCTAssertEqual(parsed.total, 20685)
        XCTAssertTrue(parsed.data.isEmpty)
    }

    /// A record missing every optional field must not take the page down.
    func testASparseEpisodeStillDecodes() throws {
        let json = """
        {"id":1,"title":"Bare","slug":"bare"}
        """
        let parsed = try XCTUnwrap(decode(IdaEpisodeDTO.self, json).asEpisode())
        XCTAssertEqual(parsed.title, "Bare")
        XCTAssertTrue(parsed.genres.isEmpty)
        XCTAssertTrue(parsed.tracks.isEmpty)
        XCTAssertNil(parsed.duration)
        XCTAssertNil(parsed.channel)
        XCTAssertFalse(parsed.isPlayable)
    }

    /// A record with no slug has nothing to navigate to, so it is dropped
    /// rather than becoming a tile that opens an empty page.
    func testARecordWithNoSlugIsDropped() throws {
        XCTAssertNil(try decode(IdaEpisodeDTO.self, #"{"id":1,"title":"No slug"}"#).asEpisode())
        XCTAssertNil(try decode(IdaEpisodeDTO.self, #"{"id":1,"slug":"s","title":"  "}"#).asEpisode())
        XCTAssertNil(try decode(IdaShowDTO.self, #"{"id":1,"title":"No slug"}"#).asShow())
    }
}
