//
//  N10ASTests.swift
//  IndigoTests
//
//  Payloads trimmed from live responses on api.radiocult.fm, n10asmaster and
//  api.mixcloud.com. Titles are real ones off the station's archive, typos
//  included.
//
//  Almost everything here is about one thing: n10.as publishes no link at all
//  between a show and its recordings, so the only join is the programme name
//  typed at the front of a broadcast's title. If that reading is wrong, a
//  show page is empty and a broadcast belongs to nobody — so the reading is
//  what is tested, against the shapes the station has actually used across
//  ten years.
//

import XCTest
@testable import Indigo

final class N10ASTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// The broadcast day in Montréal, which is what the title names.
    private func day(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "America/Toronto")
        return formatter.string(from: date)
    }

    // MARK: - Reading a broadcast out of its title

    func testTheProgrammeIsWhatPrecedesTheDate() {
        let parsed = N10ASTitle.parse("Exhale 2026/09/17")

        XCTAssertEqual(parsed.programme, "Exhale")
        XCTAssertNil(parsed.guest)
        XCTAssertEqual(day(parsed.date), "2026-09-17")
    }

    func testAGuestIsSeparatedFromTheProgramme() {
        let parsed = N10ASTitle.parse("Maraschino Chalet w/ special guest bethytown 2026/09/17")

        XCTAssertEqual(
            parsed.programme, "Maraschino Chalet",
            "The show is what a show page matches on — the guest is not part of it"
        )
        XCTAssertEqual(parsed.guest, "bethytown", "'special guest' is the wording, not the name")
        XCTAssertEqual(day(parsed.date), "2026-09-17")
    }

    /// The station has written its dates every way round, sometimes in the
    /// same week, so the order is read off the numbers rather than assumed.
    func testDateOrderIsReadFromTheNumbers() {
        XCTAssertEqual(
            day(N10ASTitle.parse("Inflexion Point w/ Margee 19/12/2024").date), "2024-12-19",
            "19 cannot be a month, so this is day-first"
        )
        XCTAssertEqual(
            day(N10ASTitle.parse("Brunch Club 12/17/2020").date), "2020-12-17",
            "17 cannot be a month, so this one is month-first"
        )
        XCTAssertEqual(
            day(N10ASTitle.parse("SOUR FRUIT 18/12/2020").date), "2020-12-18",
            "Filed the same week as Brunch Club, and the other way round"
        )
        XCTAssertEqual(
            day(N10ASTitle.parse("Echo Chamber with Mole 2026/01/02").date), "2026-01-02",
            "A four-digit year leading means year-first"
        )
    }

    /// "12/05/2026" is genuinely ambiguous and no amount of looking at the
    /// title will settle it. Day-first is the station's overwhelming habit —
    /// 3,100 resolvable titles that way against 22 the other — so it is the
    /// reading that is wrong least often.
    func testAnUnresolvableDateIsReadDayFirst() {
        XCTAssertEqual(day(N10ASTitle.parse("Elle Barbara Special 12/05/2026.mp3").date), "2026-05-12")
    }

    func testMalformedDatesAreSurvived() {
        XCTAssertEqual(
            day(N10ASTitle.parse("Dakhmeh hosted by Koohyaar and Cassraa 03/08//2023").date),
            "2023-08-03",
            "A doubled separator is a typo, not a different date"
        )
        XCTAssertEqual(
            day(N10ASTitle.parse("Sleepwalk 02/10/2020/").date), "2020-10-02",
            "A trailing slash likewise"
        )

        // "04/07/20265" — a year with a finger caught on the keyboard. It has
        // to not become a date at all, because a broadcast filed in the year
        // 20265 sorts above everything the station has ever made.
        let typo = N10ASTitle.parse("THE FRIEND HOUR WITH FRIENDS W/ BRAD DJ 04/07/20265")
        XCTAssertNil(typo.date)
        XCTAssertEqual(
            typo.programme, "THE FRIEND HOUR",
            "The programme is still readable even when the date is not"
        )
    }

    func testADateAtTheFrontIsRead() {
        let parsed = N10ASTitle.parse("2026-03-04-Echoes of Time.mp3")

        XCTAssertEqual(parsed.programme, "Echoes of Time")
        XCTAssertEqual(day(parsed.date), "2026-03-04")
    }

    func testATitleWithNoDateStillNamesItsShow() {
        let parsed = N10ASTitle.parse("Amery FM w/ Emma Noonan")

        XCTAssertEqual(parsed.programme, "Amery FM")
        XCTAssertEqual(parsed.guest, "Emma Noonan")
        XCTAssertNil(parsed.date)
    }

    /// A separator at the very front would leave no programme at all, and a
    /// broadcast with no programme belongs to no show.
    func testASeparatorCannotEatTheWholeTitle() {
        let parsed = N10ASTitle.parse("With Love 2026/09/17")

        XCTAssertEqual(parsed.programme, "With Love")
        XCTAssertNil(parsed.guest)
    }

    // MARK: - Matching a broadcast to a show

    /// The directory and the archive disagree about what a show is called:
    /// the directory names several with their host, the recordings never do.
    /// Matching them as published left sixteen shows unable to find a single
    /// broadcast of their own.
    func testAShowNamedWithItsHostStillFindsItsBroadcasts() {
        XCTAssertEqual(
            N10ASTitle.matchKey("Echo Chamber with Mole"),
            N10ASTitle.matchKey("Echo Chamber 12/09/2026")
        )
        XCTAssertEqual(
            N10ASTitle.matchKey("T Time with Tammy J"),
            N10ASTitle.matchKey("T Time w/ Tammy J 20/01/2021")
        )
        XCTAssertEqual(
            N10ASTitle.matchKey("Groovy time with Key Watch"),
            N10ASTitle.matchKey("Groovy Time 05/06/2024"),
            "Case and spacing are the station's, not a difference"
        )
        XCTAssertEqual(
            N10ASTitle.matchKey("AMICALEMENT VÔTRE WITH SAWYER"),
            N10ASTitle.matchKey("Amicalement Vôtre 11/05/2024"),
            "Accents and shouting are not a difference either"
        )
    }

    func testDifferentShowsStillKeyApart() {
        XCTAssertNotEqual(
            N10ASTitle.matchKey("Echo Chamber with Mole"),
            N10ASTitle.matchKey("Echoes of Time")
        )
    }

    /// The calendar marks the station's re-runs in the slot title. That is
    /// bookkeeping about the schedule, not the name of the show, and leaving
    /// it in means a re-run never matches the programme it is a re-run of.
    func testRerunMarksAreNotPartOfTheName() {
        XCTAssertEqual(
            N10ASScheduleEntry(
                id: "1",
                title: "Play Recent (2026-08-28) (Re-Run)",
                summary: nil,
                startsAt: .now,
                endsAt: .now.addingTimeInterval(3600),
                isLive: false
            ).cleanTitle,
            "Play Recent"
        )
        XCTAssertEqual(
            N10ASTitle.matchKey("HiHello the N10.AS Morning Show (2026-09-07) (Re-Run)"),
            N10ASTitle.matchKey("HiHello the N10.AS Morning Show")
        )
    }

    // MARK: - The archive

    private let cloudcast = """
    {"key":"/n10as/2026-09-17-maraschino-chaletmp3",
     "url":"https://www.mixcloud.com/n10as/2026-09-17-maraschino-chaletmp3/",
     "name":"Maraschino Chalet w/ special guest bethytown 2026/09/17",
     "slug":"2026-09-17-maraschino-chaletmp3",
     "created_time":"2026-09-16T03:00:37Z","audio_length":3608,
     "tags":[{"name":"Techno","key":"/genres/techno/"},{"name":"Ambient","key":"/genres/ambient/"}],
     "pictures":{"large":"https://thumbnailer.mixcloud.com/unsafe/300x300/extaudio/a/b/c"},
     "sections":[],
     "description":"A pop-up bar on the edge of town.\\n\\nN10.AS (pronounced \\u201cantennas\\u201d — we broadcast online, no actual antennas, get it?) is a 100% volunteer-run community radio station broadcasting from a tiny studio above Bar Système in Montréal, QC.\\n\\nhttp://www.n10.as"}
    """

    func testABroadcastCarriesItsOwnShowAndNight() throws {
        let episode = try XCTUnwrap(
            decode(MixcloudCloudcastDTO.self, cloudcast).asN10ASEpisode()
        )

        XCTAssertEqual(episode.id, "2026-09-17-maraschino-chaletmp3")
        XCTAssertEqual(episode.programme, "Maraschino Chalet")
        XCTAssertEqual(episode.guest, "bethytown")
        XCTAssertEqual(episode.genres, ["Techno", "Ambient"])
        XCTAssertEqual(episode.duration, 3608)
        XCTAssertEqual(episode.mediaID, "n10as.episode.2026-09-17-maraschino-chaletmp3")
    }

    /// Mixcloud's upload time is not the broadcast date and must not stand in
    /// for it: the station uploads in batches, and across the archive the two
    /// agree within three days only seven times in ten. Here the upload is
    /// the sixteenth and the broadcast the seventeenth.
    func testTheTitlesDateBeatsTheUploadTime() throws {
        let episode = try XCTUnwrap(
            decode(MixcloudCloudcastDTO.self, cloudcast).asN10ASEpisode()
        )

        XCTAssertEqual(day(episode.broadcastAt), "2026-09-17")
    }

    func testABroadcastWithNoReadableDateFallsBackToTheUpload() throws {
        let undated = """
        {"key":"/n10as/armable-w-santinistamp3","url":"https://www.mixcloud.com/n10as/armable-w-santinistamp3/",
         "name":"Armable w Santinista","slug":"armable-w-santinistamp3",
         "created_time":"2025-08-27T14:00:00Z","audio_length":3600,"tags":[],"pictures":{},"sections":[]}
        """
        let episode = try XCTUnwrap(decode(MixcloudCloudcastDTO.self, undated).asN10ASEpisode())

        XCTAssertEqual(episode.programme, "Armable")
        XCTAssertEqual(day(episode.broadcastAt), "2025-08-27")
    }

    // MARK: - Descriptions

    /// Every upload carries the station's standing blurb appended to whatever
    /// the host wrote. Printing it under six thousand broadcasts says nothing
    /// and buries the ones that do have a note.
    func testTheStationsStandingBlurbIsStripped() throws {
        let episode = try XCTUnwrap(
            decode(MixcloudCloudcastDTO.self, cloudcast).asN10ASEpisode()
        )

        XCTAssertEqual(episode.summary, "A pop-up bar on the edge of town.")
    }

    func testADescriptionThatIsOnlyTheBlurbBecomesNoDescription() {
        XCTAssertNil(
            N10ASBlurb.showSpecific(
                "Http://www.n10.as\nhttps://www.patreon.com/n10as\nhttps://www.instagram.com/n10.as/"
            ),
            "A bare list of the station's own links is not something a broadcast said"
        )
        XCTAssertNil(N10ASBlurb.showSpecific(nil))
        XCTAssertNil(N10ASBlurb.showSpecific("   "))
    }

    // MARK: - The show directory

    func testAShowReadsItsSlotGenresAndLinks() throws {
        let json = """
        {"_id":"5bcdeef1541b880004164d9a","name":"100% SULK",
         "image":"https://n10as-images.s3.us-east-2.amazonaws.com/res/a/b/c/1613155321.jpg",
         "slug":"100-sulk","description":"DEEP goodies curated by Deadline Extension\\n",
         "timeslot":"1st Sunday / 8PM EST / Quarterly",
         "tags":[{"label":"house","value":"house"},{"label":"techno","value":"techno"}],
         "links":[{"name":"Soundcloud","link":"https://soundcloud.com/deadlineextension"},
                  {"name":"","link":""}],
         "oldImage":"https://res.cloudinary.com/x/y.jpg"}
        """
        let show = try XCTUnwrap(decode(N10ASShowDTO.self, json).asShow())

        XCTAssertEqual(show.slug, "100-sulk")
        XCTAssertEqual(show.title, "100% SULK")
        XCTAssertEqual(show.timeslot, "1st Sunday / 8PM EST / Quarterly")
        XCTAssertEqual(show.genres, ["house", "techno"])
        XCTAssertEqual(
            show.links.count, 1,
            "The station leaves blank rows in the link repeater rather than removing them"
        )
        XCTAssertEqual(show.links.first?.label, "Soundcloud")
        XCTAssertEqual(show.imageURL?.host, "n10as-images.s3.us-east-2.amazonaws.com")
    }

    func testAShowKeptOnlyOnCloudinaryStillHasAPicture() throws {
        let json = """
        {"name":"Old Show","slug":"old-show","image":"","tags":[],"links":[],
         "oldImage":"https://res.cloudinary.com/dgtrnqqcf/image/upload/v1/x.jpg"}
        """
        let show = try XCTUnwrap(decode(N10ASShowDTO.self, json).asShow())

        XCTAssertEqual(show.imageURL?.host, "res.cloudinary.com")
    }

    // MARK: - What is on the air

    private let liveSlot = """
    {"success":true,"result":{"status":"schedule","content":{
      "timezone":"America/Halifax","stationId":"n10as","title":" eauoeau W/ ONLY NOW",
      "id":"335aafb4-a92f-4232-b8d2-769a05fd2789","duration":60,
      "startDateUtc":"2026-09-17T23:00:00.000Z","endDateUtc":"2026-09-18T00:00:00.000Z",
      "media":{"type":"live"},"color":"#998DD9"},
      "metadata":{"title":"Live","artist":null,"album":null}}}
    """

    func testALiveSlotReadsAsSomebodyInTheRoom() throws {
        let slot = try XCTUnwrap(decode(RadioCultLiveDTO.self, liveSlot).result?.content)
        let entry = try XCTUnwrap(slot.asScheduleEntry())

        XCTAssertEqual(entry.title, "eauoeau W/ ONLY NOW")
        XCTAssertTrue(entry.isLive)
        XCTAssertFalse(entry.isRerun)
        XCTAssertEqual(entry.endsAt.timeIntervalSince(entry.startsAt), 3600)
    }

    /// RadioCult stamps "America/Halifax" on every slot while the station is
    /// in Montréal, an hour behind it. The UTC fields are the ones that are
    /// right, and they are the only ones read.
    func testTheSlotsStatedTimeZoneIsIgnored() throws {
        let slot = try XCTUnwrap(decode(RadioCultLiveDTO.self, liveSlot).result?.content)
        let entry = try XCTUnwrap(slot.asScheduleEntry())

        XCTAssertEqual(entry.startsAt, Date(timeIntervalSince1970: 1_789_686_000))
    }

    /// Most of n10.as's week is the station playing out its own recordings.
    /// That is not nobody being on air, but it is not a live broadcast either.
    func testAPlayoutSlotIsNotMistakenForALiveOne() throws {
        let json = """
        {"success":true,"result":{"status":"schedule","content":{
          "title":"Play Recent (2026-08-28) (Re-Run)","id":"8381b36b",
          "startDateUtc":"2026-09-18T00:00:00.000Z","endDateUtc":"2026-09-18T01:00:00.000Z",
          "media":{"type":"mix","trackId":"3JMcc3E7h62H7lQNalmK1Dihzj1"}}}}
        """
        let slot = try XCTUnwrap(decode(RadioCultLiveDTO.self, json).result?.content)
        let entry = try XCTUnwrap(slot.asScheduleEntry())

        XCTAssertFalse(entry.isLive)
        XCTAssertTrue(entry.isRerun)
        XCTAssertEqual(entry.cleanTitle, "Play Recent")
    }

    func testAnEmptySlotIsNotAShow() throws {
        let json = """
        {"success":true,"result":{"status":"default","content":null,"metadata":null}}
        """
        XCTAssertNil(try decode(RadioCultLiveDTO.self, json).result?.content)
    }

    func testASlotWithNoEndIsDiscarded() throws {
        let json = """
        {"title":"Broken","id":"x","startDateUtc":"2026-09-18T00:00:00.000Z","endDateUtc":null}
        """
        XCTAssertNil(try decode(RadioCultSlotDTO.self, json).asScheduleEntry())
    }

    // MARK: - Identity

    func testAMixcloudKeyReducesToTheSlugThatRefetchesIt() {
        XCTAssertEqual(
            N10ASEpisodeKey.slug(from: "/n10as/2026-09-17-exhalemp3/"), "2026-09-17-exhalemp3"
        )
        XCTAssertNil(N10ASEpisodeKey.slug(from: "/"))
    }
}
