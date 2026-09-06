//
//  SceneSignatureTests.swift
//  IndigoTests
//
//  Phase 5. "Move beyond simplistic genre classifications" — and the reason
//  that is not a matter of taste is arithmetic. In a catalogue of this kind
//  the commonest tags are Experimental, Electronic and Ambient, and they are
//  the commonest in *every* place. Naming a scene by its top tag produced New
//  York / Experimental, London / Electronic and Berlin / Experimental: fifty
//  places wearing three names.
//
//  What makes a scene itself is a sound that is ordinary here and unusual
//  everywhere else.
//

import XCTest
import SwiftData
@testable import Indigo

final class SceneSignatureTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    /// An artist from somewhere, with a Bandcamp record carrying keywords.
    private func artist(_ name: String, from city: String, tags: [String]) {
        let record = Artist(mbid: "mbid-\(name)", name: name)
        record.origin = city
        context.insert(record)
        let release = BandcampRelease(
            urlString: "https://\(name.filter { !$0.isWhitespace }).bandcamp.com/album/x",
            title: "\(name) album", artistName: name
        )
        release.keywords = tags
        context.insert(release)
    }

    private func signature(of city: String) -> [String] {
        try? context.save()
        return SceneEngine(context: context).scene(city: city)?.signature ?? []
    }

    // MARK: The whole point

    func testASceneIsNamedByWhatOnlyItHas() {
        // Everywhere is experimental. Only one place is dub techno.
        artist("A", from: "Berlin", tags: ["Experimental", "Electronic", "Dub Techno"])
        artist("B", from: "Berlin", tags: ["Experimental", "Electronic", "Dub Techno"])
        artist("C", from: "London", tags: ["Experimental", "Electronic", "Grime"])
        artist("D", from: "London", tags: ["Experimental", "Electronic", "Grime"])
        artist("E", from: "Detroit", tags: ["Experimental", "Electronic", "Minimal"])
        artist("F", from: "Detroit", tags: ["Experimental", "Electronic", "Minimal"])

        XCTAssertEqual(signature(of: "Berlin").first, "Dub Techno")
        XCTAssertEqual(signature(of: "London").first, "Grime")
        XCTAssertEqual(signature(of: "Detroit").first, "Minimal")
    }

    func testAWordEverywhereNamesNothing() {
        artist("A", from: "Berlin", tags: ["Experimental"])
        artist("B", from: "Berlin", tags: ["Experimental"])
        artist("C", from: "London", tags: ["Experimental"])
        artist("D", from: "London", tags: ["Experimental"])

        // In every place, so it distinguishes none of them. A scene with
        // nothing to say about its sound falls back on when it happened.
        XCTAssertTrue(signature(of: "Berlin").isEmpty)
    }

    // MARK: Words that are not sounds

    func testASceneIsNotNamedAfterSomebodyInIt() {
        // A name appears in exactly one place by definition, which makes it
        // the most distinctive word there is and the least useful. This
        // produced BERLIN / SONAE.
        artist("Sonae", from: "Cologne", tags: ["Electronic"])
        artist("Monika Werkstatt", from: "Berlin", tags: ["Sonae", "sonae", "Ambient"])
        artist("Another", from: "Berlin", tags: ["Sonae", "Ambient"])
        artist("Elsewhere", from: "London", tags: ["Electronic"])

        XCTAssertFalse(signature(of: "Berlin").contains { $0.lowercased() == "sonae" })
    }

    func testASceneIsNotNamedAfterAPlace() {
        artist("A", from: "Berlin", tags: ["Berlin", "Dub Techno"])
        artist("B", from: "Berlin", tags: ["Berlin", "Dub Techno"])
        artist("C", from: "London", tags: ["Electronic"])
        artist("D", from: "London", tags: ["Electronic"])

        let found = signature(of: "Berlin")
        XCTAssertFalse(found.contains { $0.lowercased() == "berlin" })
        XCTAssertEqual(found.first, "Dub Techno")
    }

    // MARK: Counting honestly

    func testOneArtistTaggedTwoWaysIsStillOneArtist() {
        // The bug that let a single name through: a record tagged both "Sonae"
        // and "sonae" folds to one sound twice, and cleared a bar meant to
        // require two different artists.
        artist("A", from: "Berlin", tags: ["Kosmische", "kosmische", "KOSMISCHE"])
        artist("B", from: "Berlin", tags: ["Ambient"])
        artist("C", from: "London", tags: ["Electronic"])
        artist("D", from: "London", tags: ["Electronic"])

        XCTAssertFalse(signature(of: "Berlin").contains { $0.lowercased() == "kosmische" })
    }

    func testAKeywordOnOneMemberOfALargeSceneDoesNotNameIt() {
        for index in 0..<10 {
            artist("Artist \(index)", from: "Berlin", tags: ["Ambient"])
        }
        artist("Odd One", from: "Berlin", tags: ["Sea Shanty", "Ambient"])
        artist("Elsewhere", from: "London", tags: ["Ambient"])
        artist("Elsewhere Two", from: "London", tags: ["Ambient"])

        XCTAssertFalse(signature(of: "Berlin").contains { $0.lowercased() == "sea shanty" })
    }

    // MARK: Where they are heading

    /// Crated, so the scene has a foothold in the listener's own collection.
    private func crate(artist name: String) {
        let item = CrateItem(
            digKind: .artist, providerID: "dig.artist.name",
            entityID: RecordingKey.normalizeArtist(name), title: name,
            subtitle: "Artist", artworkURL: nil
        )
        context.insert(item)
        let discogs = DiscogsArtist(
            nameKey: RecordingKey.normalizeArtist(name), discogsID: abs(name.hashValue % 90000),
            name: name
        )
        discogs.styles = ["Kosmische"]
        context.insert(discogs)
    }

    private func movingToward() -> MusicScene? {
        try? context.save()
        return SceneEngine(context: context)
            .movingToward(taste: TasteProfile.collected(context: context))
    }

    func testTheDirectionIsAPlaceWithAFootInItAndMostOfItLeft() {
        // Eight in Cologne, one of whom is kept: a foot in the door and seven
        // names still in front of them.
        for index in 0..<8 {
            artist("Köln \(index)", from: "Cologne", tags: ["Kosmische", "Ambient"])
        }
        for index in 0..<8 {
            artist("Elsewhere \(index)", from: "London", tags: ["Grime", "Ambient"])
        }
        crate(artist: "Köln 0")

        XCTAssertEqual(movingToward()?.city, "Cologne")
    }

    func testAPlaceTheyHaveNotTouchedIsNotADirection() {
        for index in 0..<8 {
            artist("Köln \(index)", from: "Cologne", tags: ["Kosmische", "Ambient"])
        }
        // A taste for the sound, but not one record from there. That is a
        // stranger, not a direction.
        let discogs = DiscogsArtist(nameKey: "someone", discogsID: 1, name: "Someone")
        discogs.styles = ["Kosmische"]
        context.insert(discogs)
        context.insert(CrateItem(
            digKind: .artist, providerID: "dig.artist.name", entityID: "someone",
            title: "Someone", subtitle: "Artist", artworkURL: nil
        ))

        XCTAssertNil(movingToward())
    }

    /// The answer this rule was written for. On a real collection the
    /// direction offered was "the United States" — nineteen people who share
    /// a passport, which is not a scene and not somewhere anybody is heading.
    func testACountryIsNotADirection() {
        // MusicBrainz writes an origin as "City / Country", so the catalogue
        // says which is which without a list to maintain.
        for index in 0..<9 {
            artist("American \(index)", from: "United States", tags: ["Kosmische", "Ambient"])
        }
        // One artist filed properly, which is what makes the country a country.
        artist("Someone", from: "Chicago / United States", tags: ["House"])
        crate(artist: "American 0")

        let toward = movingToward()
        XCTAssertNotEqual(toward?.city, "United States")
    }

    func testSomebodyWithNoTasteYetIsNotSentAnywhere() {
        for index in 0..<8 {
            artist("Köln \(index)", from: "Cologne", tags: ["Kosmische"])
        }
        // Nothing kept, nothing played. Inventing a direction here would be
        // the app talking rather than reading.
        XCTAssertNil(movingToward())
    }

    func testASceneSaysHowMuchIsWaitingInIt() {
        artist("A", from: "Berlin", tags: ["Dub Techno"])
        artist("B", from: "Berlin", tags: ["Dub Techno"])
        try? context.save()

        let line = SceneEngine(context: context).scene(city: "Berlin")?.sizeLine
        XCTAssertEqual(line?.contains("2 artists"), true)
    }

    // MARK: What it reads as

    func testAScenePresentsItsSoundAndFallsBackToItsYears() {
        artist("A", from: "Berlin", tags: ["Experimental", "Dub Techno"])
        artist("B", from: "Berlin", tags: ["Experimental", "Dub Techno"])
        artist("C", from: "London", tags: ["Experimental"])
        artist("D", from: "London", tags: ["Experimental"])
        try? context.save()

        let engine = SceneEngine(context: context)
        XCTAssertEqual(engine.scene(city: "Berlin")?.soundLabel, "DUB TECHNO")
        // London has nothing of its own to say, so it says when instead.
        let london = engine.scene(city: "London")
        XCTAssertEqual(london?.soundLabel, london?.eraLabel)
    }
}
