//
//  NoodsTests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on panel.noodsradio.com.
//

import XCTest
@testable import Indigo

final class NoodsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: Show cards

    private let card = """
    {"id":"shows/skin-two-w-silver-tuxedomoon-special-25th-august-26",
     "artisttag":"Silver","date":"25.08.26",
     "genretag":["New Wave","Post-Punk"],
     "genretags":["New Wave","Post-Punk","New Wave","Avant-Garde"],
     "mixcloud":"https://mixcloud.com/noodsradio/skin-two-w-silver","soundcloud":"https://soundcloud.com/noodsradio/skin-two-w-silver?utm_source=x",
     "residentid":"","artworkSm":"https://panel.noodsradio.com/a-25x25.jpg",
     "artworkMd":"https://panel.noodsradio.com/a-300x300.jpg"}
    """

    func testShowCardParses() throws {
        let show = try XCTUnwrap(decode(NoodsShowDTO.self, card).asShow())

        XCTAssertEqual(show.slug, "skin-two-w-silver-tuxedomoon-special-25th-august-26")
        XCTAssertEqual(show.artist, "Silver")
        XCTAssertEqual(show.audio?.provider, .soundcloud, "SoundCloud is preferred over Mixcloud")
        XCTAssertEqual(show.audio?.url.absoluteString,
                       "https://soundcloud.com/noodsradio/skin-two-w-silver",
                       "Share tracking must be stripped for the widget")
        XCTAssertNil(show.residentPath, "An empty resident id is not a resident")
        XCTAssertEqual(show.mediaID, "noods.show.skin-two-w-silver-tuxedomoon-special-25th-august-26")
    }

    /// Half of Noods' catalogue serialises its genre list as an object keyed
    /// "1","2","3" rather than an array. Decoding one shape only threw away
    /// every page containing the other — including all of Collections.
    func testGenreListAcceptsBothShapes() throws {
        let asObject = """
        {"id":"shows/x","title":"X","date":"25.08.26",
         "genretags":{"3":"Downtempo","1":"Ambient","2":"Electronica"}}
        """
        XCTAssertEqual(try decode(NoodsShowDTO.self, asObject).asShow()?.genres,
                       ["Ambient", "Electronica", "Downtempo"],
                       "Numeric keys carry the order and must sort as numbers, not strings")

        let asArray = """
        {"id":"shows/y","title":"Y","date":"25.08.26","genretags":["Ambient","Electronica"]}
        """
        XCTAssertEqual(try decode(NoodsShowDTO.self, asArray).asShow()?.genres, ["Ambient", "Electronica"])

        let missing = """
        {"id":"shows/z","title":"Z","date":"25.08.26"}
        """
        XCTAssertEqual(try decode(NoodsShowDTO.self, missing).asShow()?.genres, [])
    }

    /// Noods repeats genre tags — one live show carried "Ambient" four times.
    func testGenreTagsAreDedupedWithoutReordering() throws {
        let show = try XCTUnwrap(decode(NoodsShowDTO.self, card).asShow())
        XCTAssertEqual(show.genres, ["New Wave", "Post-Punk", "Avant-Garde"])
    }

    /// `artisttag` is a string on a card and an array on a show page.
    func testArtistTagAcceptsBothShapes() throws {
        let asArray = """
        {"id":"shows/x","title":"X","artisttag":["Ancient Grains","Lupini"],"date":"30.04.26"}
        """
        XCTAssertEqual(try decode(NoodsShowDTO.self, asArray).asShow()?.artist, "Ancient Grains, Lupini")

        let asEmptyArray = """
        {"id":"shows/y","title":"Y","artisttag":[],"date":"30.04.26"}
        """
        XCTAssertNil(try decode(NoodsShowDTO.self, asEmptyArray).asShow()?.artist)
    }

    func testAShowWithNoAudioIsNotPlayable() throws {
        let json = """
        {"id":"shows/inklingroom-26th-august-26","title":"inklingroom",
         "date":"27.08.26","mixcloud":"","soundcloud":"","genretags":[]}
        """
        let show = try XCTUnwrap(decode(NoodsShowDTO.self, json).asShow())
        XCTAssertFalse(show.isPlayable)
        XCTAssertNil(show.mediaItem())
    }

    func testShowUsesLargestSrcsetWhenMediumArtworkIsMissing() throws {
        let json = """
        {"id":"shows/archive","title":"Archive","artworkSm":"https://x/cover-25x25.jpg",
         "srcset":"https://x/cover-175x.jpg 175w, https://x/cover-225x.jpg 225w"}
        """
        let show = try XCTUnwrap(decode(NoodsShowDTO.self, json).asShow())
        XCTAssertEqual(show.artworkURL?.absoluteString, "https://x/cover-225x.jpg")
    }

    // MARK: Dates

    /// Noods writes three two-digit parts and not always in the same order:
    /// shows are day-first, collections month-first. Both have to land.
    func testBothDateOrderingsParse() {
        let calendar = Calendar(identifier: .gregorian)

        let show = try? XCTUnwrap(NoodsDate.parse("25.08.26"))
        XCTAssertEqual(calendar.component(.day, from: show!), 25)
        XCTAssertEqual(calendar.component(.month, from: show!), 8)
        XCTAssertEqual(calendar.component(.year, from: show!), 2026)

        // 30 can't be a month, so the month-first reading wins.
        let collection = try? XCTUnwrap(NoodsDate.parse("04.30.26"))
        XCTAssertEqual(calendar.component(.day, from: collection!), 30)
        XCTAssertEqual(calendar.component(.month, from: collection!), 4)

        XCTAssertNil(NoodsDate.parse("nonsense"))
        XCTAssertNil(NoodsDate.parse(nil))
    }

    // MARK: Markup

    func testTracklistSplitsOnLineBreaks() {
        let html = "<p>Tuxedomoon - Today<br />\nPeter Principle - Dolphins<br />\nTuxedomoon - Willie</p>"
        XCTAssertEqual(NoodsMarkup.lines(html), [
            "Tuxedomoon - Today", "Peter Principle - Dolphins", "Tuxedomoon - Willie"
        ])
    }

    func testMarkupDecodesEntitiesAndDropsTags() {
        let html = "<p>Spirits &amp; Ghosts <em>live</em></p>"
        XCTAssertEqual(NoodsMarkup.text(html), "Spirits & Ghosts live")
        XCTAssertNil(NoodsMarkup.text(""))
        XCTAssertTrue(NoodsMarkup.lines(nil).isEmpty)
    }

    /// Rich text is `{"html": "…"}` when populated and a bare `""` when not.
    func testRichTextAcceptsBothShapes() throws {
        let object = """
        {"id":"shows/a","title":"A","date":"25.08.26","description":{"html":"<p>Hello</p>"}}
        """
        XCTAssertEqual(NoodsMarkup.text(try decode(NoodsShowDetailDTO.self, object).description?.html), "Hello")

        let bare = """
        {"id":"shows/b","title":"B","date":"25.08.26","description":""}
        """
        let parsed = try decode(NoodsShowDetailDTO.self, bare)
        XCTAssertNil(parsed.description?.html)
        XCTAssertNotNil(parsed.asDetail(path: "shows/b"), "An empty description must not lose the show")
    }

    // MARK: Feeds

    func testFeedParsesPostsAndPagination() throws {
        let json = """
        {"title":"Guests","posts":[\(card)],
         "pagination":{"hasNextPage":true,"paginationUrl":"https://panel.noodsradio.com/shows/guests.json?page=2"}}
        """
        let feed = try decode(NoodsFeedDTO.self, json)

        XCTAssertEqual(feed.title, "Guests")
        XCTAssertEqual((feed.posts ?? []).compactMap { $0.asShow() }.count, 1)
        XCTAssertNotNil(feed.pagination?.next)
    }

    func testDiscoverCarriesBothLists() throws {
        let json = """
        {"title":"Shows","featured":[\(card)],"latest":[\(card)]}
        """
        let discover = try decode(NoodsDiscoverDTO.self, json)
        XCTAssertEqual(discover.featured?.count, 1)
        XCTAssertEqual(discover.latest?.count, 1)
    }

    // MARK: Filter

    /// With no genre selected the endpoint answers with an array of ints
    /// instead of cards. Decoding that as cards threw away the whole page.
    func testFilterSurvivesTheUnselectedShape() throws {
        let unselected = """
        {"title":"Filter","genres":[],"groups":[],"page":1,"pages":1,"shows":[1,2,3],"totalShows":0}
        """
        let response = try decode(NoodsFilterDTO.self, unselected)
        XCTAssertEqual(response.shows?.count, 0)
        XCTAssertEqual(response.totalShows, 0)
    }

    /// `page` and `pages` arrive as numbers but `totalShows` as a string.
    func testFilterParsesASelectedPage() throws {
        let json = """
        {"title":"Filter","genres":["Ambient"],"page":2,"pages":243,"totalShows":"5823","shows":[\(card)]}
        """
        let response = try decode(NoodsFilterDTO.self, json)

        XCTAssertEqual(response.genres, ["Ambient"])
        XCTAssertEqual(response.page, 2)
        XCTAssertEqual(response.pages, 243)
        XCTAssertEqual(response.totalShows, 5823)
        XCTAssertEqual((response.shows ?? []).compactMap { $0.asShow() }.count, 1)
    }

    // MARK: Residents

    func testResidentDetailParses() throws {
        let json = """
        {"id":"residents/melodic-odds","title":"Melodic Odds",
         "scheduleString":"2000 - 2100 • Friday • Every 4 Weeks","location":"London",
         "ogdescription":"Rosie Ama explores the sonic spaces between the beautiful and the strange.",
         "image":"https://panel.noodsradio.com/r-300x.jpg",
         "posts":[\(card)],
         "pagination":{"hasNextPage":true,"paginationUrl":"https://panel.noodsradio.com/residents/melodic-odds.json?page=2"},
         "similarresidents":[{"id":"residents/other","title":"Other Show","image":"https://x/y.jpg"}]}
        """
        let resident = try decode(NoodsResidentDTO.self, json).asResident(path: "residents/melodic-odds")

        XCTAssertEqual(resident.name, "Melodic Odds")
        XCTAssertEqual(resident.location, "London")
        XCTAssertEqual(resident.schedule, "2000 - 2100 • Friday • Every 4 Weeks")
        XCTAssertEqual(resident.shows.count, 1)
        XCTAssertNotNil(resident.nextPage)
        XCTAssertEqual(resident.similar.first?.name, "Other Show")
    }

    /// The A–Z groups and the flat list describe the same people; taking both
    /// would list everyone twice.
    func testResidentsIndexPrefersTheGroupedList() throws {
        let json = """
        {"title":"Residents",
         "promotedResidents":[{"id":"residents/melodic-odds","title":"Melodic Odds","image":"https://x/p.jpg"}],
         "children":[[{"needle":"A","id":"residents/a-better-break","title":"A Better Break"}],
                     [{"needle":"B","id":"residents/beats","title":"Beats"}]],
         "unsorted":[{"id":"residents/a-better-break","title":"A Better Break"},
                     {"id":"residents/beats","title":"Beats"}]}
        """
        let dto = try decode(NoodsResidentsDTO.self, json)
        let grouped = (dto.children ?? []).flatMap { $0 }.compactMap { $0.asRef() }

        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped.first?.needle, "A")
        XCTAssertEqual(dto.promotedResidents?.count, 1)
    }

    func testResidentUsesLargestSrcsetCandidate() throws {
        let json = """
        {"id":"residents/a","title":"A",
         "srcset":"https://x/a-41x.jpg 41w, https://x/a-414x.jpg 414w, https://x/a-300x.jpg 300w"}
        """
        let resident = try XCTUnwrap(decode(NoodsResidentRefDTO.self, json).asRef())
        XCTAssertEqual(resident.artworkURL?.absoluteString, "https://x/a-414x.jpg")
    }

    // MARK: Collections

    func testCollectionParses() throws {
        let json = """
        {"id":"collections/avon-moot-26","title":"Avon Moot","date":"04.30.26","featured":true,
         "excerpt":"We teamed up with our Celtic siblings EHFM.","collectionType":"takeover",
         "artworkSm":"https://panel.noodsradio.com/c-100x100.jpg","location":"Bristol",
         "shows":[\(card)]}
        """
        let collection = try XCTUnwrap(decode(NoodsCollectionDTO.self, json).asCollection())

        XCTAssertEqual(collection.title, "Avon Moot")
        XCTAssertEqual(collection.kind, "Takeover")
        XCTAssertEqual(collection.slug, "avon-moot-26")
        XCTAssertTrue(collection.isFeatured)
        XCTAssertEqual(collection.shows.count, 1)
        XCTAssertEqual(collection.artworkURL?.absoluteString,
                       "https://panel.noodsradio.com/c-900x.jpg")
    }

    // MARK: Show detail

    func testShowDetailCarriesItsTracklist() throws {
        let json = """
        {"id":"shows/skin-two","title":"Skin Two w/ Silver","date":"25.08.26",
         "artisttag":[],"description":{"html":"<p>An hour dedicated to the cult band.</p>"},
         "genretags":["New Wave","New Wave","Post-Punk"],
         "tracklist":{"html":"<p>Tuxedomoon - Today<br />\\nPeter Principle - Dolphins</p>"},
         "guestmix":true,"soundcloud":"https://soundcloud.com/noodsradio/skin-two","mixcloud":"",
         "ogimage":"https://panel.noodsradio.com/s-1200x630.jpg","residentId":"","similarshows":[\(card)]}
        """
        let detail = try XCTUnwrap(decode(NoodsShowDetailDTO.self, json).asDetail(path: "shows/skin-two"))

        XCTAssertEqual(detail.summary, "An hour dedicated to the cult band.")
        XCTAssertEqual(detail.tracklist, ["Tuxedomoon - Today", "Peter Principle - Dolphins"])
        XCTAssertTrue(detail.isGuestMix)
        XCTAssertEqual(detail.show.genres, ["New Wave", "Post-Punk"])
        XCTAssertEqual(detail.similar.count, 1)
        XCTAssertEqual(detail.show.mediaItem()?.embedProvider, .soundcloud)
    }
}
