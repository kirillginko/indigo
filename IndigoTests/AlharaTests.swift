//
//  AlharaTests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on ch2.radioalhara.net. alHara
//  publishes only what is on its three channels this minute, so all of this is
//  about reading that state honestly — particularly the difference between a
//  studio with somebody in it and an automated playlist filling the air.
//

import XCTest
@testable import Indigo

final class AlharaTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - The studio channel

    private let onAir = """
    {"title":"NAWRAS AND FARES WITH BNHARAM","episodeTitle":null,"episodeId":null,"artist":null,
     "airDate":"2021-07-23T13:00:00+03:00","campaignName":null,"ch2Label":null,
     "ch2City":"Bethlehem","ch2Timezone":"Asia/Hebron","ch2Enabled":false,
     "ch2HideRa2":false,"ch2HideRa3":false,"mode":"harbor",
     "trackStart":"2026-08-29T14:43:14.000Z","duration":4889.19535,
     "scheduledTitle":null,"isRerun":false,"originalAirDate":null}
    """

    func testAConnectedDJReadsAsOnAir() throws {
        let state = try decode(AlharaNowPlayingDTO.self, onAir).asChannelState()

        XCTAssertEqual(state.mode, .live)
        XCTAssertTrue(state.isOnAir)
        XCTAssertEqual(state.title, "NAWRAS AND FARES WITH BNHARAM")
        XCTAssertEqual(state.city, "Bethlehem")
        XCTAssertEqual(state.mode.label, "On air now")
    }

    func testElapsedIsMeasuredFromWhenTheSetStarted() throws {
        let state = try decode(AlharaNowPlayingDTO.self, onAir).asChannelState()
        let start = try XCTUnwrap(state.startedAt)

        XCTAssertEqual(try XCTUnwrap(state.duration), 4889, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(state.elapsedFraction(at: start)), 0, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(state.elapsedFraction(at: start.addingTimeInterval(2444))), 0.5,
            accuracy: 0.01
        )
        XCTAssertEqual(
            try XCTUnwrap(state.elapsedFraction(at: start.addingTimeInterval(99_999))), 1,
            "A set that has overrun is finished, not more than finished"
        )
    }

    /// The payload carries an `airDate` whether or not anything is a repeat,
    /// so it only means something once the station says it is one.
    func testAirDateIsIgnoredUntilTheStationCallsItARerun() throws {
        let plain = try decode(AlharaNowPlayingDTO.self, onAir).asChannelState()
        XCTAssertFalse(plain.isRerun)
        XCTAssertNil(plain.originalAirDate, "An air date on a first broadcast is noise")

        let rerun = """
        {"title":"A REPEAT","mode":"harbor","isRerun":true,
         "originalAirDate":"2021-07-23T13:00:00+03:00","ch2City":"Bethlehem"}
        """
        let repeated = try decode(AlharaNowPlayingDTO.self, rerun).asChannelState()
        XCTAssertTrue(repeated.isRerun)
        XCTAssertEqual(repeated.originalAirLabel, "23 Jul 2021")
    }

    /// The station asks for a channel to be hidden when there is nothing on it.
    func testHiddenChannelsAreReadFromTheStationsOwnFlags() throws {
        let json = """
        {"title":"x","mode":"harbor","ch2HideRa2":true,"ch2HideRa3":false}
        """
        let hidden = try decode(AlharaNowPlayingDTO.self, json).hiddenChannels

        XCTAssertEqual(hidden, ["alhara.ra2"])
    }

    // MARK: - The relay channels

    func testAnIdleRelayIsNotLive() throws {
        let json = """
        {"isHarborActive":false,"isRelayActive":false,"relayTitle":null,"relayTrackTitle":null,
         "meta":{"title":null,"artist":null},"mode":"fallback","displayTitle":null,
         "forcedTitle":null,"city":null,"timezone":null,"videoActive":false,
         "videoUrl":"https://ch2.radioalhara.net/ra3video/index.m3u8"}
        """
        let state = try decode(AlharaRelayDTO.self, json).asChannelState()

        XCTAssertEqual(state.mode, .automated)
        XCTAssertFalse(state.isOnAir, "The automated playlist is the lights being on, not a show")
        XCTAssertNil(state.title)
        XCTAssertNil(state.videoURL, "An inactive video feed is not a video feed")
        XCTAssertEqual(state.mode.label, "Between shows")
        XCTAssertNil(state.asRadioShow(), "Nothing on air is nothing to report")
    }

    /// The relay endpoints report booleans as well as a mode, and the booleans
    /// are the more reliable of the two.
    func testRelayBooleansOutrankTheReportedMode() throws {
        let relaying = """
        {"isHarborActive":false,"isRelayActive":true,"relayTitle":"Another Station",
         "mode":"fallback","videoActive":true,"videoUrl":"https://x/index.m3u8","city":"Amman"}
        """
        let state = try decode(AlharaRelayDTO.self, relaying).asChannelState()

        XCTAssertEqual(state.mode, .relay)
        XCTAssertTrue(state.isOnAir)
        XCTAssertEqual(state.title, "Another Station")
        XCTAssertEqual(state.city, "Amman")
        XCTAssertEqual(state.videoURL?.absoluteString, "https://x/index.m3u8")
        XCTAssertEqual(state.mode.label, "Relaying")
    }

    func testTitleFallsBackThroughEveryNameTheRelayOffers() throws {
        let json = """
        {"isHarborActive":true,"forcedTitle":"","displayTitle":"  ",
         "relayTitle":null,"relayTrackTitle":"A Set","meta":{"title":"ignored"}}
        """
        let state = try decode(AlharaRelayDTO.self, json).asChannelState()

        XCTAssertEqual(state.title, "A Set", "Blank names are not names")
        XCTAssertEqual(state.mode, .live)
    }

    // MARK: - Channels

    /// The secondary channels carry the main one whenever they have nothing of
    /// their own on, so offering all three would be three ways to hear the
    /// same audio — which is exactly how it looked before this.
    @MainActor
    func testOnlyChannelsDoingSomethingOfTheirOwnAreOffered() {
        let provider = AlharaProvider()

        XCTAssertEqual(provider.stations.map(\.id), ["alhara.ra", "alhara.ra2", "alhara.ra3"])
        XCTAssertEqual(provider.publishedStations.count, 3, "Nothing is hidden until the station says so")
        XCTAssertEqual(
            provider.visibleStations.map(\.id), ["alhara.ra"],
            "Before the first poll nothing is known, and the main channel is the honest default"
        )
        XCTAssertEqual(
            provider.station(id: "alhara.ra2")?.streamURL.absoluteString,
            "https://stream.radioalhara.net/ra2"
        )
        XCTAssertNil(provider.station(id: "alhara.ra4"))
        XCTAssertEqual(provider.state(for: "alhara.ra").mode, .automated, "An unread channel is not on air")
        XCTAssertFalse(provider.isSimulcast("alhara.ra"), "The main channel is never a simulcast of itself")
    }

    @MainActor
    func testMediaItemCarriesTheChannelRatherThanTheStation() throws {
        let provider = AlharaProvider()
        let item = try XCTUnwrap(provider.mediaItem(for: "alhara.ra3"))

        XCTAssertEqual(item.id, "alhara.ra3")
        XCTAssertEqual(item.sourceID, AlharaProvider.providerID)
        XCTAssertTrue(item.isLive)
        XCTAssertEqual(item.playbackURL.absoluteString, "https://stream.radioalhara.net/ra3")
        XCTAssertNil(provider.mediaItem(for: "nts.1"))
    }

    // MARK: - The archive, which lives on Mixcloud

    private let cloudcast = """
    {"key":"/RadioAlhara/radio-alhara-voices-x-the-cause-fm-new-frequency-20260725-150845/",
     "url":"https://www.mixcloud.com/RadioAlhara/radio-alhara-voices-x-the-cause-fm-new-frequency-20260725-150845/",
     "name":"Radio alHara &amp; Voices x The Cause FM: New Frequency",
     "slug":"radio-alhara-voices-x-the-cause-fm-new-frequency-20260725-150845",
     "created_time":"2026-07-26T09:23:53Z","audio_length":32620,"play_count":34,
     "tags":[{"name":"Drum and bass"},{"name":"Noise music"},{"name":""}],
     "pictures":{"thumbnail":"https://x/thumb.jpg","medium":"https://x/medium.jpg",
                 "large":"https://x/large.jpg","1024wx1024h":"https://x/huge.jpg"},
     "description":"<p>A takeover.</p><p>Two hours.</p>",
     "sections":[{"start_time":0,"track":{"name":"First","artist":{"name":"Someone"}}},
                 {"start_time":540,"track":{"name":"Second","artist":null}},
                 {"start_time":900,"track":{"name":"","artist":{"name":"Nobody"}}}]}
    """

    func testCloudcastBecomesAPlayableShow() throws {
        let show = try XCTUnwrap(decode(MixcloudCloudcastDTO.self, cloudcast).asShow())

        XCTAssertEqual(show.title, "Radio alHara & Voices x The Cause FM: New Frequency")
        XCTAssertEqual(show.genres, ["Drum and bass", "Noise music"], "A blank tag is not a tag")
        XCTAssertEqual(try XCTUnwrap(show.duration), 32620, accuracy: 1)
        XCTAssertEqual(show.playCount, 34)
        XCTAssertEqual(show.publishedLabel, "26 Jul 2026")
        XCTAssertEqual(show.summary, "A takeover.\nTwo hours.")
    }

    /// A grid tile has no business pulling the 1024px original.
    func testArtworkPrefersASizeAGridCanUse() throws {
        let show = try XCTUnwrap(decode(MixcloudCloudcastDTO.self, cloudcast).asShow())

        XCTAssertEqual(show.artworkURL?.absoluteString, "https://x/large.jpg")
    }

    /// The recordings are Mixcloud's, so they play through the hosted widget —
    /// which is also what keeps the plays counted where they belong.
    func testShowPlaysThroughTheMixcloudWidget() throws {
        let show = try XCTUnwrap(decode(MixcloudCloudcastDTO.self, cloudcast).asShow())
        let item = show.mediaItem()

        XCTAssertEqual(item.embedProvider, .mixcloud)
        XCTAssertEqual(item.kind, .episode)
        XCTAssertEqual(item.playbackURL, show.mixcloudURL)
        XCTAssertEqual(
            show.mediaID,
            "alhara.show.radio-alhara-voices-x-the-cause-fm-new-frequency-20260725-150845"
        )
    }

    func testTracklistKeepsItsOffsetsAndDropsItsBlanks() throws {
        let show = try XCTUnwrap(decode(MixcloudCloudcastDTO.self, cloudcast).asShow())

        XCTAssertEqual(show.tracklist.count, 2, "A track with no title is not a track")
        XCTAssertEqual(show.tracklist.first?.artist, "Someone")
        XCTAssertNil(show.tracklist.last?.artist)
        XCTAssertEqual(show.tracklist.last?.offsetLabel, "0:09:00")
    }

    /// Most of alHara's uploads have no tracklist and no tags at all.
    func testAShowWithNothingButATitleIsStillAShow() throws {
        let json = """
        {"url":"https://www.mixcloud.com/RadioAlhara/filmishmish_exfriendly/",
         "name":"Filmishmish_ExFriendly","slug":"filmishmish_exfriendly",
         "created_time":"2020-07-21T10:00:00Z","audio_length":3600,
         "tags":[],"pictures":{"large":"https://x/l.jpg"},"sections":[]}
        """
        let show = try XCTUnwrap(decode(MixcloudCloudcastDTO.self, json).asShow())

        XCTAssertEqual(show.title, "Filmishmish_ExFriendly")
        XCTAssertTrue(show.genres.isEmpty)
        XCTAssertTrue(show.tracklist.isEmpty)
        XCTAssertNil(show.summary)
        XCTAssertEqual(show.subtitle, "21 Jul 2020 · 1:00:00")
    }

    func testACloudcastWithNoPermalinkIsNotAShow() throws {
        let json = #"{"name":"Orphan","slug":"orphan","created_time":"2020-07-21T10:00:00Z"}"#
        XCTAssertNil(try decode(MixcloudCloudcastDTO.self, json).asShow())
    }

    func testPagingCursorIsCarriedThrough() throws {
        let json = """
        {"data":[],"paging":{"next":"https://api.mixcloud.com/radioalhara/cloudcasts/?limit=50&offset=50"}}
        """
        let page = try decode(MixcloudPageDTO.self, json)

        XCTAssertEqual(
            page.paging?.next,
            "https://api.mixcloud.com/radioalhara/cloudcasts/?limit=50&offset=50"
        )
    }
}
