//
//  LYLTests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on strapi.lyl.live. LYL publishes more
//  about an episode than any other station Indigo reads — its own audio file
//  as well as Mixcloud and SoundCloud mirrors — so most of this is about
//  choosing between them correctly and reading LYL's own formats.
//

import XCTest
@testable import Indigo

final class LYLTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Episodes

    private let episode = """
    {"id":"abc123","title":"Flagrant Déni","slug":"speechmaker","artists":"Speechmaker",
     "startAt":"2026-08-24T16:00:00.000Z","duration":"01:00:00.000",
     "mixcloud":"https://www.mixcloud.com/lylradio/flagrant-deni-speechmaker-24082026/",
     "soundcloud":"https://soundcloud.com/lyl_radio/flagrant-deni?utm_medium=api&utm_campaign=social_sharing",
     "audio":{"url":"https://static.lyl.live/uploads/FLAGRANT_DENI.mp3","mime":"audio/mpeg","name":"x.mp3"},
     "show":{"id":"s1","slug":"one-off-lyon","title":"One Off Lyon"},
     "description":"Ethos co-founder Speechmaker celebrates the release.",
     "tracks":"- Odd Shy Guy - Unreleased\\n\\n- DalidaCarnage - Beldam\\n   \\n• Rips - Faceoff\\n",
     "styles":[{"id":"g1","name":"Bass"},{"id":"g2","name":"Breaks"},{"id":"g3","name":""}],
     "image":{"url":"https://static.lyl.live/uploads/ETHOS_45.jpg","alternativeText":null}}
    """

    func testEpisodeParses() throws {
        let parsed = try XCTUnwrap(decode(LYLEpisodeDTO.self, episode).asEpisode())

        XCTAssertEqual(parsed.slug, "speechmaker")
        XCTAssertEqual(parsed.title, "Flagrant Déni")
        XCTAssertEqual(parsed.artists, "Speechmaker")
        XCTAssertEqual(parsed.styles, ["Bass", "Breaks"], "A blank style is not a style")
        XCTAssertEqual(parsed.showSlug, "one-off-lyon")
        XCTAssertEqual(parsed.showTitle, "One Off Lyon")
        XCTAssertEqual(parsed.broadcastLabel, "24 Aug 2026")
        XCTAssertTrue(parsed.isPlayable)
    }

    /// LYL hosts the recording itself. Playing its own file means the episode
    /// seeks and reports a real duration instead of going through a widget —
    /// so the mirrors are only ever a fallback.
    func testTheStationsOwnFileBeatsBothMirrors() throws {
        let parsed = try XCTUnwrap(decode(LYLEpisodeDTO.self, episode).asEpisode())
        let item = try XCTUnwrap(parsed.mediaItem())

        XCTAssertNil(item.embedProvider, "LYL's own audio needs no embed")
        XCTAssertEqual(item.playbackURL, parsed.audioURL)
        XCTAssertEqual(item.id, "lyl.episode.speechmaker")
        XCTAssertEqual(try XCTUnwrap(item.duration), 3600, accuracy: 1)
    }

    func testMirrorsAreUsedOnlyWhenThereIsNoFile() throws {
        let noFile = """
        {"title":"X","slug":"x","audio":null,
         "soundcloud":"https://soundcloud.com/lyl_radio/x?utm_medium=api",
         "mixcloud":"https://www.mixcloud.com/lylradio/x/"}
        """
        let noFileEpisode = try XCTUnwrap(decode(LYLEpisodeDTO.self, noFile).asEpisode())
        let soundcloud = try XCTUnwrap(noFileEpisode.mediaItem())
        XCTAssertEqual(soundcloud.embedProvider, .soundcloud)
        XCTAssertEqual(
            soundcloud.playbackURL.absoluteString, "https://soundcloud.com/lyl_radio/x",
            "Share tracking must be stripped before the widget sees the link"
        )

        let mixcloudOnly = """
        {"title":"X","slug":"x","mixcloud":"https://www.mixcloud.com/lylradio/x/"}
        """
        let mixcloudEpisode = try XCTUnwrap(decode(LYLEpisodeDTO.self, mixcloudOnly).asEpisode())
        let mixcloud = try XCTUnwrap(mixcloudEpisode.mediaItem())
        XCTAssertEqual(mixcloud.embedProvider, .mixcloud)

        let nothing = #"{"title":"X","slug":"x"}"#
        let orphan = try XCTUnwrap(decode(LYLEpisodeDTO.self, nothing).asEpisode())
        XCTAssertFalse(orphan.isPlayable)
        XCTAssertNil(orphan.mediaItem())
    }

    /// LYL writes duration as a clock rather than a count of seconds.
    func testDurationIsAClock() {
        XCTAssertEqual(LYLTimestamp.parseDuration("01:00:00.000"), 3600)
        XCTAssertEqual(LYLTimestamp.parseDuration("02:30:45.500"), 9045.5)
        XCTAssertNil(LYLTimestamp.parseDuration("00:00:00.000"), "A zero-length episode has no duration")
        XCTAssertNil(LYLTimestamp.parseDuration("3600"))
        XCTAssertNil(LYLTimestamp.parseDuration(nil))
    }

    /// Half the tracklists use a different separator between artist and title,
    /// so each line is kept as written rather than split into fields.
    func testTracklistKeepsLinesAndDropsTheirBullets() throws {
        let parsed = try XCTUnwrap(decode(LYLEpisodeDTO.self, episode).asEpisode())

        XCTAssertEqual(parsed.tracks, [
            "Odd Shy Guy - Unreleased",
            "DalidaCarnage - Beldam",
            "Rips - Faceoff"
        ])
        XCTAssertTrue(LYLTracklist.parse("").isEmpty)
        XCTAssertTrue(LYLTracklist.parse(nil).isEmpty)
    }

    // MARK: - Shows

    func testShowParsesWithItsCadenceAndLinks() throws {
        let json = """
        {"id":"s1","slug":"temple-of-faitiche","title":"Temple Of Faitiche","recursion":"Bimestrial",
         "nextBroadcast":"2026-09-06T15:00:00.000Z","description":"<p>A show.</p>","artists":"Various",
         "styles":[{"id":"g1","name":"Dub"},{"id":"g2","name":"Experimental"}],
         "links":[{"type":"Bandcamp","url":"https://x.bandcamp.com"},{"type":"","url":"not a url"}],
         "image":{"url":"https://static.lyl.live/uploads/x.jpg"}}
        """
        let show = try XCTUnwrap(decode(LYLShowDTO.self, json).asShow())

        XCTAssertEqual(show.title, "Temple Of Faitiche")
        XCTAssertEqual(show.recursionLabel, "Bimestrial")
        XCTAssertFalse(show.hasEnded)
        XCTAssertEqual(show.styles, ["Dub", "Experimental"])
        XCTAssertEqual(show.links.map(\.label), ["Bandcamp"], "A link that is not an address is not a link")
        XCTAssertEqual(show.summary, "A show.")
        XCTAssertNotNil(show.nextBroadcast)
    }

    /// LYL marks a show that has finished rather than deleting it, and writes
    /// its cadence as one word.
    func testEndedAndOneOffShowsReadProperly() throws {
        let ended = #"{"slug":"a","title":"A","recursion":"Terminated"}"#
        let show = try XCTUnwrap(decode(LYLShowDTO.self, ended).asShow())
        XCTAssertTrue(show.hasEnded)
        XCTAssertEqual(show.recursionLabel, "Terminated")

        let oneOff = #"{"slug":"b","title":"B","recursion":"OneOff"}"#
        let single = try XCTUnwrap(decode(LYLShowDTO.self, oneOff).asShow())
        XCTAssertEqual(single.recursionLabel, "One off", "OneOff is not how anyone writes it")
        XCTAssertFalse(single.hasEnded)
    }

    func testAShowWithoutASlugIsNotAShow() throws {
        XCTAssertNil(try decode(LYLShowDTO.self, #"{"title":"Orphan"}"#).asShow())
        XCTAssertNil(try decode(LYLShowDTO.self, #"{"slug":"x","title":""}"#).asShow())
    }

    // MARK: - The calendar

    /// Only a slot that becomes an archived episode has anywhere to point.
    func testOnlyEpisodeSlotsCarryASlug() throws {
        let episodeSlot = """
        {"startAt":"2026-08-29T23:30:00.000Z","end":"2026-08-30T00:30:00.000Z",
         "title":"Bienvenue chez Christian Coiffure","slug":"bienvenue-48",
         "artists":"Christian Coiffure","type":"EPISODE"}
        """
        let entry = try XCTUnwrap(decode(LYLCalendarEntryDTO.self, episodeSlot).asScheduleEntry())
        XCTAssertEqual(entry.episodeSlug, "bienvenue-48")
        XCTAssertEqual(entry.artists, "Christian Coiffure")
        XCTAssertTrue(entry.contains(entry.startsAt.addingTimeInterval(60)))

        let rerun = """
        {"startAt":"2026-08-29T23:30:00.000Z","end":"2026-08-30T00:30:00.000Z",
         "title":"Rerun","slug":"rerun-1","type":"RERUN"}
        """
        let other = try XCTUnwrap(decode(LYLCalendarEntryDTO.self, rerun).asScheduleEntry())
        XCTAssertNil(other.episodeSlug, "Only an EPISODE ends up in the archive")
    }

    func testASlotThatEndsBeforeItStartsIsNotASlot() throws {
        let json = """
        {"startAt":"2026-08-30T10:00:00.000Z","end":"2026-08-30T09:00:00.000Z","title":"Broken"}
        """
        XCTAssertNil(try decode(LYLCalendarEntryDTO.self, json).asScheduleEntry())
    }

    // MARK: - Envelope

    func testGraphQLErrorsAreCarriedRatherThanSwallowed() throws {
        let json = #"{"errors":[{"message":"Cannot query field \"nope\"."}]}"#
        struct Payload: Decodable, Sendable { let onair: LYLOnAirDTO? }
        let response = try decode(LYLResponse<Payload>.self, json)

        XCTAssertNil(response.data)
        XCTAssertEqual(response.errors?.first?.message, "Cannot query field \"nope\".")
    }

    /// LYL's older uploads are not all still on its server — some answer 403 —
    /// but the SoundCloud and Mixcloud copies are. So the file is what plays
    /// and the mirror rides along, rather than the episode simply failing and
    /// the player walking on to the next one.
    func testABrokenFileCanFallBackToTheMirror() throws {
        let parsed = try XCTUnwrap(decode(LYLEpisodeDTO.self, episode).asEpisode())
        let item = try XCTUnwrap(parsed.mediaItem())

        XCTAssertNil(item.embedProvider, "The station's own file plays first")
        XCTAssertEqual(item.alternateEmbedProvider, .soundcloud)
        XCTAssertEqual(item.alternatePlaybackURL?.absoluteString, "https://soundcloud.com/lyl_radio/flagrant-deni")

        let retry = try XCTUnwrap(item.usingAlternate())
        XCTAssertEqual(retry.id, item.id, "It is the same recording, reached another way")
        XCTAssertEqual(retry.embedProvider, .soundcloud)
        XCTAssertEqual(retry.playbackURL, item.alternatePlaybackURL)
        XCTAssertNil(retry.usingAlternate(), "One retry, not a loop between two dead ends")
    }

    func testTheMirrorChainRunsOutHonestly() throws {
        // No file: SoundCloud leads and Mixcloud backs it up.
        let noFile = """
        {"title":"X","slug":"x","soundcloud":"https://soundcloud.com/lyl_radio/x",
         "mixcloud":"https://www.mixcloud.com/lylradio/x/"}
        """
        let first = try XCTUnwrap(decode(LYLEpisodeDTO.self, noFile).asEpisode().flatMap { $0.mediaItem() })
        XCTAssertEqual(first.embedProvider, .soundcloud)
        XCTAssertEqual(first.alternateEmbedProvider, .mixcloud)

        // Mixcloud alone has nothing to fall back to.
        let onlyMixcloud = #"{"title":"X","slug":"x","mixcloud":"https://www.mixcloud.com/lylradio/x/"}"#
        let last = try XCTUnwrap(decode(LYLEpisodeDTO.self, onlyMixcloud).asEpisode().flatMap { $0.mediaItem() })
        XCTAssertEqual(last.embedProvider, .mixcloud)
        XCTAssertNil(last.alternatePlaybackURL)
        XCTAssertNil(last.usingAlternate())
    }

    func testTheQueueCanSwapWhatIsUnderTheCursor() {
        func make(_ id: String) -> MediaItem {
            MediaItem(id: id, sourceID: "lyl", kind: .episode, title: id,
                      playbackURL: URL(string: "https://x/\(id).mp3")!)
        }
        var queue = PlaybackQueue()
        queue.load([make("a"), make("b"), make("c")], startingAt: 1)
        XCTAssertEqual(queue.current?.id, "b")

        queue.replaceCurrent(with: make("b-mirror"))
        XCTAssertEqual(queue.current?.id, "b-mirror")
        XCTAssertEqual(queue.items.map(\.id), ["a", "b-mirror", "c"], "The running order is undisturbed")
        XCTAssertEqual(queue.index, 1)
    }

    @MainActor
    func testTheStationFallsBackToAKnownStreamUntilItIsTold() {
        let provider = LYLProvider()

        XCTAssertEqual(provider.station.id, "lyl.live")
        XCTAssertEqual(provider.station.streamURL.absoluteString, "https://radio.lyl.live/hls/live.m3u8")
        XCTAssertEqual(provider.mediaItem().subtitle, "Live", "Nothing is known before the first poll")
        XCTAssertTrue(provider.mediaItem().isLive)
    }
}
