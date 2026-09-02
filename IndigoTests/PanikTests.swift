//
//  PanikTests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on radiopanik.org. Panik is the first
//  station Indigo reads that publishes no catalogue API, so most of this is
//  about the two things that replace one: the podcast feeds its archive lives
//  in, and the markup its directory, week and track logs are read out of.
//
//  The markup tests matter more than usual. They are what will fail first if
//  the station is redesigned, and failing there is the point — it is a good
//  deal better than a page that quietly comes back empty.
//

import XCTest
@testable import Indigo

final class PanikTests: XCTestCase {

    // MARK: - The podcast feed

    private let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
        <title>Radio Panik - Podcasts</title>
        <description>Les podcasts</description>
        <itunes:image href="https://www.radiopanik.org/static/img/logo-panik-500.png"/>
        <item>
          <title>[Daydream Nation] Mixtape session #22</title>
          <link>https://www.radiopanik.org/emissions/daydream-nation/mixtape-session-22/</link>
          <description>&lt;p&gt;Une s&amp;eacute;lection.&lt;/p&gt;</description>
          <pubDate>Tue, 01 Sep 2026 19:05:16 +0200</pubDate>
          <guid>https://www.radiopanik.org/emissions/daydream-nation/mixtape-session-22/</guid>
          <enclosure length="73994577" type="audio/mpeg"
                     url="https://www.radiopanik.org/media/sounds/daydream-nation/mixtape_22857.mp3"/>
          <itunes:image href="https://www.radiopanik.org/media/images/daydream-nation/x.jpg"/>
          <itunes:duration>01:05:58</itunes:duration>
        </item>
        <item>
          <title>[Acouphène] Émission du 31</title>
          <link>/emissions/acouphene/emission-du-31/</link>
          <pubDate>Mon, 31 Aug 2026 20:30:00 +0200</pubDate>
          <enclosure length="10" type="audio/mpeg"
                     url="https://www.radiopanik.org/media/sounds/acouphene/a.mp3"/>
          <itunes:duration>3600</itunes:duration>
        </item>
      </channel>
    </rss>
    """

    func testFeedParses() throws {
        let parsed = try XCTUnwrap(PodcastFeedParser.parse(Data(feed.utf8)))

        XCTAssertEqual(parsed.title, "Radio Panik - Podcasts")
        XCTAssertEqual(
            parsed.imageURL?.absoluteString,
            "https://www.radiopanik.org/static/img/logo-panik-500.png"
        )
        XCTAssertEqual(parsed.items.count, 2)

        let first = parsed.items[0]
        XCTAssertEqual(first.title, "[Daydream Nation] Mixtape session #22")
        XCTAssertEqual(
            first.enclosureURL?.absoluteString,
            "https://www.radiopanik.org/media/sounds/daydream-nation/mixtape_22857.mp3"
        )
        XCTAssertEqual(first.enclosureBytes, 73_994_577)
        XCTAssertEqual(try XCTUnwrap(first.duration), 3958, accuracy: 1)
        XCTAssertNotNil(first.publishedAt)
    }

    /// iTunes permits a clock or a plain count of seconds, and stations use
    /// both — sometimes in the same feed, as this one does.
    func testDurationsInEitherForm() {
        XCTAssertEqual(try XCTUnwrap(PodcastFeedParser.duration("01:05:58")), 3958, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(PodcastFeedParser.duration("5:58")), 358, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(PodcastFeedParser.duration("3600")), 3600, accuracy: 1)
        XCTAssertNil(PodcastFeedParser.duration(nil))
        XCTAssertNil(PodcastFeedParser.duration(""))
        XCTAssertNil(PodcastFeedParser.duration("0"))
    }

    func testMalformedXMLIsRejectedRatherThanGuessed() {
        XCTAssertNil(PodcastFeedParser.parse(Data("not xml at all <<<".utf8)))
    }

    // MARK: - Broadcasts

    /// Panik hosts its own recordings, so an episode plays through the normal
    /// engine — seekable, with a real duration — rather than through a widget.
    func testEpisodePlaysTheStationsOwnFile() throws {
        let parsed = try XCTUnwrap(PodcastFeedParser.parse(Data(feed.utf8)))
        let episode = try XCTUnwrap(parsed.items[0].asPanikEpisode())
        let item = try XCTUnwrap(episode.mediaItem())

        XCTAssertNil(item.embedProvider, "The station's own file needs no embed")
        XCTAssertEqual(item.sourceID, "panik")
        XCTAssertEqual(item.id, "panik.episode.daydream-nation/mixtape-session-22")
        XCTAssertEqual(try XCTUnwrap(item.duration), 3958, accuracy: 1)
    }

    /// The station-wide feed writes "[Show] Episode" and the per-show feed
    /// writes the episode alone, so the bracket is stripped for display while
    /// the show itself is taken from the link, which is an identifier.
    func testShowIsTakenFromTheLinkAndTheBracketOnlyFromTheTitle() throws {
        let parsed = try XCTUnwrap(PodcastFeedParser.parse(Data(feed.utf8)))
        let episode = try XCTUnwrap(parsed.items[0].asPanikEpisode())

        XCTAssertEqual(episode.title, "Mixtape session #22")
        XCTAssertEqual(episode.showTitle, "Daydream Nation")
        XCTAssertEqual(episode.showSlug, "daydream-nation")
    }

    func testRelativeLinksAreUnderstoodToo() throws {
        let parsed = try XCTUnwrap(PodcastFeedParser.parse(Data(feed.utf8)))
        let episode = try XCTUnwrap(parsed.items[1].asPanikEpisode())
        XCTAssertEqual(episode.id, "acouphene/emission-du-31")
        XCTAssertEqual(episode.showSlug, "acouphene")
    }

    func testTitleSplitLeavesUnbracketedTitlesAlone() {
        XCTAssertEqual(PanikTitle.split("Plain title").title, "Plain title")
        XCTAssertNil(PanikTitle.split("Plain title").show)
        // A title that is nothing but a bracket is a title, not a prefix.
        XCTAssertEqual(PanikTitle.split("[Sound Design]").title, "[Sound Design]")
        XCTAssertNil(PanikTitle.split("[Sound Design]").show)
    }

    /// The crate keeps only this string and has to be able to fetch the
    /// broadcast back from cold months later.
    func testEpisodeIDsRoundTrip() {
        let id = PanikEpisodeID.fromLink("https://www.radiopanik.org/emissions/afrozik/afrozik-48/")
        XCTAssertEqual(id, "afrozik/afrozik-48")
        XCTAssertEqual(PanikEpisodeID.showSlug(of: "afrozik/afrozik-48"), "afrozik")
        XCTAssertEqual(PanikEpisodeID.pagePath("afrozik/afrozik-48"), "/emissions/afrozik/afrozik-48/")

        XCTAssertNil(PanikEpisodeID.fromLink(nil))
        XCTAssertNil(PanikEpisodeID.fromLink("https://www.radiopanik.org/emissions/afrozik/"))
        XCTAssertNil(PanikEpisodeID.fromLink("https://example.test/somewhere/else/"))
    }

    // MARK: - The shows directory

    private let directory = """
    <li class="item  musique">
    <div class="emission emission-resume resume ">
      <a class="block cf" href="/emissions/acouphene/">
        <div class="logo"><img src="/media/cache/05/b3/logo.jpg"/></div>
        <div class="title">
          <strong class="title">Acouph&egrave;ne</strong>
          <div class="smooth metas">
            <span class="categories"><span class="category">Musique en continu</span></span>
          </div>
        </div>
        <div class="description">De 20h30 &agrave; minuit.</div>
      </a>
    </div>
    </li>
    <li class="item  creation">
    <div class="emission emission-resume resume ">
      <a class="block cf" href="/emissions/alerte-niveau-5/">
        <div class="logo"><img src="/media/cache/aa/bb/other.jpg"/></div>
        <div class="title">
          <strong class="title">Alerte Niveau 5</strong>
          <div class="smooth metas">
            <span class="categories"><span class="category">Cr&eacute;ation</span></span>
          </div>
        </div>
        <div class="description">Sons. Mots. Maux.</div>
      </a>
    </div>
    </li>
    """

    func testShowsDirectoryParses() throws {
        let shows = PanikHTML.shows(in: directory)
        XCTAssertEqual(shows.count, 2)

        let first = try XCTUnwrap(shows.first)
        XCTAssertEqual(first.slug, "acouphene")
        XCTAssertEqual(first.title, "Acouphène", "French entities have to survive the parse")
        XCTAssertEqual(first.categories, ["Musique en continu"])
        XCTAssertEqual(first.summary, "De 20h30 à minuit.")
        XCTAssertEqual(
            first.imageURL?.absoluteString,
            "https://www.radiopanik.org/media/cache/05/b3/logo.jpg"
        )
        XCTAssertEqual(shows[1].categories, ["Création"])
    }

    /// A card carries no heading of its own only when the page has changed
    /// shape; adopting the next card's heading would be a wrong answer that
    /// looks like a right one.
    func testACardWithNoHeadingIsDroppedRatherThanBorrowingTheNexts() {
        let broken = directory.replacingOccurrences(
            of: "<strong class=\"title\">Acouph&egrave;ne</strong>", with: ""
        )
        let shows = PanikHTML.shows(in: broken)
        XCTAssertEqual(shows.count, 1)
        XCTAssertEqual(shows.first?.slug, "alerte-niveau-5")
    }

    func testShowPathsAreToldFromEpisodePaths() {
        XCTAssertEqual(PanikHTML.slug(fromShowPath: "/emissions/afrozik/"), "afrozik")
        XCTAssertNil(PanikHTML.slug(fromShowPath: "/emissions/afrozik/afrozik-48/"))
        XCTAssertNil(PanikHTML.slug(fromShowPath: "/actus/"))
        XCTAssertNil(PanikHTML.slug(fromShowPath: "/"))
    }

    // MARK: - The week

    private let programme = """
    <div class="Program-week-2026-08-31-043000 content">
      <ul class="custom program-week list">
        <li class="past" data-program-slug="matin-tranquille">
          <div class="programDate"><strong>05:30</strong></div>
          <div class="programCell">
            <a href="/emissions/la-musique-en-continu/" class="nonstop"><em>Matin tranquille</em></a>
            - <span class="smooth categories category">Musique en continu</span>
            - <a class="playlist" href="/emissions/matin-tranquille/playlist/2026-8-31/">playlist</a>
          </div>
        </li>
        <li class="past" data-program-slug="a-supposedly-fun-thing">
          <div class="programDate"><strong>11:00</strong></div>
          <div class="programCell">
            <div class="episode inline standalone">
              <div class="content"><div class="title"><div class="title">
                <a href="/emissions/a-supposedly-fun-thing/asftinda-18/">ASFTINDA 18</a>
              </div></div></div>
            </div>
          </div>
        </li>
        <li class="future" data-program-slug="reveries">
          <div class="programDate"><strong>02:00</strong></div>
          <div class="programCell">
            <a href="/emissions/reveries/" class="nonstop"><em>R&ecirc;veries</em></a>
          </div>
        </li>
      </ul>
    </div>
    """

    private var brussels: TimeZone {
        TimeZone(identifier: "Europe/Brussels") ?? .current
    }

    func testScheduleParses() throws {
        let entries = PanikHTML.schedule(in: programme, zone: brussels)
        XCTAssertEqual(entries.count, 3)

        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.title, "Matin tranquille")
        XCTAssertEqual(first.showSlug, "matin-tranquille")
        XCTAssertEqual(first.categories, ["Musique en continu"])
        XCTAssertEqual(first.playlistPath, "/emissions/matin-tranquille/playlist/2026-8-31/")
    }

    /// A slot holding a specific episode nests its heading inside anchors. It
    /// reached the screen as raw markup until the heading was stripped.
    func testAnEpisodeSlotYieldsATitleRatherThanItsMarkup() throws {
        let entries = PanikHTML.schedule(in: programme, zone: brussels)
        let episode = try XCTUnwrap(entries.first { $0.showSlug == "a-supposedly-fun-thing" })
        XCTAssertEqual(episode.title, "ASFTINDA 18")
        XCTAssertFalse(episode.title.contains("<"), "No markup reaches the screen")
    }

    /// Panik's broadcast day begins at 04:30, which is why a 02:00 slot is
    /// printed at the bottom of Monday's list and belongs to Tuesday. Read as
    /// Monday it would sort to the top of the day and read as already past.
    func testASlotBeforeDawnBelongsToTheNextDay() throws {
        let entries = PanikHTML.schedule(in: programme, zone: brussels)
        let late = try XCTUnwrap(entries.first { $0.showSlug == "reveries" })

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = brussels
        let day = calendar.component(.day, from: late.startsAt)
        XCTAssertEqual(day, 1, "02:00 after Monday the 31st is Tuesday the 1st")
        XCTAssertEqual(late.title, "Rêveries")
        XCTAssertEqual(entries.last?.showSlug, "reveries", "and it sorts last, not first")
    }

    /// Panik publishes a start per slot and no end, so a slot runs until the
    /// next begins — which is what makes an on-air progress line possible.
    func testEachSlotEndsWhereTheNextBegins() throws {
        let entries = PanikHTML.schedule(in: programme, zone: brussels)
        XCTAssertEqual(entries[0].endsAt, entries[1].startsAt)
        XCTAssertEqual(entries[1].endsAt, entries[2].startsAt)
        XCTAssertNil(entries.last?.endsAt, "Nothing follows the last slot of the week")

        let noon = try XCTUnwrap(entries[1].startsAt.addingTimeInterval(60))
        XCTAssertTrue(entries[1].contains(noon))
        XCTAssertFalse(entries[0].contains(noon))
    }

    // MARK: - Track logs

    private let playlist = """
    <ul class="nonstop-playlist">
      <li id="log-1508828">
        <span class="tracktime">20:30</span> :
        <span class="trackartist">Andreilien</span>
        <span class="tracksep">—</span>
        <span class="tracktitle">Bass Fetish</span>
      </li>
      <li id="log-1508829">
        <span class="tracktime">20:36</span> :
        <span class="trackartist">Eazybaked &amp; Of The Trees</span>
        <span class="tracksep">—</span>
        <span class="tracktitle">Sapped</span>
      </li>
    </ul>
    """

    /// Panik logs the artist and the title in separate fields, which is what
    /// lets a logged track become a real recording rather than a line of text.
    func testTrackLogParses() throws {
        let tracks = PanikHTML.tracks(in: playlist)
        XCTAssertEqual(tracks.count, 2)

        XCTAssertEqual(tracks[0].time, "20:30")
        XCTAssertEqual(tracks[0].artist, "Andreilien")
        XCTAssertEqual(tracks[0].title, "Bass Fetish")
        XCTAssertEqual(tracks[0].display, "Andreilien — Bass Fetish")
        XCTAssertEqual(tracks[1].artist, "Eazybaked & Of The Trees")
    }

    /// The three columns run in lockstep. A page that renders a row short is a
    /// page this no longer understands, and half a tracklist is worse than
    /// none — so it declines rather than pairing the wrong artist to a title.
    func testAMismatchedLogIsRefusedRatherThanMisaligned() {
        let broken = playlist.replacingOccurrences(
            of: "<span class=\"trackartist\">Andreilien</span>", with: ""
        )
        XCTAssertTrue(PanikHTML.tracks(in: broken).isEmpty)
    }

    func testAPageWithNoLogYieldsNothing() {
        XCTAssertTrue(PanikHTML.tracks(in: "<html><body>Rien</body></html>").isEmpty)
    }

    // MARK: - A show's own page

    func testShowDetailAddsToTheListingEntry() throws {
        let page = """
        <meta property="og:title" content="Daydream Nation" />
        <meta property="og:description" content="&laquo; In Rock We Trust &raquo;" />
        <meta property="og:image" content="https://www.radiopanik.org/media/cache/big.jpg" />
        <span class="label">Mardi 22:00</span>
        <span class="category">Musique</span>
        <a href="https://www.mixcloud.com/daydreamnation/">mc</a>
        <a href="http://www.mixcloud.com/daydreamnation/">mc again</a>
        <a href="https://www.instagram.com/daydreamnation">ig</a>
        <a href="https://www.radiopanik.org/emissions/">home</a>
        """
        let listing = PanikHTML.shows(in: directory).first
        let show = try XCTUnwrap(PanikHTML.showDetail(in: page, slug: "daydream-nation", listing: listing))

        XCTAssertEqual(show.title, "Daydream Nation")
        XCTAssertEqual(show.summary, "« In Rock We Trust »")
        XCTAssertEqual(show.slot, "Mardi 22:00")
        XCTAssertEqual(show.categories, ["Musique"])
        // One chip a destination, and the station's own pages are not links
        // off the page.
        XCTAssertEqual(show.links.map(\.label), ["Mixcloud", "Instagram"])
    }

    /// A page that gives nothing back should leave the listing entry standing
    /// rather than replacing it with an emptier one.
    func testShowDetailFallsBackToTheListing() throws {
        let listing = PanikHTML.shows(in: directory).first
        let show = PanikHTML.showDetail(in: "<html></html>", slug: "acouphene", listing: listing)
        XCTAssertEqual(show?.title, "Acouphène")
        XCTAssertEqual(show?.categories, ["Musique en continu"])
    }

    // MARK: - Shared decoding

    /// Most of these stations do not broadcast in English, and a station
    /// serving rendered HTML writes its accents as entities. Without these the
    /// accent survives as entity text all the way onto the screen.
    func testAccentedEntitiesDecode() {
        XCTAssertEqual(HTMLText.decode("Acouph&egrave;ne"), "Acouphène")
        XCTAssertEqual(HTMLText.decode("Cr&eacute;ation"), "Création")
        XCTAssertEqual(HTMLText.decode("R&ecirc;veries"), "Rêveries")
        XCTAssertEqual(HTMLText.decode("&laquo; ici &raquo;"), "« ici »")
        XCTAssertEqual(HTMLText.decode("&ccedil;a &amp; &Eacute;t&eacute;"), "ça & Été")
        // Numeric and unknown entities keep working as they did.
        XCTAssertEqual(HTMLText.decode("caf&#233;"), "café")
        XCTAssertEqual(HTMLText.decode("&notareal;"), "&notareal;")
    }

    // MARK: - What is on the air

    private func onAir(_ json: String) throws -> PanikOnAir {
        try JSONDecoder().decode(PanikOnAirDTO.self, from: Data(json.utf8)).asOnAir()
    }

    /// A programme on the air.
    func testOnAirReadsAProgramme() throws {
        let parsed = try onAir(##"""
        {"data": {"emission": {"title": "Flux détendu", "subtitle": "mélange",
                               "slug": "flux-detendu", "url": "/emissions/flux-detendu/",
                               "chat": null}}}
        """##)
        XCTAssertTrue(parsed.isOnAir)
        XCTAssertFalse(parsed.isNonstop)
        XCTAssertEqual(parsed.title, "Flux détendu")
        XCTAssertEqual(parsed.subtitle, "mélange")
        XCTAssertEqual(parsed.showSlug, "flux-detendu")
        XCTAssertNil(parsed.nowPlaying)
    }

    /// The hours between programmes answer in a different shape entirely —
    /// `nonstop` rather than `emission`, and with the record playing this
    /// minute. Reading only the first shape left the page saying nothing was
    /// on for a large part of the station's week.
    func testOnAirReadsTheContinuousMusicHoursToo() throws {
        let parsed = try onAir(##"""
        {"data": {"nonstop": {"title": "Le Mange Disque", "slug": "le-mange-disque",
                              "url": "/emissions/la-musique-en-continu-sur-panik/",
                              "playlist_url": "/emissions/le-mange-disque/playlist/2026-9-2/"},
                  "track_title": "Deadly Verses", "track_artist": "Gangsta Pat"}}
        """##)
        XCTAssertTrue(parsed.isOnAir)
        XCTAssertTrue(parsed.isNonstop)
        XCTAssertEqual(parsed.title, "Le Mange Disque")
        XCTAssertEqual(parsed.nowPlaying, "Gangsta Pat — Deadly Verses")
        XCTAssertEqual(parsed.playlistPath, "/emissions/le-mange-disque/playlist/2026-9-2/")
    }

    func testOnAirWithNothingPlayingIsIdle() throws {
        XCTAssertFalse(try onAir(##"{"data": {}}"##).isOnAir)
        XCTAssertFalse(try onAir(##"{}"##).isOnAir)
    }

    /// A record with no artist named is still a record.
    func testNowPlayingWithoutAnArtist() throws {
        let parsed = try onAir(##"{"data": {"nonstop": {"title": "X"}, "track_title": "Untitled"}}"##)
        XCTAssertEqual(parsed.nowPlaying, "Untitled")
    }

    /// The station id is what the player and the sidebar key off, and the
    /// crate stores it — so it is not free to drift.
    func testStationIdentityIsStable() {
        XCTAssertEqual(PanikProvider.providerID, "panik")
    }
}
