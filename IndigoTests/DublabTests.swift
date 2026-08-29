//
//  DublabTests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on dublab.com. dublab is WordPress
//  behind a Vue front end, which shows in the wire format: a field with no
//  value comes back as `false` rather than being omitted, and every prose
//  field arrives as rendered HTML.
//

import XCTest
@testable import Indigo

final class DublabTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Broadcasts

    private let broadcast = """
    {"url":"/archive/addae-safe-in-sound-08-26-26",
     "title":"Addae \\u2014 Safe in Sound (08.26.26)",
     "slug":"addae-safe-in-sound-08-26-26",
     "template":"broadcast",
     "thumbnail":232790,
     "files":{"232790":{"ID":232790,"url":"https://x/full.jpg","width":2560,"height":2560,
                        "sizes":{"medium":"https://x/300.jpg","large":"https://x/1000.jpg"}}},
     "audio":{"title":"Addae","url":"https://archives/26_08_26_Safe_in_Sound.mp3"},
     "broadcast_date":"20260826",
     "tags":[{"name":"Film","slug":"film"},{"name":"Soundtracks","slug":"soundtracks"}],
     "artists":["Addae"],
     "artist_slugs":["addae"],
     "guest_session":false,
     "links":[{"title":"Bandcamp","url":"https://addae.bandcamp.com"},{"title":"","url":"not a url"}],
     "show":{"ID":1,"post_title":"Safe in Sound","post_name":"safe-in-sound",
             "post_content":"<p>An audio altar.</p>\\r\\n<p>For listeners.</p>"},
     "show_performer":[{"ID":2,"post_title":"Addae","post_content":"<p>A composer &amp; selector.</p>"}]}
    """

    func testBroadcastParsesIntoSomethingPlayable() throws {
        let parsed = try XCTUnwrap(decode(DublabEntryDTO.self, broadcast).asBroadcast())

        XCTAssertEqual(parsed.slug, "addae-safe-in-sound-08-26-26")
        XCTAssertEqual(parsed.title, "Addae — Safe in Sound (08.26.26)")
        XCTAssertTrue(parsed.isPlayable)
        XCTAssertEqual(parsed.audioURL?.lastPathComponent, "26_08_26_Safe_in_Sound.mp3")
        XCTAssertEqual(parsed.genreNames, ["Film", "Soundtracks"])
        XCTAssertEqual(parsed.artists, ["Addae"])
        XCTAssertEqual(parsed.showName, "Safe in Sound")
        XCTAssertEqual(parsed.performer, "Addae")
    }

    /// The archive lists a dozen image sizes; a grid tile has no business
    /// pulling the 2560px scan.
    func testArtworkPrefersASizeAGridCanUse() throws {
        let parsed = try XCTUnwrap(decode(DublabEntryDTO.self, broadcast).asBroadcast())

        XCTAssertEqual(parsed.artworkURL?.absoluteString, "https://x/1000.jpg")
    }

    func testBroadcastIdentityRoundTripsThroughTheCrate() throws {
        let parsed = try XCTUnwrap(decode(DublabEntryDTO.self, broadcast).asBroadcast())
        let item = try XCTUnwrap(parsed.mediaItem())

        XCTAssertEqual(parsed.mediaID, "dublab.broadcast.addae-safe-in-sound-08-26-26")
        XCTAssertEqual(item.kind, .episode)
        XCTAssertNil(item.embedProvider, "dublab publishes plain MP3s, so nothing has to be embedded")
        XCTAssertEqual(item.genres, ["Film", "Soundtracks"])
    }

    func testProseArrivesAsMarkupAndLeavesAsText() throws {
        let parsed = try XCTUnwrap(decode(DublabEntryDTO.self, broadcast).asBroadcast())

        XCTAssertEqual(parsed.showSummary, "An audio altar.\nFor listeners.")
        XCTAssertEqual(parsed.performerSummary, "A composer & selector.")
    }

    func testLinksThatArenNotAddressesAreDropped() throws {
        let parsed = try XCTUnwrap(decode(DublabEntryDTO.self, broadcast).asBroadcast())

        XCTAssertEqual(parsed.links.map(\.label), ["Bandcamp"])
    }

    /// WordPress writes `false` where a field has no value, so a guest session
    /// with no parent show is a different JSON type in the same field.
    func testFalsyFieldsDoNotTakeTheEntryDownWithThem() throws {
        let json = """
        {"url":"/archive/amir-elahi-guest-session-08-27-26",
         "title":"Amir Elahi \\u2014 guest session (08.27.26)",
         "slug":"amir-elahi-guest-session-08-27-26",
         "audio":{"url":"https://archives/x.mp3"},
         "broadcast_date":"20260827",
         "guest_session":true,
         "show":false,
         "show_performer":false,
         "thumbnail":false,
         "tags":false,
         "links":false,
         "files":[]}
        """
        let parsed = try XCTUnwrap(decode(DublabEntryDTO.self, json).asBroadcast())

        XCTAssertEqual(parsed.title, "Amir Elahi — guest session (08.27.26)")
        XCTAssertTrue(parsed.isGuestSession)
        XCTAssertNil(parsed.showName)
        XCTAssertNil(parsed.performer)
        XCTAssertNil(parsed.artworkURL)
        XCTAssertTrue(parsed.genres.isEmpty)
        XCTAssertTrue(parsed.isPlayable, "A guest session is still a broadcast")
    }

    func testBroadcastWithoutATitleIsNotABroadcast() throws {
        let json = #"{"url":"/archive/x","slug":"x","title":""}"#
        XCTAssertNil(try decode(DublabEntryDTO.self, json).asBroadcast())
    }

    // MARK: - DJs

    func testDJParsesWithTheirShows() throws {
        let json = """
        {"url":"/djs/addae","title":"Addae","slug":"addae","template":"dj","is_active":true,
         "thumbnail":232790,
         "files":{"232790":{"ID":232790,"url":"https://x/full.jpg","sizes":{"large":"https://x/1000.jpg"}}},
         "content":"<p>A composer and music selector.</p>\\n",
         "shows":[{"title":"Safe in Sound","url":"/shows/safe-in-sound"}]}
        """
        let dj = try XCTUnwrap(decode(DublabEntryDTO.self, json).asDJ())

        XCTAssertEqual(dj.name, "Addae")
        XCTAssertTrue(dj.isActive)
        XCTAssertEqual(dj.biography, "A composer and music selector.")
        XCTAssertEqual(dj.shows.map(\.slug), ["safe-in-sound"])
        XCTAssertEqual(dj.artworkURL?.absoluteString, "https://x/1000.jpg")
    }

    // MARK: - Time

    /// dublab writes every time in its own wall clock with no offset attached,
    /// so a slot read in any other zone is simply the wrong slot.
    func testStationTimesAreReadInTheStationsZone() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let parsed = try XCTUnwrap(DublabTimestamp.parse("2026-08-29 12:00:00", zone: zone))

        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 29; components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        XCTAssertEqual(parsed, calendar.date(from: components))

        XCTAssertNotNil(DublabTimestamp.parse("2026-08-29 18:03:11.000000", zone: zone), "Airtime adds microseconds")
        XCTAssertNil(DublabTimestamp.parse("", zone: zone))
    }

    func testBroadcastDatesAreADateAndNothingMore() throws {
        let parsed = try XCTUnwrap(DublabTimestamp.parseBroadcastDate("20260826"))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(formatter.string(from: parsed), "2026-08-26")
        XCTAssertNil(DublabTimestamp.parseBroadcastDate("2026-08"))
    }

    func testScheduleEntryNeedsBothEndsOfItsSlot() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let good = """
        {"url":"/schedule/1/x","title":"The Sounds of Now","content":"<p>New music.</p>",
         "event_start_date":"2026-08-31","event_start_time":"00:00:00",
         "event_end_date":"2026-08-31","event_end_time":"09:30:00"}
        """
        let entry = try XCTUnwrap(decode(DublabEntryDTO.self, good).asScheduleEntry(zone: zone))
        XCTAssertEqual(entry.title, "The Sounds of Now")
        XCTAssertEqual(entry.summary, "New music.")
        XCTAssertTrue(entry.contains(entry.startsAt.addingTimeInterval(60)))

        let backwards = """
        {"url":"/schedule/2/y","title":"Broken",
         "event_start_date":"2026-08-31","event_start_time":"10:00:00",
         "event_end_date":"2026-08-31","event_end_time":"09:00:00"}
        """
        XCTAssertNil(try decode(DublabEntryDTO.self, backwards).asScheduleEntry(zone: zone))
    }

    // MARK: - Airtime

    /// Airtime answers with an object where there is one item and an array
    /// where there are several — or none at all.
    func testLiveInfoAcceptsObjectOrArrayForNextAndPrevious() throws {
        let json = """
        {"station":{"timezone":"America/Los_Angeles"},
         "tracks":{"previous":{"name":"a"},"current":{"name":"b","starts":"2026-08-29 12:00:00",
                   "ends":"2026-08-29 13:44:20",
                   "metadata":{"track_title":"PRAISE: Dolly Parton P1","artist_name":"dublab Broadcast Team"}},
                   "next":{"name":"c"}},
         "shows":{"previous":[],"current":{"name":"PRAISE: Dolly Parton","starts":"2026-08-29 12:00:00",
                  "ends":"2026-08-29 15:50:00"},
                  "next":[{"name":"sounds of NOW","starts":"2026-08-29 15:50:00","ends":"2026-08-29 16:00:00"}]}}
        """
        let parsed = try decode(AirtimeLiveInfoDTO.self, json)

        XCTAssertEqual(parsed.station?.timezone, "America/Los_Angeles")
        XCTAssertEqual(parsed.shows?.current?.name, "PRAISE: Dolly Parton")
        XCTAssertEqual(parsed.shows?.next.count, 1)
        XCTAssertTrue(parsed.shows?.previous.isEmpty ?? false)
        XCTAssertEqual(parsed.tracks?.next.count, 1, "A single object is a list of one")
        XCTAssertEqual(parsed.tracks?.current?.metadata?.track_title, "PRAISE: Dolly Parton P1")
    }

    func testOnAirReportsHowFarThroughTheShowIs() {
        let start = Date.now.addingTimeInterval(-1800)
        let onAir = DublabOnAir(
            showName: "PRAISE",
            showStartsAt: start,
            showEndsAt: start.addingTimeInterval(3600),
            trackTitle: "P1",
            trackArtist: "dublab",
            upNext: []
        )
        XCTAssertEqual(try XCTUnwrap(onAir.elapsedFraction), 0.5, accuracy: 0.02)
        XCTAssertEqual(onAir.asRadioShow().location, "Los Angeles")
    }

    // MARK: - Narrowing

    func testASearchOfUnderTwoCharactersIsNotASearch() {
        var query = DublabBrowseStore.ArchiveQuery()
        query.search = "d"
        XCTAssertFalse(query.isSearching)
        query.search = "dolly"
        XCTAssertTrue(query.isSearching)
        XCTAssertTrue(query.isFiltered)

        var filtered = DublabBrowseStore.ArchiveQuery()
        XCTAssertFalse(filtered.isFiltered)
        filtered.genre = "dance"
        XCTAssertTrue(filtered.isFiltered)
    }
}
