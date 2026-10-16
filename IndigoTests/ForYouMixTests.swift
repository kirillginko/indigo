//
//  ForYouMixTests.swift
//  IndigoTests
//
//  For You as one list, and its compass: the pattern, one artist once, each
//  source's order kept; axes from the listener's own interests, the same
//  in any order.
//

import XCTest
@testable import Indigo

final class ForYouMixTests: XCTestCase {
    private func track(_ id: Int, _ artist: String, tags: [String] = ["ambient"], via: String = "X") -> DiscoveredTrack {
        DiscoveredTrack(artist: artist, artistDiscogsID: id, title: "T\(id)",
                        source: .recording(URL(string: "https://www.youtube.com/watch?v=\(id)")!, channel: nil),
                        tags: tags, reason: "Played next to \(via)", via: via, playable: .yes, score: 1)
    }

    private func suggestion(_ title: String, kind: MusicNodeKind = .artist) -> ExploreSuggestion {
        let node = kind == .broadcast ? MusicNode.broadcast(providerID: "nts", showID: title.lowercased(), title: title) : .artist(title)
        return ExploreSuggestion(node: node, reason: "Credited together", via: "Y", kind: kind == .broadcast ? .playedInShow : .collaborator,
                                 corroboration: 1, score: 1)
    }

    private func record(_ id: Int, _ artist: String) -> SimilarRecord {
        let profile = RecordProfile(id: id, title: "R\(id)", artists: [artist], artistKeys: [RecordingKey.normalizeArtist(artist)],
                                    styles: ["slowcore"], genres: ["rock"], year: 1998, labels: [])
        return SimilarRecord(record: profile, via: profile, reason: "Slowcore", score: 1)
    }

    func testThePatternOneArtistOnceAndEachSourcesOrder() {
        var offers = ExploreOffers()
        offers.next = [suggestion("Burial"), suggestion("Grouper"), suggestion("Low")]
        offers.shows = [suggestion("Show", kind: .broadcast)]
        let mixed = ForYouMix.mix(offers: offers, tracks: [track(1, "Burial"), track(2, "Biosphere")],
                                  records: [record(10, "Low"), record(11, "Codeine")])
        XCTAssertEqual(mixed.map(\.kind), [.track, .artist, .record, .track, .show, .record])
        XCTAssertEqual(mixed.map(\.title), ["T1", "Grouper", "R10", "T2", "Show", "R11"],
                       "Burial is a track, so not also a page; Low a record, so not also a page")
    }

    /// Only tracks checked to play; reasons say what each was reached through.
    func testOnlyPlayableTracksAndReasonsSayWhereFrom() {
        var unanswered = track(3, "Unchecked")
        unanswered.playable = .unknown
        var offers = ExploreOffers()
        offers.next = [suggestion("Grouper")]
        let mixed = ForYouMix.mix(offers: offers, tracks: [track(1, "Burial"), unanswered], records: [record(10, "Low")])
        XCTAssertFalse(mixed.contains { $0.title == "T3" })
        XCTAssertEqual(mixed.first { $0.title == "Grouper" }?.reason, "Credited together · via Y")
        XCTAssertEqual(mixed.first { $0.title == "R10" }?.reason, "Like R10 · Slowcore")
    }

    func testAKindThatRunsOutIsSkippedNotWaitedFor() {
        let mixed = ForYouMix.mix(offers: ExploreOffers(), tracks: [track(1, "A", via: "P"), track(2, "B", via: "Q"), track(3, "C", via: "R")],
                                  records: [])
        XCTAssertEqual(mixed.map(\.title), ["T1", "T2", "T3"])
    }

    /// At most two things reached from one starting point, whatever their kind.
    func testOneStartingPointDoesNotFillTheList() {
        var offers = ExploreOffers()
        offers.next = [suggestion("Grouper")]   // via "Y"
        let mixed = ForYouMix.mix(offers: offers,
                                  tracks: [track(1, "A", via: "Y"), track(2, "B", via: "Y"), track(3, "C", via: "Z")],
                                  records: [])
        XCTAssertEqual(mixed.map(\.title), ["T1", "Grouper", "T3"])
    }

    /// A record or a label in For You's list is not an artist.
    func testOnlyPeopleInTheArtistQueue() {
        var offers = ExploreOffers()
        offers.next = [ExploreSuggestion(node: .release("Their Own EP", discogsID: 9), reason: "Released Their Own EP", via: "Y",
                                         kind: .appearsOnRelease, corroboration: 1, score: 1), suggestion("Grouper")]
        XCTAssertEqual(ForYouMix.mix(offers: offers, tracks: [], records: []).map(\.title), ["Grouper"])
    }

    private let vectors: [String: [String: Double]] = [
        "ambient": ["ambient": 0.8, "drone": 0.6], "drone": ["drone": 0.8, "ambient": 0.6],
        "techno": ["techno": 0.8, "house": 0.6], "house": ["house": 0.8, "techno": 0.6],
        "free jazz": ["free jazz": 1], "slowcore": ["slowcore": 0.9, "ambient": 0.1],
    ]

    func testTheCompassIsTheListenersOwnAndTheSameInAnyOrder() throws {
        let longTerm = ["ambient": 1.0, "drone": 0.8, "techno": 0.7, "house": 0.5, "free jazz": 0.4]
        let items = [(id: "a", tags: ["ambient"]), (id: "b", tags: ["techno"]), (id: "c", tags: ["slowcore"])]
        let compass = try XCTUnwrap(MusicalCompass.draw(longTerm: longTerm, recent: ["techno": 1], items: items, vectors: vectors))
        let again = try XCTUnwrap(MusicalCompass.draw(longTerm: longTerm, recent: ["techno": 1], items: items.reversed(), vectors: vectors))
        XCTAssertEqual(Set(compass.points.map(\.id)), ["a", "b", "c"])
        for point in compass.points {
            let other = try XCTUnwrap(again.points.first { $0.id == point.id })
            XCTAssertEqual(point.x.bitPattern, other.x.bitPattern)
            XCTAssertEqual(point.y.bitPattern, other.y.bitPattern)
        }
        // Ambient and techno pull apart on the first axis, and "Now" -- all
        // techno -- sits on techno's side of "You".
        let a = try XCTUnwrap(compass.points.first { $0.id == "a" }), b = try XCTUnwrap(compass.points.first { $0.id == "b" })
        let now = try XCTUnwrap(compass.now)
        XCTAssertLessThan(a.x * b.x, 0)
        XCTAssertGreaterThan(now.x * b.x, 0)
        XCTAssertEqual(compass.points.first { $0.id == "c" }?.heading, "Toward Slowcore")
        XCTAssertTrue(compass.points.allSatisfy { abs($0.x) <= 1 && abs($0.y) <= 1 })
    }

    func testTooLittleTasteDrawsNoCompass() {
        XCTAssertNil(MusicalCompass.draw(longTerm: ["ambient": 1], recent: [:], items: [], vectors: vectors))
    }
}
