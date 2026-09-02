//
//  Radio80000Tests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on radio80k.de, radio80k.airtime.pro
//  and api.mixcloud.com. Radio 80000 is assembled from three sources at once,
//  so most of this is about the joins: an episode id that survives being
//  written to the crate and read back cold, and the two platforms a broadcast
//  can live on arriving as one shape.
//

import XCTest
@testable import Indigo

final class Radio80000Tests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Shows

    private let show = """
    {"id":2639,"slug":"all-exhales","link":"https://www.radio80k.de/shows/residents/all-exhales/",
     "title":{"rendered":"(All Exhales)"},
     "content":{"rendered":"<p class=\\"wp-block-paragraph\\">A deep dive with pure metal insanity.<br />– Phil</p>"},
     "featured_media":1973,"cities":"Munich",
     "acf":{"cycle":"bi-monthly ","weekday":"Wednesday","time":"15:00 - 16:00",
            "links":[{"url":"https://www.instagram.com/technischersupport24.de/","text":"Instagram"}],
            "mixcloud_playlist_url":"https://www.mixcloud.com/Radio80K/playlists/all-exhales/",
            "soundcloud_playlist_url":""},
     "soundcloud_playlist_id":false,
     "_embedded":{
       "wp:featuredmedia":[{"source_url":"https://www.radio80k.de/app/uploads/logo.jpg",
         "media_details":{"sizes":{
           "thumbnail":{"source_url":"https://x/t.jpg","width":150},
           "medium":{"source_url":"https://x/m.jpg","width":300},
           "large":{"source_url":"https://x/l.jpg","width":1024}}}}],
       "wp:term":[[{"name":"Munich","slug":"munich","taxonomy":"city"}],
                  [{"name":"Metalcore","slug":"metalcore","taxonomy":"genre"},
                   {"name":"Noise","slug":"noise","taxonomy":"genre"}]]}}
    """

    func testShowParses() throws {
        let parsed = try XCTUnwrap(decode(Radio80000ShowDTO.self, show).asShow())

        XCTAssertEqual(parsed.slug, "all-exhales")
        XCTAssertEqual(parsed.title, "(All Exhales)")
        XCTAssertEqual(parsed.genres, ["Metalcore", "Noise"])
        XCTAssertEqual(parsed.city, "Munich")
        XCTAssertEqual(parsed.weekday, "Wednesday")
        XCTAssertEqual(parsed.time, "15:00 - 16:00")
        XCTAssertEqual(parsed.cycle, "bi-monthly", "Trailing space is the station's, not the label's")
        XCTAssertEqual(parsed.scheduleLabel, "Wednesday 15:00 - 16:00 · bi-monthly")
        XCTAssertEqual(parsed.links.count, 1)
        XCTAssertEqual(parsed.summary, "A deep dive with pure metal insanity.\n– Phil")
    }

    /// The two taxonomies arrive as separate arrays in no stated order, so
    /// which is which is read off each term rather than off its position.
    func testGenreAndCityAreToldApartByTaxonomy() throws {
        let swapped = show
            .replacingOccurrences(of: "\"taxonomy\":\"city\"", with: "\"taxonomy\":\"ZZZ\"")
        let parsed = try XCTUnwrap(decode(Radio80000ShowDTO.self, swapped).asShow())
        // With no city term left, the station's own flattened field stands in.
        XCTAssertEqual(parsed.city, "Munich")
        XCTAssertEqual(parsed.genres, ["Metalcore", "Noise"])
    }

    /// A grid has no use for a 1024px show logo.
    func testShowThumbnailPicksTheSmallestSufficientSize() throws {
        let parsed = try XCTUnwrap(decode(Radio80000ShowDTO.self, show).asShow())
        XCTAssertEqual(parsed.thumbnailURL?.absoluteString, "https://x/l.jpg")
        XCTAssertEqual(parsed.imageURL?.absoluteString, "https://www.radio80k.de/app/uploads/logo.jpg")
    }

    /// This show has a Mixcloud playlist and no SoundCloud one, which is the
    /// commoner of the two cases — a hundred and forty-six shows to eighty-two.
    func testShowArchiveSources() throws {
        let parsed = try XCTUnwrap(decode(Radio80000ShowDTO.self, show).asShow())
        XCTAssertNil(parsed.soundcloudPlaylistID, "ACF writes an unset number as false")
        XCTAssertEqual(parsed.mixcloudPlaylist, "Radio80K/playlists/all-exhales")
        XCTAssertTrue(parsed.hasArchive)
    }

    func testAShowWithNeitherPlaylistSaysSo() throws {
        let bare = show
            .replacingOccurrences(
                of: "\"mixcloud_playlist_url\":\"https://www.mixcloud.com/Radio80K/playlists/all-exhales/\"",
                with: "\"mixcloud_playlist_url\":\"\""
            )
        let parsed = try XCTUnwrap(decode(Radio80000ShowDTO.self, bare).asShow())
        XCTAssertFalse(parsed.hasArchive)
    }

    // MARK: - ACF's bools

    /// Advanced Custom Fields writes an empty field as `false` rather than as
    /// null or an empty array, which throws a plain `Int?` or `[Link]?`.
    func testACFWritesEmptyFieldsAsFalse() throws {
        XCTAssertEqual(try decode(FlexibleInt.self, "1762612107").value, 1_762_612_107)
        XCTAssertNil(try decode(FlexibleInt.self, "false").value)
        XCTAssertNil(try decode(FlexibleInt.self, "null").value)
        XCTAssertEqual(try decode(FlexibleInt.self, "\"123\"").value, 123)

        XCTAssertTrue(try decode(FlexibleLinks.self, "false").links.isEmpty)
        XCTAssertEqual(
            try decode(FlexibleLinks.self, #"[{"url":"https://x.test","text":"Site"}]"#).links.count,
            1
        )
    }

    // MARK: - SoundCloud broadcasts

    private let track = """
    {"id":2377388648,"title":"SONIC VACATION w/ heronymus (07/08/26)",
     "description":"Deep grooves and darker textures.",
     "duration":3533454,"created_at":"2026/08/07 14:18:05 +0000",
     "permalink_url":"https://soundcloud.com/radio80000/sonic-vacation-w-heronymus?utm_medium=api&utm_campaign=social_sharing",
     "artwork_url":"https://i1.sndcdn.com/artworks-abc-large.jpg",
     "genre":"Dub","tag_list":"ndw \\"fake reggae\\" library"}
    """

    func testSoundCloudTrackParses() throws {
        let parsed = try XCTUnwrap(decode(Radio80000TrackDTO.self, track).asEpisode())

        XCTAssertEqual(parsed.title, "SONIC VACATION w/ heronymus (07/08/26)")
        XCTAssertEqual(parsed.source, .soundcloud)
        XCTAssertEqual(try XCTUnwrap(parsed.duration), 3533.454, accuracy: 0.01)
        XCTAssertEqual(parsed.broadcastLabel, "7 Aug 2026")
        XCTAssertEqual(parsed.summary, "Deep grooves and darker textures.")
        XCTAssertEqual(parsed.mediaID, "radio80000.episode.sc:2377388648")
    }

    /// SoundCloud appends share tracking to every permalink, and the widget
    /// wants the bare address.
    func testShareTrackingIsStrippedFromThePermalink() throws {
        let parsed = try XCTUnwrap(decode(Radio80000TrackDTO.self, track).asEpisode())
        XCTAssertEqual(
            parsed.permalink.absoluteString,
            "https://soundcloud.com/radio80000/sonic-vacation-w-heronymus"
        )
    }

    /// The artwork SoundCloud hands back is 100px. The same address with the
    /// size swapped is the one a hero can use.
    func testArtworkIsAskedForAtAUsableSize() throws {
        let parsed = try XCTUnwrap(decode(Radio80000TrackDTO.self, track).asEpisode())
        XCTAssertEqual(
            parsed.artworkURL?.absoluteString,
            "https://i1.sndcdn.com/artworks-abc-t500x500.jpg"
        )
    }

    /// SoundCloud writes tags space-separated and quotes the ones containing
    /// spaces, so splitting on whitespace alone breaks "fake reggae" in half.
    func testQuotedTagsSurviveParsing() throws {
        let parsed = try XCTUnwrap(decode(Radio80000TrackDTO.self, track).asEpisode())
        XCTAssertEqual(parsed.genres, ["Dub", "ndw", "fake reggae", "library"])
    }

    func testTagListEdgeCases() {
        XCTAssertEqual(Radio80000Tags.parse(nil), [])
        XCTAssertEqual(Radio80000Tags.parse(""), [])
        XCTAssertEqual(Radio80000Tags.parse("   "), [])
        XCTAssertEqual(Radio80000Tags.parse("house"), ["house"])
        XCTAssertEqual(Radio80000Tags.parse("\"deep house\""), ["deep house"])
    }

    // MARK: - Mixcloud broadcasts

    private let cloudcast = """
    {"key":"/Radio80K/all-exhales-010323/","url":"https://www.mixcloud.com/Radio80K/all-exhales-010323/",
     "name":"(All Exhales) (01/03/23)","slug":"all-exhales-010323",
     "created_time":"2023-03-01T16:14:31Z","audio_length":3513,
     "tags":[{"name":"Metal","key":"/discover/metal/"}],
     "pictures":{"large":"https://x/large.jpg","thumbnail":"https://x/thumb.jpg"},
     "sections":[{"start_time":0,"track":{"name":"Opener","artist":{"name":"Someone"}}},
                 {"start_time":312,"track":{"name":"Second","artist":null}}]}
    """

    func testMixcloudCloudcastParses() throws {
        let parsed = try XCTUnwrap(
            decode(MixcloudCloudcastDTO.self, cloudcast).asRadio80000Episode()
        )

        XCTAssertEqual(parsed.title, "(All Exhales) (01/03/23)")
        XCTAssertEqual(parsed.source, .mixcloud)
        XCTAssertEqual(parsed.duration, 3513)
        XCTAssertEqual(parsed.genres, ["Metal"])
        XCTAssertEqual(parsed.artworkURL?.absoluteString, "https://x/large.jpg")
        XCTAssertEqual(parsed.mediaID, "radio80000.episode.mc:Radio80K/all-exhales-010323")
    }

    /// Mixcloud is the only one of the two that logs a tracklist, and it gives
    /// a start time per track.
    func testMixcloudTracklistCarriesOffsets() throws {
        let parsed = try XCTUnwrap(
            decode(MixcloudCloudcastDTO.self, cloudcast).asRadio80000Episode()
        )

        XCTAssertEqual(parsed.tracks.count, 2)
        XCTAssertEqual(parsed.tracks[0].display, "Someone — Opener")
        XCTAssertEqual(parsed.tracks[1].display, "Second", "No artist logged is not an em dash")
        XCTAssertEqual(parsed.tracks[1].offsetLabel, "0:05:12")
    }

    // MARK: - Episode identity

    /// The crate keeps only this string, and a listener can open a crated
    /// broadcast months later from a cold start — so it has to say where the
    /// recording lives and how to ask for it back.
    func testEpisodeIDsRoundTrip() {
        let withShow = Radio80000EpisodeID.soundcloud(trackID: 2_377_388_648, showSlug: "sonic-vacation")
        XCTAssertEqual(withShow, "sc:2377388648@sonic-vacation")
        XCTAssertEqual(
            Radio80000EpisodeID.parse(withShow),
            .soundcloud(trackID: 2_377_388_648, showSlug: "sonic-vacation")
        )

        let bare = Radio80000EpisodeID.soundcloud(trackID: 42, showSlug: nil)
        XCTAssertEqual(bare, "sc:42")
        XCTAssertEqual(Radio80000EpisodeID.parse(bare), .soundcloud(trackID: 42, showSlug: nil))

        let mixcloud = Radio80000EpisodeID.mixcloud(key: "/Radio80K/all-exhales-010323/")
        XCTAssertEqual(mixcloud, "mc:Radio80K/all-exhales-010323")
        XCTAssertEqual(
            Radio80000EpisodeID.parse(mixcloud),
            .mixcloud(key: "Radio80K/all-exhales-010323")
        )
    }

    func testUnreadableEpisodeIDsAreRejectedRatherThanGuessed() {
        XCTAssertNil(Radio80000EpisodeID.parse(""))
        XCTAssertNil(Radio80000EpisodeID.parse("2377388648"))
        XCTAssertNil(Radio80000EpisodeID.parse("sc:notanumber"))
        XCTAssertNil(Radio80000EpisodeID.parse("mc:"))
    }

    // MARK: - Titles

    /// Broadcast titles are typed by hand every week — "SHOW w/ guest (date)".
    /// The show part is pulled out only as a label, and matched against the
    /// real directory rather than trusted.
    func testShowNameIsRecoveredFromABroadcastTitle() {
        XCTAssertEqual(
            Radio80000Title.showName(from: "SONIC VACATION w/ heronymus (07/08/26)"),
            "SONIC VACATION"
        )
        XCTAssertEqual(Radio80000Title.showName(from: "-270C (25/01/24)"), "-270C")
        XCTAssertEqual(Radio80000Title.showName(from: "Room Service (26/08/26)"), "Room Service")
        XCTAssertEqual(
            Radio80000Title.showName(from: "Cascade w/ Kiawash (26/05/26)"),
            "Cascade"
        )
        XCTAssertNil(Radio80000Title.showName(from: "(26/08/26)"), "A date alone names no show")
    }

    // MARK: - Paging

    /// The proxy answers the first page as an object carrying a cursor and
    /// every later page as a bare array, which a single shape has to take.
    func testTrackPageAcceptsBothShapesTheProxyReturns() throws {
        let first = """
        {"collection":[\(track)],
         "next_href":"users/141829514/tracks?cursor=2026-08-07T14%3A18%3A05.000Z%2Ctracks%2C0001&linked_partitioning=true"}
        """
        let page = try decode(Radio80000TrackPageDTO.self, first)
        XCTAssertEqual(page.collection.count, 1)
        XCTAssertEqual(page.nextCursor, "2026-08-07T14:18:05.000Z,tracks,0001")

        let later = try decode(Radio80000TrackPageDTO.self, "[\(track)]")
        XCTAssertEqual(later.collection.count, 1)
        XCTAssertNil(later.nextCursor, "A bare array is the last page")
    }

    // MARK: - Airtime

    /// `week-info` mixes fourteen day arrays with scalars like the API
    /// version, so anything that is not a list of slots is skipped rather
    /// than throwing the document away.
    func testWeekInfoReadsTheDaysAndIgnoresTheRest() throws {
        let json = """
        {"monday":[{"start_timestamp":"2026-08-31 08:00:00","end_timestamp":"2026-08-31 09:00:00",
                    "name":"tune in or not","description":"","id":3729,"instance_id":73210}],
         "tuesday":[{"start_timestamp":"2026-09-01 10:00:00","end_timestamp":"2026-09-01 11:00:00",
                     "name":"pushin (P)roduction","description":"","id":3730,"instance_id":73211}],
         "AIRTIME_API_VERSION":"1.1"}
        """
        let week = try decode(AirtimeWeekInfoDTO.self, json)
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let slots = week.slots(zone: zone)

        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(slots.map(\.slot.name), ["tune in or not", "pushin (P)roduction"])
        XCTAssertTrue(slots[0].starts < slots[1].starts, "Ordered on the timestamps, not the keys")
    }

    /// Airtime writes local times with no offset attached, so reading them in
    /// the wrong zone silently shifts the whole schedule.
    func testWeekInfoTimesAreReadInTheStationsZone() throws {
        let json = """
        {"monday":[{"start_timestamp":"2026-08-31 08:00:00","end_timestamp":"2026-08-31 09:00:00",
                    "name":"tune in or not","id":1,"instance_id":2}]}
        """
        let week = try decode(AirtimeWeekInfoDTO.self, json)
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))

        let inBerlin = try XCTUnwrap(week.slots(zone: berlin).first).starts
        let inUTC = try XCTUnwrap(week.slots(zone: utc).first).starts
        // Berlin is two hours ahead of UTC on that date.
        XCTAssertEqual(inUTC.timeIntervalSince(inBerlin), 7200, accuracy: 1)
    }

    // MARK: - Playback

    func testBroadcastsPlayThroughTheirOwnPlatformsWidget() throws {
        let fromSoundCloud = try XCTUnwrap(decode(Radio80000TrackDTO.self, track).asEpisode())
        XCTAssertEqual(fromSoundCloud.mediaItem().embedProvider, .soundcloud)
        XCTAssertEqual(fromSoundCloud.mediaItem().sourceID, "radio80000")

        let fromMixcloud = try XCTUnwrap(
            decode(MixcloudCloudcastDTO.self, cloudcast).asRadio80000Episode()
        )
        XCTAssertEqual(fromMixcloud.mediaItem().embedProvider, .mixcloud)
    }

    /// The station id is what the player and the sidebar key off, and the
    /// crate stores it — so it is not free to drift.
    func testStationIdentityIsStable() {
        XCTAssertEqual(Radio80000Provider.providerID, "radio80000")
    }

    // MARK: - Malformed records

    func testARecordWithNothingUsableIsDropped() throws {
        XCTAssertNil(try decode(Radio80000ShowDTO.self, #"{"id":1}"#).asShow())
        XCTAssertNil(try decode(Radio80000TrackDTO.self, #"{"id":1,"title":"No link"}"#).asEpisode())
        XCTAssertNil(
            try decode(MixcloudCloudcastDTO.self, #"{"name":"No key"}"#).asRadio80000Episode()
        )
    }
}
