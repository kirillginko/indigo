//
//  RovrTests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on strapi.rovr.live. ROVR is unlike
//  the other stations in one structural way, and most of this is about it: the
//  station has no home timezone. The same programme goes out on twenty-one
//  streams, one an hour of UTC offset, and the schedule is expressed in
//  whatever wall clock it was asked in — so a time read as an instant, or a
//  stream picked without an offset, is quietly the wrong answer.
//

import XCTest
@testable import Indigo

final class RovrTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Broadcasts

    private let broadcast = """
    {"id":13176,"documentId":"akmu7s0gpz96egpcm0almrrc","title":"I Love It Loud 15",
     "soundcloudPermalinkUrl":"https://soundcloud.com/rovr-108499109/i-love-it-loud-13176-2026-09/s-Pw4hOT9zRyg?utm_medium=api&utm_campaign=social_sharing",
     "soundcloudEmbedUrl":"https://api.soundcloud.com/tracks/2388530769?secret_token=s-Pw4hOT9zRyg",
     "scheduleDate":"2026-09-02T00:00:00.000Z","releaseDate":"2026-09-02T00:00:00.000Z",
     "overwriteShowDescription":"Alternative Rock","overwriteShowName":null,"aiDescription":null,
     "showEpisodeNumber":15,"playlistProcessedAudioDuration":7200,
     "overwriteShowRadioImage":null,
     "playlistTags":[{"id":6,"label":"FUZZ","type":"grease","displayOrder":6,"visible":true},
                     {"id":9,"label":"HIDDEN","type":"hidden","displayOrder":9,"visible":false}],
     "show":{"id":328,"documentId":"cki0uqyqe07b0qj858kyo0p5","title":"I Love It Loud",
             "description":"Loud and dirty selections","frequency":"monthly","active":true,
             "radioImage":{"url":"https://rovr-prod.s3.amazonaws.com/full.png",
                           "formats":{"thumbnail":{"url":"https://x/t.png","width":156},
                                      "medium":{"url":"https://x/m.png","width":500}}}},
     "curator":{"id":32,"documentId":"YlH05e2eiVVZzyFX5uVG9","name":"Thomas Bornand",
                "countryCode":"FRA","urlSlug":"thomas-bornand"}}
    """

    func testBroadcastParses() throws {
        let parsed = try XCTUnwrap(decode(RovrBroadcastDTO.self, broadcast).asBroadcast())

        XCTAssertEqual(parsed.documentID, "akmu7s0gpz96egpcm0almrrc")
        XCTAssertEqual(parsed.title, "I Love It Loud 15")
        XCTAssertEqual(parsed.episodeNumber, 15)
        XCTAssertEqual(parsed.duration, 7200)
        XCTAssertEqual(parsed.showTitle, "I Love It Loud")
        XCTAssertEqual(parsed.curatorName, "Thomas Bornand")
        XCTAssertEqual(parsed.curatorID, "YlH05e2eiVVZzyFX5uVG9")
        XCTAssertEqual(parsed.mediaID, "rovr.broadcast.akmu7s0gpz96egpcm0almrrc")
        XCTAssertTrue(parsed.isPlayable)
    }

    /// SoundCloud's share tracking goes; the path must not. A private upload
    /// carries its secret token as a path segment, and a permalink tidied down
    /// to the bare track is one the widget will refuse to play.
    func testTheSecretTokenSurvivesButTheTrackingDoesNot() throws {
        let parsed = try XCTUnwrap(decode(RovrBroadcastDTO.self, broadcast).asBroadcast())
        XCTAssertEqual(
            parsed.permalink?.absoluteString,
            "https://soundcloud.com/rovr-108499109/i-love-it-loud-13176-2026-09/s-Pw4hOT9zRyg"
        )
        XCTAssertEqual(parsed.mediaItem()?.embedProvider, .soundcloud)
    }

    func testPlaybackUsesTheEmbedTargetWithItsPrivateToken() throws {
        let parsed = try XCTUnwrap(decode(RovrBroadcastDTO.self, broadcast).asBroadcast())
        XCTAssertEqual(
            parsed.mediaItem()?.playbackURL.absoluteString,
            "https://api.soundcloud.com/tracks/2388530769?secret_token=s-Pw4hOT9zRyg"
        )
    }

    func testEmbedOnlyRecordingIsPlayable() throws {
        let json = """
        {"documentId":"embed-only","title":"Archive",
         "soundcloudEmbedUrl":"https://api.soundcloud.com/tracks/123?secret_token=s-test&utm_source=share"}
        """
        let parsed = try XCTUnwrap(decode(RovrBroadcastDTO.self, json).asBroadcast())
        XCTAssertTrue(parsed.isPlayable)
        XCTAssertEqual(parsed.mediaItem()?.playbackURL.absoluteString,
                       "https://api.soundcloud.com/tracks/123?secret_token=s-test")
    }

    func testPermalinkIsAFallbackWhenNoEmbedTargetExists() throws {
        let json = """
        {"documentId":"public","title":"Archive",
         "soundcloudPermalinkUrl":"https://soundcloud.com/rovr/recording?utm_source=share"}
        """
        let parsed = try XCTUnwrap(decode(RovrBroadcastDTO.self, json).asBroadcast())
        XCTAssertTrue(parsed.isPlayable)
        XCTAssertEqual(parsed.mediaItem()?.playbackURL.absoluteString,
                       "https://soundcloud.com/rovr/recording")
    }

    /// Most broadcasts carry no picture of their own and take the show's.
    func testBroadcastInheritsTheShowsArtwork() throws {
        let parsed = try XCTUnwrap(decode(RovrBroadcastDTO.self, broadcast).asBroadcast())
        XCTAssertEqual(
            parsed.imageURL?.absoluteString, "https://rovr-prod.s3.amazonaws.com/full.png"
        )
        XCTAssertEqual(parsed.thumbnailURL?.absoluteString, "https://x/m.png")
    }

    /// A tag the station has hidden is not a tag to show a listener.
    func testHiddenTagsAreDropped() throws {
        let parsed = try XCTUnwrap(decode(RovrBroadcastDTO.self, broadcast).asBroadcast())
        XCTAssertEqual(parsed.tags, ["FUZZ"])
    }

    /// ROVR overrides a show's name per broadcast when it wants to, and that
    /// override is the title the listener should see.
    func testAnOverriddenNameWins() throws {
        let json = broadcast.replacingOccurrences(
            of: "\"overwriteShowName\":null", with: "\"overwriteShowName\":\"Special Edition\""
        )
        let parsed = try XCTUnwrap(decode(RovrBroadcastDTO.self, json).asBroadcast())
        XCTAssertEqual(parsed.title, "Special Edition")
    }

    // MARK: - Tags

    /// The archive filters on a tag's `type` and the listener sees its
    /// `label`, and they are different words. Filtering by the label is not an
    /// error — it simply returns nothing, which reads as an empty archive.
    func testTagLabelAndFilterValueAreNotTheSameWord() throws {
        let json = """
        {"data":[{"id":6,"label":"FUZZ","type":"grease","displayOrder":6,"visible":true},
                 {"id":1,"label":"DREAM","type":"dreamy","displayOrder":1,"visible":true},
                 {"id":9,"label":"GONE","type":"gone","displayOrder":9,"visible":false}]}
        """
        let tags = try decode(RovrListResponse<RovrTagDTO>.self, json).data
            .compactMap { $0.asTag() }
            .sorted { $0.order < $1.order }

        XCTAssertEqual(tags.map(\.label), ["DREAM", "FUZZ"], "Hidden tags are not offered")
        XCTAssertEqual(tags.map(\.type), ["dreamy", "grease"])
        XCTAssertNotEqual(tags[1].label, tags[1].type)
    }

    // MARK: - Curators

    /// Some curators write their whole biography as a run of addresses. Those
    /// are links, not prose, and belong in the chips rather than in a
    /// paragraph that reads as a wall of URLs.
    func testABiographyOfNothingButLinksBecomesLinks() throws {
        let json = """
        {"id":613,"documentId":"sy74hghpqswphzasdmpk7no4","name":"L' Amateur",
         "about":"https://www.instagram.com/lamateur/ https://soundcloud.com/lamateur",
         "countryCode":"FRA","urlSlug":"l-amateur","visible":true,"isSubcurator":false,
         "links":[],"shows":[{"documentId":"s1","title":"Better Call Soul"}]}
        """
        let parsed = try XCTUnwrap(decode(RovrCuratorDTO.self, json).asCurator())

        XCTAssertEqual(parsed.name, "L' Amateur")
        XCTAssertNil(parsed.about, "Nothing but addresses leaves no prose behind")
        XCTAssertEqual(parsed.links.map(\.label), ["Instagram", "SoundCloud"])
        XCTAssertEqual(parsed.showTitles, ["Better Call Soul"])
    }

    /// A page links its Mixcloud three times over, and often as both http and
    /// https, so the host is what counts as the same place.
    func testOneChipADestination() throws {
        let json = """
        {"documentId":"c1","name":"Someone","about":"Words worth keeping.",
         "links":[{"id":1,"link":"https://www.instagram.com/someone"},
                  {"id":2,"link":"http://instagram.com/someone"},
                  {"id":3,"link":"https://soundcloud.com/someone"}]}
        """
        let parsed = try XCTUnwrap(decode(RovrCuratorDTO.self, json).asCurator())
        XCTAssertEqual(parsed.links.map(\.label), ["Instagram", "SoundCloud"])
        XCTAssertEqual(parsed.about, "Words worth keeping.")
    }

    /// ROVR files a country as ISO alpha-3 and a flag needs alpha-2. An
    /// unmapped code shows no flag rather than a wrong one.
    func testCountryFlags() {
        XCTAssertEqual(RovrCountry.flag(alpha3: "FRA"), "🇫🇷")
        XCTAssertEqual(RovrCountry.flag(alpha3: "usa"), "🇺🇸")
        XCTAssertNil(RovrCountry.flag(alpha3: "XXX"))
        XCTAssertNil(RovrCountry.flag(alpha3: "FR"))
    }

    // MARK: - The schedule

    /// The schedule comes back in whatever wall clock it was asked in, with no
    /// zone attached — because the station does not have one to attach. Read
    /// as UTC it would be off by the listener's own offset, which is exactly
    /// the amount that makes a schedule look plausible and be wrong.
    func testScheduleTimesAreWallClockNotInstants() throws {
        let json = """
        {"id":14394,"documentId":"qnvnqyq2f3i2zd7swh7f9li1",
         "startTime":"2026-09-02 10:00:00","endTime":"2026-09-02 12:00:00",
         "show":{"documentId":"vHWWWbnmb4AUAAyncxskb","title":"Down de Islands",
                 "description":"A free pass to the Caribbean"},
         "playlist":{"documentId":"okjmea7xethzdegyyigqp5j5","title":"#131 Joy!",
                     "soundcloudPermalinkUrl":"https://soundcloud.com/rovr/joy",
                     "curator":{"documentId":"c9","name":"Someone"}}}
        """
        let onAir = try decode(RovrScheduleDTO.self, json).asOnAir()

        XCTAssertTrue(onAir.isOnAir)
        XCTAssertEqual(onAir.title, "Down de Islands")
        XCTAssertEqual(onAir.broadcastID, "okjmea7xethzdegyyigqp5j5")
        XCTAssertEqual(onAir.curatorName, "Someone")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = try XCTUnwrap(onAir.startsAt)
        XCTAssertEqual(calendar.component(.hour, from: start), 10, "10:00 local, whoever is reading")
        XCTAssertEqual(try XCTUnwrap(onAir.endsAt).timeIntervalSince(start), 7200, accuracy: 1)
    }

    /// The same shape going back out, which is what the request carries.
    func testWallClockRoundTrips() throws {
        let written = "2026-09-02 10:00:00"
        let parsed = try XCTUnwrap(RovrTimestamp.parseWallClock(written))
        XCTAssertEqual(RovrTimestamp.wallClock(parsed), written)
    }

    func testAnEmptyScheduleIsIdleRatherThanBlank() throws {
        let onAir = try decode(RovrScheduleDTO.self, #"{"id":1}"#).asOnAir()
        XCTAssertFalse(onAir.isOnAir)
        XCTAssertNil(onAir.asRadioShow())
    }

    // MARK: - Channels

    /// The scheduled radio answers to one id whichever timezone stream is
    /// behind it. The crate and the player store it, and a broadcast crated in
    /// Berlin has to still be the same station in Lisbon.
    func testTheRadioIdDoesNotMoveWithTheListener() {
        XCTAssertEqual(RovrChannel.radioID, "rovr.live")
        XCTAssertEqual(RovrChannel.moodID("Drive"), "rovr.mood.drive")
        XCTAssertEqual(RovrChannel.moodID("drive"), "rovr.mood.drive")
        XCTAssertEqual(RovrProvider.providerID, "rovr")
    }

    func testStreamsDecode() throws {
        let json = """
        {"data":[{"id":11,"documentId":"d1","name":"Plus 0","offset":0,
                  "hlsUrl":"https://hls-prod.rovr.live/prod/stream_plus00/llhls.m3u8",
                  "icecastUrl":"https://switcher-prod.rovr.live/timezone/plus0"}]}
        """
        let streams = try decode(RovrListResponse<RovrStreamDTO>.self, json).data
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams[0].offset, 0)
        XCTAssertNotNil(streams[0].hlsUrl)
    }

    func testMoodStreamsDecode() throws {
        let json = """
        {"data":[{"id":3,"name":"drive",
                  "hlsUrl":"https://hls-prod.rovr.live/prod/mood_drive/llhls.m3u8",
                  "icecastUrl":"https://switcher-prod.rovr.live/moods/drive",
                  "mood":{"title":"DRIVE","squareImage":"https://x/drive.png","order":"1"}}]}
        """
        let moods = try decode(RovrListResponse<RovrMoodStreamDTO>.self, json).data
        XCTAssertEqual(moods.count, 1)
        XCTAssertEqual(moods[0].mood?.title, "DRIVE")
        XCTAssertEqual(moods[0].mood?.squareImage, "https://x/drive.png")
    }

    // MARK: - Shows

    func testShowParses() throws {
        let json = """
        {"id":328,"documentId":"cki0uqyqe07b0qj858kyo0p5","title":"I Love It Loud",
         "description":"Loud and dirty selections","frequency":"monthly","active":true,
         "communityRadio":false,
         "radioImage":{"url":"https://x/full.png","formats":{"medium":{"url":"https://x/m.png","width":500}}},
         "curators":[{"documentId":"c1","name":"Thomas Bornand"}]}
        """
        let parsed = try XCTUnwrap(decode(RovrShowDTO.self, json).asShow())

        XCTAssertEqual(parsed.documentID, "cki0uqyqe07b0qj858kyo0p5")
        XCTAssertEqual(parsed.title, "I Love It Loud")
        XCTAssertEqual(parsed.frequency, "monthly")
        XCTAssertEqual(parsed.curators, ["Thomas Bornand"])
        XCTAssertFalse(parsed.isCommunityRadio)
        XCTAssertEqual(parsed.thumbnailURL?.absoluteString, "https://x/m.png")
    }

    // MARK: - Envelope

    /// The archive endpoint is not shaped like Strapi's own: it pages on flat
    /// `page`/`pageSize`, and answers with a pageCount the store walks.
    func testListEnvelopeCarriesPaging() throws {
        let json = """
        {"data":[],"meta":{"pagination":{"page":2,"pageSize":24,"pageCount":449,"total":10770}}}
        """
        let parsed = try decode(RovrListResponse<RovrBroadcastDTO>.self, json)
        XCTAssertEqual(parsed.total, 10770)
        XCTAssertEqual(parsed.pageCount, 449)
        XCTAssertTrue(parsed.data.isEmpty)
    }

    /// A record with no documentId has nothing to navigate to, so it is
    /// dropped rather than becoming a tile that opens an empty page.
    func testRecordsWithNothingUsableAreDropped() throws {
        XCTAssertNil(try decode(RovrBroadcastDTO.self, #"{"id":1,"title":"No id"}"#).asBroadcast())
        XCTAssertNil(try decode(RovrShowDTO.self, #"{"id":1,"title":"No id"}"#).asShow())
        XCTAssertNil(try decode(RovrCuratorDTO.self, #"{"id":1,"name":"No id"}"#).asCurator())
        XCTAssertNil(try decode(RovrBroadcastDTO.self, #"{"documentId":"d","title":"  "}"#).asBroadcast())
    }

    /// A broadcast ROVR never uploaded is listed but cannot be played, and the
    /// grid has to be able to say so.
    func testABroadcastWithNoRecordingIsNotPlayable() throws {
        let json = #"{"documentId":"unrecorded","title":"No recording"}"#
        let parsed = try XCTUnwrap(decode(RovrBroadcastDTO.self, json).asBroadcast())
        XCTAssertFalse(parsed.isPlayable)
        XCTAssertNil(parsed.mediaItem())
    }
}
