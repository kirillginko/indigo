//
//  DigCacheTests.swift
//  IndigoTests
//
//  Why returning to a page felt like arriving at it for the first time.
//

import XCTest
import SwiftData
@testable import Indigo

final class DigCacheTests: XCTestCase {
    /// The old cache held one entry, so opening anything else evicted exactly
    /// what you were about to come back to.
    func testMoreThanOneAnswerIsKept() {
        var cache = DigCache<String>(limit: 3)
        cache.store("artist", key: "a", revision: 1)
        cache.store("release", key: "b", revision: 1)

        XCTAssertEqual(cache.fresh("a", revision: 1), "artist")
        XCTAssertEqual(cache.fresh("b", revision: 1), "release")
    }

    /// `revision` is one counter for the whole store, so writing a release
    /// invalidates the artist page too. Showing the old answer at once and
    /// correcting it a moment later beats a loading bar in front of something
    /// the listener was reading seconds ago.
    func testAStaleAnswerIsStillWorthShowing() {
        var cache = DigCache<String>()
        cache.store("artist", key: "a", revision: 1)

        XCTAssertNil(cache.fresh("a", revision: 2), "Not current")
        XCTAssertEqual(cache.any("a"), "artist", "But still worth drawing")
        XCTAssertNil(cache.any("never seen"))
    }

    /// A long dig must not grow without bound, and what goes is what has been
    /// untouched longest.
    func testTheLeastRecentlyUsedIsWhatGoes() {
        var cache = DigCache<Int>(limit: 2)
        cache.store(1, key: "a", revision: 1)
        cache.store(2, key: "b", revision: 1)
        // Touching "a" makes "b" the oldest.
        cache.store(1, key: "a", revision: 1)
        cache.store(3, key: "c", revision: 1)

        XCTAssertEqual(cache.any("a"), 1)
        XCTAssertEqual(cache.any("c"), 3)
        XCTAssertNil(cache.any("b"))
    }

    /// The case that started this: dig an artist, open one of their records,
    /// come back. The artist page must not be rebuilt from nothing.
    @MainActor
    func testReturningToAnArtistDoesNotStartOver() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)

        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                   discogsID: 1, name: "Skee Mask")
        artist.releaseTitles = ["Compro"]
        artist.styles = ["Techno"]
        context.insert(artist)

        let dig = DigStore(context: context)
        XCTAssertNil(dig.cachedArtistProfile(name: "Skee Mask", mbid: nil),
                     "Nothing to draw before it has ever been opened")

        _ = dig.artistProfile(name: "Skee Mask", mbid: nil)

        // Opening a release writes, which bumps the revision for everything.
        let release = DiscogsReleaseRecord(discogsID: 5, title: "Compro")
        release.artistNames = ["Skee Mask"]
        context.insert(release)
        dig.markUnplayable(URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa")!)

        let onReturn = try XCTUnwrap(dig.cachedArtistProfile(name: "Skee Mask", mbid: nil))
        XCTAssertEqual(onReturn.name, "Skee Mask")
        XCTAssertEqual(onReturn.styles, ["Techno"], "Drawn at once from what it last knew")
    }
}
