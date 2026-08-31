//
//  SceneTests.swift
//  IndigoTests
//
//  Phase 3E. A scene is a place and a stretch of time, assembled from
//  evidence rather than opinion. The two things worth pinning are the ones
//  most likely to go quietly wrong: telling a place from a genre when a
//  station mixes both into one tag list, and not letting a single reissue
//  stretch an era across thirty years.
//

import XCTest
import SwiftData
@testable import Indigo

final class SceneTests: XCTestCase {
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

    @discardableResult
    private func bandcamp(
        _ title: String, artist: String, keywords: [String], year: String? = "2021",
        label: String? = nil
    ) -> BandcampRelease {
        let record = BandcampRelease(
            urlString: "https://x.bandcamp.com/album/\(RecordingKey.normalize(title))",
            title: title, artistName: artist, labelName: label, year: year,
            trackTitles: ["A"], keywords: keywords
        )
        context.insert(record)
        return record
    }

    // MARK: Places

    /// Bandcamp puts genre and city in one list — "Electronic, ambient, dub,
    /// Manchester" — and getting this wrong turns a city into a genre tag or
    /// files every ambient record under a town called Ambient.
    func testAPlaceIsToldApartFromAGenre() {
        let places = PlaceIndex(known: ["Manchester", "Berlin"])
        let split = places.split(keywords: ["Electronic", "ambient", "dub", "Manchester"])

        XCTAssertEqual(split.places, ["Manchester"])
        XCTAssertEqual(split.tags, ["Electronic", "ambient", "dub"])
    }

    /// The index grows out of the catalogue itself: any city MusicBrainz has
    /// named as an origin is, by definition, a place.
    func testTheCatalogueTeachesItNewPlaces() {
        context.insert(Artist(mbid: "a", name: "Local", origin: "Huddersfield / England"))
        let places = PlaceIndex(context: context)

        XCTAssertTrue(places.isPlace("Huddersfield"), "Learned from the artist's own origin")
        XCTAssertTrue(places.isPlace("Berlin"), "And the seed still applies")
        XCTAssertFalse(places.isPlace("dub techno"))
    }

    /// MusicBrainz writes "Munich / Germany". A scene is a city.
    func testTheCityIsTheFirstHalfOfAnOrigin() {
        XCTAssertEqual(PlaceIndex.city(from: "Munich / Germany"), "Munich")
        XCTAssertEqual(PlaceIndex.city(from: "Berlin"), "Berlin")
        XCTAssertNil(PlaceIndex.city(from: nil))
        XCTAssertNil(PlaceIndex.city(from: ""))
    }

    // MARK: Era

    /// One reissue of a 1994 record must not stretch a scene across thirty
    /// years and say nothing true about any of them.
    func testAStrayReissueDoesNotStretchAnEra() {
        let clustered = [2010, 2011, 2012, 2012, 2013, 2014, 2015, 2016, 2016, 1994, 2024]
        let era = SceneEngine.era(from: clustered)

        XCTAssertEqual(era?.lowerBound, 2010)
        XCTAssertEqual(era?.upperBound, 2016)
    }

    /// Too little to trim is not a licence to invent a window.
    func testASmallSpanIsReportedAsItIs() {
        XCTAssertEqual(SceneEngine.era(from: [2018, 2021]), 2018...2021)
        XCTAssertEqual(SceneEngine.era(from: [2020]), 2020...2020)
        XCTAssertNil(SceneEngine.era(from: []), "Nothing dated is a real answer, not a guess")
        XCTAssertNil(SceneEngine.era(from: [0, 12]), "Nor is nonsense a date")
    }

    // MARK: Scenes

    func testArtistsClusterIntoThePlaceTheirRecordsName() throws {
        bandcamp("Honest Labour", artist: "Space Afrika",
                 keywords: ["Electronic", "ambient", "Manchester"], year: "2021", label: "sferic")
        bandcamp("Blue", artist: "Blackhaine",
                 keywords: ["experimental", "Manchester"], year: "2022", label: "sferic")
        bandcamp("Elsewhere", artist: "Someone Else",
                 keywords: ["techno", "Berlin"], year: "2019")

        let scenes = SceneEngine(context: context).scenes()
        let manchester = try XCTUnwrap(scenes.first { $0.city == "Manchester" })

        XCTAssertEqual(manchester.artists, ["Blackhaine", "Space Afrika"])
        XCTAssertEqual(manchester.labels, ["sferic"])
        XCTAssertTrue(manchester.tags.contains("ambient"))
        XCTAssertFalse(manchester.tags.contains("Manchester"), "The city is not one of its own tags")
        XCTAssertEqual(manchester.era, 2021...2022)
    }

    /// A place with one artist and nothing else is not a scene. Saying so
    /// beats a page of headings with one name under each.
    func testOneArtistAloneIsNotAScene() {
        bandcamp("Elsewhere", artist: "Someone Else", keywords: ["techno", "Berlin"])

        XCTAssertFalse(SceneEngine(context: context).scenes().contains { $0.city == "Berlin" })
        XCTAssertNotNil(SceneEngine(context: context).scene(city: "Berlin"),
                        "It still exists when asked for directly")
    }

    /// People move, and a Berlin record made by somebody from Manchester
    /// belongs to both stories.
    func testAnArtistCanBelongToMoreThanOneScene() throws {
        context.insert(Artist(mbid: "a", name: "Traveller", origin: "Manchester / England"))
        bandcamp("Abroad", artist: "Traveller", keywords: ["techno", "Berlin"])
        bandcamp("Home", artist: "Local", keywords: ["ambient", "Manchester"])
        bandcamp("Also Abroad", artist: "Resident", keywords: ["techno", "Berlin"])

        let cities = SceneEngine(context: context).scenes(forArtist: "Traveller").map(\.city)
        XCTAssertEqual(Set(cities), ["Manchester", "Berlin"])
    }

    func testASceneIsSomewhereYouCanGo() {
        bandcamp("One", artist: "A", keywords: ["ambient", "Manchester"])
        bandcamp("Two", artist: "B", keywords: ["ambient", "Manchester"])

        let scene = SceneEngine(context: context).scene(city: "Manchester")
        XCTAssertEqual(scene?.node.kind, .scene)
        XCTAssertEqual(scene?.title, "MANCHESTER")
    }

    /// A scene has to be somewhere you can dig *out of*, not a page you have
    /// to reverse out of.
    func testASceneCanBeWalkedOutOf() throws {
        bandcamp("One", artist: "Space Afrika", keywords: ["ambient", "Manchester"], label: "sferic")
        bandcamp("Two", artist: "Blackhaine", keywords: ["experimental", "Manchester"], label: "sferic")

        let scene = try XCTUnwrap(SceneEngine(context: context).scene(city: "Manchester"))
        let reached = DigEngine(context: context).connections(from: scene.node)

        XCTAssertEqual(
            Set(reached.filter { $0.to.kind == .artist }.map(\.to.title)),
            ["Space Afrika", "Blackhaine"]
        )
        XCTAssertTrue(reached.contains { $0.to.kind == .label && $0.to.title == "sferic" })
        XCTAssertTrue(
            reached.allSatisfy { $0.reasons.allSatisfy { reason in reason.kind == .sameScene } },
            "Every step out of a scene says it is a scene connection"
        )
        XCTAssertEqual(reached.first?.why?.headline, "Part of Manchester 2021")
    }
}
