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

    /// The bug as reported: the same scene, every time the page opened.
    ///
    /// Scoring already ranked every candidate and then threw all but one away,
    /// so a collection that changes slowly named one place for weeks.
    func testMoreThanOneDirectionIsWorkedOutWhenThereIsMoreThanOne() {
        for index in 0..<4 {
            artist("Köln \(index)", from: "Cologne", tags: ["Kosmische", "Ambient"])
        }
        for index in 0..<4 {
            artist("Roma \(index)", from: "Rome", tags: ["Library Music", "Ambient"])
        }
        for index in 0..<4 {
            artist("Londoner \(index)", from: "London", tags: ["Grime", "Ambient"])
        }
        crate(artist: "Köln 0")
        crate(artist: "Roma 0")
        try? context.save()

        let found = SceneEngine(context: context)
            .directions(taste: TasteProfile.collected(context: context))
        XCTAssertGreaterThan(found.count, 1)
        // Two different places, so rotating through them says something new.
        XCTAssertEqual(Set(found.map(\.id)).count, found.count)
    }

    /// The threshold that caused it. Four artists was set when a scene was a
    /// whole city and held nineteen people; splitting them by sound made every
    /// scene smaller, and the threshold went on measuring the old shape.
    func testASceneOfTwoCanBeADirection() {
        artist("A", from: "Cologne", tags: ["Kosmische"])
        artist("B", from: "Cologne", tags: ["Kosmische"])
        artist("C", from: "London", tags: ["Grime"])
        artist("D", from: "London", tags: ["Grime"])
        crate(artist: "A")
        try? context.save()

        let found = SceneEngine(context: context)
            .directions(taste: TasteProfile.collected(context: context))
        XCTAssertTrue(found.contains { $0.city == "Cologne" })
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

    // MARK: Who is in it

    /// The bug as it was reported: a scene called jazz, containing bands that
    /// are not jazz. Only the name knew about sound; membership was still
    /// everybody who happened to live there.
    func testASceneContainsOnlyTheArtistsItIsNamedAfter() {
        artist("Braxton", from: "New York", tags: ["Free Jazz", "Experimental"])
        artist("Cyrille", from: "New York", tags: ["Free Jazz", "Experimental"])
        artist("Lurie", from: "New York", tags: ["Free Jazz", "Experimental"])
        // From the same city, and nothing to do with the scene.
        artist("A Noise Band", from: "New York", tags: ["Noise Rock", "Experimental"])
        artist("Elsewhere", from: "London", tags: ["Experimental"])
        artist("Elsewhere Two", from: "London", tags: ["Experimental"])
        try? context.save()

        let scene = SceneEngine(context: context).scene(city: "New York")
        XCTAssertEqual(scene?.soundLabel, "FREE JAZZ")
        XCTAssertEqual(scene?.artists.count, 3)
        XCTAssertFalse(scene?.artists.contains("A Noise Band") ?? true)
        XCTAssertNil(scene?.artists.first { $0 == "A Noise Band" })
    }

    func testASceneWithNoSoundOfItsOwnStillHoldsEverybody() {
        // Nothing distinguishes this place, so it is a scene in the older
        // sense — a city and a stretch of years — and there is nothing to be
        // a member of.
        artist("A", from: "Berlin", tags: ["Experimental"])
        artist("B", from: "Berlin", tags: ["Experimental"])
        artist("C", from: "London", tags: ["Experimental"])
        artist("D", from: "London", tags: ["Experimental"])
        try? context.save()

        let scene = SceneEngine(context: context).scene(city: "Berlin")
        XCTAssertTrue(scene?.signature.isEmpty ?? false)
        XCTAssertEqual(scene?.artists.count, 2)
    }

    func testACityHoldsMoreThanOneScene() {
        // Manchester read "HARD TECHNO, HIP HOP" — not a scene but two of
        // them wearing one name, with a membership that was the union of
        // people who have nothing to do with each other.
        for name in ["Techno A", "Techno B", "Techno C"] {
            artist(name, from: "Manchester", tags: ["Hard Techno"])
        }
        for name in ["Rap A", "Rap B", "Rap C"] {
            artist(name, from: "Manchester", tags: ["Hip Hop"])
        }
        artist("Elsewhere", from: "London", tags: ["Ambient"])
        artist("Elsewhere Two", from: "London", tags: ["Ambient"])
        try? context.save()

        let found = SceneEngine(context: context).scenes()
            .filter { $0.city == "Manchester" }
        XCTAssertEqual(found.count, 2)
        let techno = found.first { $0.soundLabel == "HARD TECHNO" }
        let hipHop = found.first { $0.soundLabel == "HIP HOP" }
        XCTAssertEqual(techno?.artists.count, 3)
        XCTAssertEqual(hipHop?.artists.count, 3)
        // And neither contains the other's people.
        XCTAssertFalse(techno?.artists.contains("Rap A") ?? true)
        XCTAssertFalse(hipHop?.artists.contains("Techno A") ?? true)
    }

    func testTwoScenesInOnePlaceAreTwoAddresses() {
        for name in ["Techno A", "Techno B"] {
            artist(name, from: "Manchester", tags: ["Hard Techno"])
        }
        for name in ["Rap A", "Rap B"] {
            artist(name, from: "Manchester", tags: ["Hip Hop"])
        }
        artist("Elsewhere", from: "London", tags: ["Ambient"])
        artist("Elsewhere Two", from: "London", tags: ["Ambient"])
        try? context.save()

        let engine = SceneEngine(context: context)
        let techno = engine.scene(city: "Manchester", sound: "Hard Techno")
        let hipHop = engine.scene(city: "Manchester", sound: "Hip Hop")
        XCTAssertNotEqual(techno?.id, hipHop?.id)
        // And each opens onto itself rather than onto its city.
        XCTAssertEqual(techno?.node.destination,
                       .digScene(city: "Manchester", sound: "Hard Techno"))
    }

    func testAnArtistIsOnlyInTheScenesTheyAreActuallyIn() {
        for name in ["Techno A", "Techno B"] {
            artist(name, from: "Manchester", tags: ["Hard Techno"])
        }
        for name in ["Rap A", "Rap B"] {
            artist(name, from: "Manchester", tags: ["Hip Hop"])
        }
        artist("Elsewhere", from: "London", tags: ["Ambient"])
        artist("Elsewhere Two", from: "London", tags: ["Ambient"])
        try? context.save()

        // Living in Manchester does not put somebody in its hip hop scene.
        let found = SceneEngine(context: context).scenes(forArtist: "Techno A")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.soundLabel, "HARD TECHNO")
    }

    func testMembershipIsDecidedByTheSoundsOnTheLabelAndNoOthers() {
        // Three sounds are found; two are shown. Admitting people on the
        // strength of the third means a page that lists somebody it cannot
        // explain.
        // Half the city is kosmische and krautrock; a third of it is something
        // else, which is real enough to be found and not one of the two the
        // page prints.
        for name in ["A", "B", "C"] {
            artist(name, from: "Cologne", tags: ["Kosmische", "Krautrock"])
        }
        for name in ["D", "E"] {
            artist(name, from: "Cologne", tags: ["Neue Deutsche Welle"])
        }
        artist("F", from: "London", tags: ["Ambient"])
        artist("G", from: "London", tags: ["Ambient"])
        try? context.save()

        // The strongest scene in the place is one sound, and holds only the
        // people who make it.
        let scene = SceneEngine(context: context).scene(city: "Cologne")
        XCTAssertEqual(scene?.artists.count, 3)
        for name in ["D", "E"] {
            XCTAssertFalse(scene?.artists.contains(name) ?? true,
                           "\(name) was admitted on a sound this scene is not")
        }
        // They are not lost — they are their own scene.
        let other = SceneEngine(context: context)
            .scene(city: "Cologne", sound: "Neue Deutsche Welle")
        XCTAssertEqual(other?.artists.count, 2)
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
