//
//  RadioProvenanceTests.swift
//  IndigoTests
//
//  The shared radio record: what a station played, when, and where in the
//  broadcast — read back from Indigo's own database rather than from NTS.
//
//  Two things are pinned here. The first is that the Swift types agree with
//  what the database functions in 0004 actually emit; a renamed key does not
//  fail loudly, it makes a page quietly say an artist has never been on radio.
//  The second is that a tracklist line survives being unresolvable, because
//  the music this app exists for is mostly the music nothing has a row for.
//

import XCTest
@testable import Indigo

final class RadioProvenanceTests: XCTestCase {
    /// Postgres hands back `2026-06-12T20:00:00+00:00`. The live client uses a
    /// more forgiving parser than this one; what matters here is the key
    /// names, which are what silently drift.
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - artist_radio_summary

    func testTheSummaryDecodesWhatTheDatabaseFunctionReturns() throws {
        let summary = try decode(Catalog.ArtistRadioSummary.self, """
        {
          "artist_id": "6E2E4F4E-0000-4000-8000-000000000001",
          "appearance_count": 47,
          "episode_count": 41,
          "show_count": 29,
          "host_count": 16,
          "first_appearance_at": "2019-02-03T13:00:00+00:00",
          "latest_appearance_at": "2026-06-12T20:00:00+00:00",
          "top_shows": [
            {
              "show_id": "6E2E4F4E-0000-4000-8000-0000000000A1",
              "provider": "nts",
              "external_id": "ben-ufo",
              "title": "Ben UFO",
              "station": "NTS",
              "host_name": null,
              "appearance_count": 8
            }
          ]
        }
        """)

        XCTAssertEqual(summary.appearanceCount, 47)
        XCTAssertEqual(summary.showCount, 29)
        XCTAssertEqual(summary.episodeCount, 41)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertEqual(summary.topShows.first?.displayName, "Ben UFO")
        XCTAssertEqual(summary.topShows.first?.appearanceCount, 8)
        XCTAssertNotNil(summary.firstAppearanceAt)
    }

    /// An artist Indigo has never heard on air is a real answer, and the page
    /// has to be able to tell it apart from a failed request.
    func testAnArtistWithNoRadioHistoryReadsAsEmptyRatherThanMissing() throws {
        let summary = try decode(Catalog.ArtistRadioSummary.self, """
        {
          "artist_id": "6E2E4F4E-0000-4000-8000-000000000001",
          "appearance_count": 0,
          "episode_count": 0,
          "show_count": 0,
          "host_count": 0,
          "first_appearance_at": null,
          "latest_appearance_at": null,
          "top_shows": []
        }
        """)

        XCTAssertTrue(summary.isEmpty)
        XCTAssertTrue(summary.topShows.isEmpty)
        XCTAssertNil(summary.latestAppearanceAt)
    }

    /// A show is created under its URL slug the first time one of its
    /// broadcasts turns up, and stays that way until somebody fetches the
    /// programme itself. "ben-ufo" is not a name to put on a page.
    func testAShowStillWaitingToBeDescribedIsNotShownAsASlug() throws {
        let summary = try decode(Catalog.ArtistRadioSummary.self, """
        {
          "artist_id": "6E2E4F4E-0000-4000-8000-000000000001",
          "appearance_count": 2, "episode_count": 2, "show_count": 1, "host_count": 0,
          "first_appearance_at": null, "latest_appearance_at": null,
          "top_shows": [{
            "show_id": "6E2E4F4E-0000-4000-8000-0000000000A1",
            "provider": "nts", "external_id": "the-trilogy-tapes",
            "title": "the-trilogy-tapes", "station": "NTS",
            "host_name": null, "appearance_count": 2
          }]
        }
        """)

        XCTAssertEqual(summary.topShows.first?.displayName, "The Trilogy Tapes")
    }

    // MARK: - artist_radio_appearances

    private func appearances(_ json: String) throws -> [Catalog.ArtistRadioAppearance] {
        try decode([Catalog.ArtistRadioAppearance].self, json)
    }

    private let twoBroadcasts = """
    [
      {
        "appearance_id": "6E2E4F4E-0000-4000-8000-000000000101",
        "episode_id": "6E2E4F4E-0000-4000-8000-0000000000E1",
        "episode_title": "Ben UFO 12.06.26",
        "aired_at": "2026-06-12T20:00:00+00:00",
        "archive_url": "https://soundcloud.com/nts/ben-ufo-120626",
        "episode_external_id": "ben-ufo/12th-june-2026",
        "provider": "nts",
        "show_id": "6E2E4F4E-0000-4000-8000-0000000000A1",
        "show_title": "Ben UFO",
        "station": "NTS",
        "host_name": null,
        "track_index": 14,
        "raw_artist_name": "Skee Mask",
        "raw_track_title": "Flyby VFR",
        "offset_seconds": 4472,
        "recording_id": null
      },
      {
        "appearance_id": "6E2E4F4E-0000-4000-8000-000000000102",
        "episode_id": "6E2E4F4E-0000-4000-8000-0000000000E1",
        "episode_title": "Ben UFO 12.06.26",
        "aired_at": "2026-06-12T20:00:00+00:00",
        "archive_url": "https://soundcloud.com/nts/ben-ufo-120626",
        "episode_external_id": "ben-ufo/12th-june-2026",
        "provider": "nts",
        "show_id": "6E2E4F4E-0000-4000-8000-0000000000A1",
        "show_title": "Ben UFO",
        "station": "NTS",
        "host_name": null,
        "track_index": 22,
        "raw_artist_name": "Skee Mask",
        "raw_track_title": "Rev8617",
        "offset_seconds": 6910,
        "recording_id": null
      },
      {
        "appearance_id": "6E2E4F4E-0000-4000-8000-000000000103",
        "episode_id": "6E2E4F4E-0000-4000-8000-0000000000E2",
        "episode_title": "Moxie 03.02.26",
        "aired_at": "2026-02-03T13:00:00+00:00",
        "archive_url": null,
        "episode_external_id": "moxie/3rd-february-2026",
        "provider": "nts",
        "show_id": "6E2E4F4E-0000-4000-8000-0000000000A2",
        "show_title": "Moxie",
        "station": "NTS",
        "host_name": null,
        "track_index": 4,
        "raw_artist_name": "Skee Mask",
        "raw_track_title": "Dial 274",
        "offset_seconds": 2538,
        "recording_id": null
      }
    ]
    """

    func testAppearancesGroupIntoTheBroadcastsTheyHappenedIn() throws {
        let grouped = Catalog.groupedByEpisode(try appearances(twoBroadcasts))

        XCTAssertEqual(grouped.count, 2, "Two tracks in one show is one broadcast, not two")
        XCTAssertEqual(grouped[0].tracks.count, 2)
        XCTAssertEqual(grouped[1].tracks.count, 1)
    }

    /// The database orders by broadcast date, newest first. Grouping must not
    /// quietly reorder into whatever a dictionary felt like.
    func testTheDatabasesOrderSurvivesGrouping() throws {
        let grouped = Catalog.groupedByEpisode(try appearances(twoBroadcasts))

        XCTAssertEqual(grouped.map(\.showTitle), ["Ben UFO", "Moxie"])
        XCTAssertEqual(grouped[0].tracks.map(\.trackIndex), [14, 22],
                       "Tracks stay in the order they were played")
    }

    func testABroadcastNamesItselfByStationAndShow() throws {
        let grouped = Catalog.groupedByEpisode(try appearances(twoBroadcasts))

        XCTAssertEqual(grouped[0].heading, "NTS — Ben UFO")
        XCTAssertEqual(grouped[0].dateLabel, "12 Jun 2026")
    }

    func testATrackReadsAsTheShowAnnouncedItWithItsPlaceInTheBroadcast() throws {
        let grouped = Catalog.groupedByEpisode(try appearances(twoBroadcasts))
        let track = try XCTUnwrap(grouped[0].tracks.first)

        XCTAssertEqual(track.trackLine, "Skee Mask — Flyby VFR")
        XCTAssertEqual(track.offsetLabel, "1:14:32")
    }

    /// The point of the whole model: a station announced something Indigo has
    /// no recording for, and the appearance exists anyway.
    func testAnUnresolvedTrackIsStillAnAppearance() throws {
        let rows = try appearances("""
        [{
          "appearance_id": "6E2E4F4E-0000-4000-8000-000000000201",
          "episode_id": "6E2E4F4E-0000-4000-8000-0000000000E3",
          "episode_title": null,
          "aired_at": null,
          "archive_url": null,
          "episode_external_id": "ben-ufo/12th-june-2026",
          "provider": "nts",
          "show_id": null,
          "show_title": null,
          "station": null,
          "host_name": null,
          "track_index": 7,
          "raw_artist_name": "Unknown",
          "raw_track_title": "White Label",
          "offset_seconds": null,
          "recording_id": null
        }]
        """)

        let grouped = Catalog.groupedByEpisode(rows)
        let track = try XCTUnwrap(grouped.first?.tracks.first)

        XCTAssertNil(track.recordingID)
        XCTAssertEqual(track.trackLine, "Unknown — White Label")
        XCTAssertNil(track.offsetLabel, "NTS reports no offset for most of these")
        XCTAssertEqual(grouped.first?.heading, "NTS",
                       "A broadcast whose show is not described yet still names its provider")
        XCTAssertNil(grouped.first?.dateLabel)
    }

    // MARK: - episode_tracklist

    func testAnEpisodeTracklistCarriesTheArtistItResolvedTo() throws {
        let tracks = try decode([Catalog.EpisodeTrack].self, """
        [
          {
            "appearance_id": "6E2E4F4E-0000-4000-8000-000000000301",
            "track_index": 0,
            "raw_artist_name": "Objekt",
            "raw_track_title": "Ganzfeld",
            "offset_seconds": 180,
            "artist_id": "6E2E4F4E-0000-4000-8000-0000000000B1",
            "artist_name": "Objekt",
            "recording_id": null
          },
          {
            "appearance_id": "6E2E4F4E-0000-4000-8000-000000000302",
            "track_index": 1,
            "raw_artist_name": null,
            "raw_track_title": "Untitled",
            "offset_seconds": null,
            "artist_id": null,
            "artist_name": null,
            "recording_id": null
          }
        ]
        """)

        XCTAssertEqual(tracks.count, 2)
        XCTAssertNotNil(tracks[0].artistID, "A resolved line can be dug into")
        XCTAssertNil(tracks[1].artistID, "An unresolved one is kept as it was announced")
        XCTAssertEqual(tracks[1].rawTrackTitle, "Untitled")
    }
}
