//
//  YouTubeChannelTests.swift
//  IndigoTests
//
//  A followed channel's upload, as the backend files it and the player plays
//  it. The backend half — how a title becomes an artist — is pinned by
//  supabase/functions/_shared/youtube_test.ts.
//

import XCTest
@testable import Indigo

final class YouTubeChannelTests: XCTestCase {
    private func track(_ media: String?, title: String = "Space walk",
                       artist: String? = "Siegfried Schwab") -> Catalog.EpisodeTrack {
        Catalog.EpisodeTrack(
            appearanceID: UUID(), trackIndex: 0, rawArtistName: artist, rawTrackTitle: title,
            offsetSeconds: nil, artistID: nil, artistName: nil, recordingID: nil, mediaURL: media
        )
    }

    /// The tracklist function gained a column; a row from before it, or from a
    /// station, has none and must still decode.
    func testATracklistLineDecodesWithAndWithoutAnAddress() throws {
        let withAddress = """
        [{"appearance_id":"\(UUID())","track_index":0,"raw_artist_name":"Janko Nilovic",
          "raw_track_title":"Dans ma tristesse","offset_seconds":null,"artist_id":null,
          "artist_name":null,"recording_id":null,
          "media_url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ"}]
        """
        let without = """
        [{"appearance_id":"\(UUID())","track_index":0,"raw_artist_name":"Moxie",
          "raw_track_title":"Set","offset_seconds":120,"artist_id":null,
          "artist_name":null,"recording_id":null}]
        """
        let decoder = JSONDecoder()
        let one = try decoder.decode([Catalog.EpisodeTrack].self, from: Data(withAddress.utf8))
        XCTAssertEqual(one.first?.mediaURL, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        let two = try decoder.decode([Catalog.EpisodeTrack].self, from: Data(without.utf8))
        XCTAssertNil(two.first?.mediaURL)
    }

    @MainActor
    func testAnUploadPlaysThroughYouTubesPlayer() throws {
        let media = try XCTUnwrap(YouTubeChannelPlayback.media(
            for: track("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), channel: "André Navarro II"))
        XCTAssertEqual(media.embedProvider, .youtube)
        XCTAssertEqual(media.id, "youtube.video.dQw4w9WgXcQ")
        XCTAssertEqual(media.title, "Space walk")
        XCTAssertEqual(media.subtitle, "Siegfried Schwab")
        // Crating from the player bar files `detail` as the release; a
        // channel is not an album.
        XCTAssertNil(media.detail)
        XCTAssertEqual(media.remoteArtworkURL?.absoluteString,
                       "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
    }

    /// Nothing is offered that the player would only fail on.
    @MainActor
    func testALineWithNoVideoIsNotPlayable() {
        XCTAssertNil(YouTubeChannelPlayback.media(for: track(nil), channel: "X"))
        XCTAssertNil(YouTubeChannelPlayback.media(
            for: track("https://www.mixcloud.com/NTSRadio/x/"), channel: "X"))
    }

    func testTheUploadsListIsRecognisedByItsId() {
        func shelf(_ id: String) -> Catalog.RadioEpisode {
            Catalog.RadioEpisode(id: UUID(), radioShowID: nil, provider: "youtube", externalID: id,
                                 title: nil, description: nil, airedAt: nil, durationSeconds: nil,
                                 archiveURL: nil, imageURL: nil, tracklistStatus: "available")
        }
        XCTAssertTrue(YouTubeChannelStore.isUploads(shelf("UUv5OAW45h67CJEY6kJLyisg")))
        XCTAssertFalse(YouTubeChannelStore.isUploads(shelf("PLdYVj1MSs4AAhpGZmCntSzFuefb1ZzKba")))
    }

    /// A search hit plays exactly as the same upload does on its archive's
    /// page, because it becomes the same line.
    @MainActor
    func testASearchHitBecomesAPlayableLine() throws {
        let json = """
        [{"appearance_id":"\(UUID())","media_url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ",
          "raw_artist_name":"Comus","raw_track_title":"Diana","artist_id":null,
          "artist_name":"Comus","archive_id":"\(UUID())","archive_title":"lunarmountains"}]
        """
        let hits = try JSONDecoder().decode([Catalog.ArchiveHit].self, from: Data(json.utf8))
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.archiveTitle, "lunarmountains")
        let media = try XCTUnwrap(YouTubeChannelPlayback.media(for: hit.track, channel: ""))
        XCTAssertEqual(media.title, "Diana")
        XCTAssertEqual(media.subtitle, "Comus")
        XCTAssertEqual(media.embedProvider, .youtube)
    }
}
