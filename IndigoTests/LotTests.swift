//
//  LotTests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on www.thelotradio.com. The Lot ships
//  its data as a React Flight stream rather than as a document, so the parsing
//  is worth pinning down: a text row's length is counted in bytes, one row
//  runs straight into the next, and the tree refers to hoisted strings by id.
//

import XCTest
@testable import Indigo

final class LotTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testSparseShowDetailKeepsDirectoryArtwork() throws {
        let photo = try XCTUnwrap(URL(string: "https://images.example/show.jpg"))
        let directory = LotShow(
            id: "show-id", name: "Residency", slug: "residency",
            photoURL: photo, genres: [], artists: []
        )
        let detail = LotShow(
            id: "show-id", name: "Residency", slug: "residency",
            photoURL: nil, genres: [], artists: []
        )

        XCTAssertEqual(detail.fillingMissingFields(from: directory).photoURL, photo)
    }

    // MARK: - Flight

    /// Row 1 is JSON and newline-terminated; rows 2 and 3 are length-prefixed
    /// text and run into each other with no separator at all. "Réveil Créole"
    /// is fifteen bytes and thirteen characters, which is the whole point.
    private let stream = """
    0:{"a":"$@1","f":"","q":"","i":false}
    1:{"schedule":[{"id":"a","summary":"NO DAWN","description":"$2","start":"2026-08-20T22:00:00-04:00","end":"2026-08-21T00:00:00-04:00","reccuring":true},{"id":"b","summary":"Bloxam","description":"$3","start":"2026-08-21T00:00:00-04:00","end":"2026-08-21T02:00:00-04:00"}]}
    2:T1b,On this edition of NO DAWN.3:Tf,Réveil Créole
    """

    func testFlightResolvesHoistedTextByRowID() {
        let flight = LotFlight(stream: stream)

        XCTAssertEqual(flight.resolve("$2"), "On this edition of NO DAWN.")
        XCTAssertEqual(
            flight.resolve("$3"), "Réveil Créole",
            "A text row's length is a byte count, so a multibyte row must not be cut short"
        )
        XCTAssertEqual(flight.resolve("Already text"), "Already text")
        XCTAssertNil(flight.resolve(nil))
    }

    func testFlightReadsTheValueAServerActionReturned() throws {
        let result = try XCTUnwrap(LotFlight(stream: stream).actionResult)
        let decoded = try JSONDecoder().decode([String: [LotCalendarEntryDTO]].self, from: result)

        XCTAssertEqual(decoded["schedule"]?.count, 2, "Row 0 points at the row holding the return value")
    }

    func testFlightRebuildsTheStreamAPageShipsInItsMarkup() {
        let html = """
        <script>self.__next_f.push([1,"1:{\\"live\\":\\"The Lot Live\\"}\\n"])</script>
        <script>self.__next_f.push([1,"2:T5,hello"])</script>
        """
        let flight = LotFlight.page(html: html)

        XCTAssertEqual(flight.resolve("$2"), "hello", "Pushed slices concatenate into one stream")
    }

    func testFlightFindsTheObjectThatOwnsAKey() throws {
        let stream = #"1:{"page":{"wrap":{"transcodedFile":{"hls":"https://x/index.m3u8"},"slug":"a"},"other":{"slug":"b"}}}"#
        let objects = LotFlight(stream: stream).objects(containing: "transcodedFile")

        XCTAssertEqual(objects.count, 1)
        let owner = try decode(LotEpisodeDTO.self, String(decoding: objects[0], as: UTF8.self))
        XCTAssertEqual(owner.slug, "a", "The owner is the enclosing object, not the value under the key")
    }

    // MARK: - Episodes

    private let episode = """
    {"sys":{"id":"3hvMtZBCM39v79q73sYh2N"},
     "title":"Sluice with Luming Hao",
     "slug":"2026-08-21-1800",
     "date":"2026-08-21T22:00:00.000Z",
     "startTimestamp":"2026-08-21T22:01:18.000Z",
     "endTimestamp":"2026-08-21T23:00:13.000Z",
     "transcodedFile":{"hls":"https://link.storjshare.io/raw/x/hls/index.m3u8","mp4":[]},
     "tracklist":[{"title":"Letting Go","artist":"Hayden Pedigo","timestamp":"2026-08-21T22:02:58.000Z"},
                  {"title":"","artist":"Nobody","timestamp":"2026-08-21T22:05:17.000Z"}],
     "location":{"name":"The Lot Radio, NYC"},
     "genres":{"items":[{"sys":{"id":"g1"},"name":"folk","slug":"folk"},null]},
     "show":{"sys":{"id":"s1"},"name":"Sluice","slug":"sluice",
             "artists":{"items":[{"sys":{"id":"a1"},"name":"Laenz","slug":"laenz","thisIsAResident":true,
                                  "socialInstagram":"https://www.instagram.com/laenzzz","linkBandcamp":null}]}}}
    """

    func testEpisodeParsesIntoSomethingPlayable() throws {
        let parsed = try XCTUnwrap(decode(LotEpisodeDTO.self, episode).asEpisode())

        XCTAssertEqual(parsed.id, "3hvMtZBCM39v79q73sYh2N")
        XCTAssertEqual(parsed.streamURL?.absoluteString, "https://link.storjshare.io/raw/x/hls/index.m3u8")
        XCTAssertTrue(parsed.isPlayable)
        XCTAssertEqual(parsed.genreNames, ["folk"], "Unresolved Contentful links are holes, not failures")
        XCTAssertEqual(parsed.location, "The Lot Radio, NYC")
        XCTAssertEqual(try XCTUnwrap(parsed.duration), 3535, accuracy: 1, "Duration is what was broadcast, not what was booked")
    }

    /// The Lot logs tracks at wall-clock times. A tracklist is only seekable
    /// once those are measured against the moment the recording starts.
    func testTracklistOffsetsAreMeasuredFromTheBroadcastStart() throws {
        let parsed = try XCTUnwrap(decode(LotEpisodeDTO.self, episode).asEpisode())

        XCTAssertEqual(parsed.tracklist.count, 1, "A track with no title is not a track")
        let first = try XCTUnwrap(parsed.tracklist.first)
        XCTAssertEqual(first.index, 1)
        XCTAssertEqual(first.artist, "Hayden Pedigo")
        XCTAssertEqual(try XCTUnwrap(first.offset), 100, accuracy: 0.5)
        XCTAssertEqual(first.offsetLabel, "0:01:40")
    }

    func testEpisodeIdentityRoundTripsThroughTheCrate() throws {
        let parsed = try XCTUnwrap(decode(LotEpisodeDTO.self, episode).asEpisode())

        XCTAssertEqual(parsed.mediaID, "lot.episode.sluice/2026-08-21-1800")
        let ref = try XCTUnwrap(LotEpisodeRef.decode("sluice/2026-08-21-1800"))
        XCTAssertEqual(ref, parsed.ref)
        XCTAssertEqual(ref.path, "shows/sluice/2026-08-21-1800")
    }

    func testEpisodePlaysThroughTheFileEngineRatherThanAWidget() throws {
        let parsed = try XCTUnwrap(decode(LotEpisodeDTO.self, episode).asEpisode())
        let item = try XCTUnwrap(parsed.mediaItem())

        XCTAssertEqual(item.kind, .episode)
        XCTAssertNil(item.embedProvider, "The Lot archives to HLS, so nothing has to be embedded")
        XCTAssertFalse(item.isLive)
        XCTAssertEqual(item.genres, ["folk"])
    }

    func testArtistLinksSurviveAndEmptyOnesAreDropped() throws {
        let parsed = try XCTUnwrap(decode(LotEpisodeDTO.self, episode).asEpisode())
        let artist = try XCTUnwrap(parsed.show?.artists.first)

        XCTAssertTrue(artist.isResident)
        XCTAssertEqual(artist.links.count, 1)
        XCTAssertEqual(artist.links.first?.label, "Instagram")
    }

    /// Server actions send the asset inline. Server-rendered pages leave a
    /// path into the element tree behind instead — the same field, a different
    /// JSON type — and decoding has to survive both.
    func testAssetPathReferencesDoNotTakeTheEntryDownWithThem() throws {
        let json = """
        {"sys":{"id":"s1"},"name":"Sluice","slug":"sluice",
         "photo":"$6:props:children:0:props:asset",
         "artists":{"items":[{"sys":{"id":"a1"},"name":"Laenz","slug":"laenz",
                              "photo":"$6:props:children:1:props:asset"}]}}
        """
        let show = try XCTUnwrap(decode(LotShowDTO.self, json).asShow())

        XCTAssertEqual(show.name, "Sluice")
        XCTAssertNil(show.photoURL)
        XCTAssertEqual(show.artists.first?.name, "Laenz")
    }

    // MARK: - The calendar

    private func schedule(_ flight: LotFlight? = nil) throws -> [LotScheduleEntry] {
        let json = """
        [{"id":"a","summary":"Sluice with Luming Hao","description":"Guitar &amp; noise.<br><br><a href=\\"https://www.instagram.com/x\\">https://www.instagram.com/x</a>",
          "start":"2026-08-21T18:00:00-04:00","end":"2026-08-21T19:00:00-04:00","reccuring":true},
         {"id":"b","summary":"Bloxam","description":"$2",
          "start":"2026-08-21T19:00:00-04:00","end":"2026-08-21T20:00:00-04:00"},
         {"id":"c","summary":"Broken","start":"2026-08-21T21:00:00-04:00","end":"2026-08-21T20:00:00-04:00"}]
        """
        return try decode([LotCalendarEntryDTO].self, json)
            .compactMap { $0.asScheduleEntry(resolvedBy: flight) }
    }

    func testCalendarEntriesDropWhatCannotBeShownOnAClock() throws {
        let entries = try schedule()

        XCTAssertEqual(entries.count, 2, "A slot that ends before it starts is not a slot")
        XCTAssertEqual(entries.map(\.title), ["Sluice with Luming Hao", "Bloxam"])
    }

    func testCalendarDescriptionsBecomeTextRatherThanMarkup() throws {
        let entry = try XCTUnwrap(schedule().first)

        XCTAssertEqual(
            entry.summary, "Guitar & noise.",
            "An address printed in the middle of a paragraph is not prose"
        )
        XCTAssertEqual(entry.links.map(\.label), ["Instagram"])
        XCTAssertEqual(entry.links.first?.url.absoluteString, "https://www.instagram.com/x")
    }

    func testCalendarLinksKeepAnchorTextThatSaysSomething() {
        let parsed = LotMarkup.parse(#"Tickets: <a href="https://dice.fm/event/abc">this Thursday</a> only."#)

        XCTAssertEqual(parsed.text, "Tickets: this Thursday only.")
        XCTAssertEqual(parsed.links.map(\.label), ["Dice"])
    }

    func testCalendarDescriptionsHoistedIntoTheirOwnRowAreResolved() throws {
        let entries = try schedule(LotFlight(stream: stream))

        XCTAssertEqual(entries[1].summary, "On this edition of NO DAWN.")
    }

    /// The Lot bills a guest slot as "Residency with Guest". The shows
    /// directory is keyed by the residency alone.
    func testResidencyIsReadOutOfTheBookingTitle() throws {
        let entries = try schedule()

        XCTAssertEqual(entries[0].showName, "Sluice")
        XCTAssertEqual(entries[1].showName, "Bloxam", "A booking with no guest is already the residency")
    }

    func testOnAirIsWhicheverSlotContainsTheMoment() throws {
        let entries = try schedule()
        let during = try XCTUnwrap(entries.first?.startsAt.addingTimeInterval(600))

        XCTAssertEqual(entries.first { $0.contains(during) }?.title, "Sluice with Luming Hao")
        XCTAssertEqual(entries.first { $0.startsAt > during }?.title, "Bloxam")
    }

    // MARK: - Live channel

    func testLiveChannelPrefersTheHLSSourceAndReadsItsOwnState() throws {
        let json = """
        {"id":"3HLRjybGZbcW1Y1sCNyclQ","live":"The Lot Live","title":"The Lot Live",
         "src":[{"type":"webrtc","src":"https://livepeercdn.studio/webrtc/x","mime":"video/h264"},
                {"type":"hls","src":"https://livepeercdn.studio/hls/x/index.m3u8","mime":"application/vnd.apple.mpegurl"}],
         "poster":{"src":"https://recordings-cdn-s.lp-playback.studio/hls/x/source/latest.png","alt":"The Lot Live"},
         "playbackInfo":{"type":"live","meta":{"live":1}},
         "schedule":[]}
        """
        let channel = try XCTUnwrap(decode(LotLiveDTO.self, json).asChannel(resolvedBy: nil))

        XCTAssertEqual(channel.streamURL.absoluteString, "https://livepeercdn.studio/hls/x/index.m3u8")
        XCTAssertTrue(channel.isOnAir)
    }

    /// The booth camera only ever answers with its latest frame, and always at
    /// the same address, so the image layer would hold the first one forever.
    func testLivePosterIsStampedSoItCanRefresh() throws {
        let json = """
        {"title":"The Lot Live","src":[{"type":"hls","src":"https://x/index.m3u8"}],
         "poster":{"src":"https://x/latest.png"},"playbackInfo":{"meta":{"live":0}},"schedule":[]}
        """
        let channel = try XCTUnwrap(decode(LotLiveDTO.self, json).asChannel(resolvedBy: nil))
        let early = channel.posterURL(at: Date(timeIntervalSince1970: 0))
        let later = channel.posterURL(at: Date(timeIntervalSince1970: 600))

        XCTAssertNotNil(early)
        XCTAssertNotEqual(early, later)
        XCTAssertFalse(channel.isOnAir)
    }

    func testLiveChannelWithNoPlayableSourceIsNotAChannel() throws {
        let json = """
        {"title":"The Lot Live","src":[{"type":"webrtc","src":"https://x/webrtc"}],
         "playbackInfo":{"meta":{"live":1}},"schedule":[]}
        """
        XCTAssertNil(try decode(LotLiveDTO.self, json).asChannel(resolvedBy: nil))
    }

    // MARK: - Rich text

    func testRichTextFlattensToParagraphs() throws {
        let json = """
        {"json":{"data":{},"nodeType":"document","content":[
            {"nodeType":"paragraph","content":[{"nodeType":"text","value":"Knotty sludgy dubby excursions."}]},
            {"nodeType":"paragraph","content":[{"nodeType":"text","value":"Often "},
                                               {"nodeType":"text","value":"experimental."}]},
            {"nodeType":"paragraph","content":[{"nodeType":"text","value":"   "}]}]}}
        """
        let text = try decode(LotRichTextDTO.self, json).plainText

        XCTAssertEqual(text, "Knotty sludgy dubby excursions.\n\nOften experimental.")
    }
}
