//
//  RadioArtistProfilesTests.swift
//  IndigoTests
//
//  A radio artist's profile: reached by Discogs id through MusicBrainz's own
//  link, no one's when two MusicBrainz artists claim the entry, and styled
//  only by genres (else tags) the style space knows.
//

import XCTest
@testable import Indigo

final class RadioArtistProfilesTests: XCTestCase {
    private func artist(_ json: String) throws -> MBArtist { try JSONDecoder().decode(MBArtist.self, from: Data(json.utf8)) }

    func testGenresFirstThenTagsOnlyWhatTheStyleSpaceKnows() throws {
        let a = try artist("""
        {"id": "mb1", "name": "A", "genres": [{"name": "Dub", "count": 2}, {"name": "Reggae", "count": 5}, {"name": "rocksteady", "count": 0}],
         "tags": [{"name": "jamaica", "count": 3}],
         "release-groups": [{"id": "g1", "primary-type": "Album", "first-release-date": "1979-05"}, {"id": "g2", "primary-type": "Single", "first-release-date": "1984"}]}
        """)
        let profile = RadioArtistProfile.build(discogsID: 9, artist: a)
        XCTAssertEqual(profile.genres, ["reggae", "dub"], "by votes; unvoted genres are nobody's word")
        XCTAssertEqual(profile.years, 1979...1984)
        XCTAssertEqual(profile.albums, 1)
        let vectors: [String: [String: Double]] = ["dub": ["dub": 1], "jamaica": ["jamaica": 1]]
        XCTAssertEqual(profile.styles(known: vectors).styles, ["dub"])
        XCTAssertEqual(profile.styles(known: vectors).source, .genres)
        var tagged = profile; tagged.genres = []
        XCTAssertEqual(tagged.styles(known: vectors).styles, ["jamaica"])
        XCTAssertEqual(tagged.styles(known: vectors).source, .tags)
    }

    func testTwoMusicBrainzArtistsOnOneEntryAreNoOne() async throws {
        let one = try artist(#"{"id": "mb1", "name": "A"}"#), two = try artist(#"{"id": "mb2", "name": "A"}"#)
        let asked = ClusterSeedPicksTests.Counter()
        let profiles = RadioArtistProfiles(artists: { id in id == 1 ? [one, two] : id == 2 ? [] : [one] },
                                           profile: { _ in await asked.add("profile"); return one })
        let ambiguous = await profiles.profile(discogsID: 1)
        XCTAssertEqual(ambiguous.source, .ambiguous)
        let unlinked = await profiles.profile(discogsID: 2)
        XCTAssertEqual(unlinked.source, .unlinked)
        let none = await asked.counts["profile"]
        XCTAssertNil(none, "no profile is read for an entry that is no one's")
        let found = await profiles.profile(discogsID: 3)
        XCTAssertEqual(found.musicBrainzID, "mb1")
    }
}
