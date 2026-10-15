//
//  TrackDiscoveryTests.swift
//  IndigoTests
//

import XCTest
@testable import Indigo

final class TrackDiscoveryTests: XCTestCase {
    private let seed = TrackDiscovery.Seed(discogsID: 1, name: "Arthur Russell", weight: 1)

    private func neighbour(_ id: Int, _ name: String, episodes: Int = 2) -> TrackDiscovery.Neighbour {
        .init(discogsID: id, name: name, seed: seed, reason: "Played next to Arthur Russell in \(episodes) radio episodes",
              strength: 1 + log2(Double(episodes)))
    }

    private func recording(_ id: Int, _ artist: String, _ title: String, channel: String = "A Channel") -> TrackDiscovery.Appearance {
        .init(artistDiscogsID: id, artist: artist, title: title,
              source: .recording(URL(string: "https://www.youtube.com/watch?v=\(id)\(title.count)")!, channel: channel),
              artworkURL: nil, genres: [])
    }

    func testOneTrackPerArtistNothingAlreadyKnownAndAFewPerChannel() {
        let tracks = TrackDiscovery.rank(
            neighbours: [neighbour(2, "Todd Rundgren", episodes: 4), neighbour(3, "The Durutti Column"), neighbour(4, "Grouper"),
                         neighbour(5, "Known Artist", episodes: 8)],
            appearances: [recording(2, "Todd Rundgren", "Fair Warning"), recording(2, "Todd Rundgren", "Hello It's Me"),
                          recording(3, "The Durutti Column", "Party"), recording(4, "Grouper", "Little Gray Cat"),
                          recording(5, "Known Artist", "Their Track", channel: "Elsewhere")],
            taste: .empty, knownArtists: ["known artist"], knownTracks: ["the durutti column|party"])
        XCTAssertEqual(Set(tracks.map(\.artist)).count, tracks.count, "One track per artist")
        XCTAssertFalse(tracks.contains { $0.title == "Party" }, "Never a track they already know")
        XCTAssertEqual(tracks.filter { if case .recording(_, "A Channel") = $0.source { true } else { false } }.count, 2,
                       "At most two from one channel")
        XCTAssertEqual(tracks.last?.artist, "Known Artist", "A known artist is offered, never first")
    }

    func testAnUploadIsOnlyATrackWhenItSaysSo() {
        XCTAssertTrue(TrackDiscovery.isTrackUpload(title: "Fair warning", artist: "Todd Rundgren"))
        XCTAssertFalse(TrackDiscovery.isTrackUpload(title: "Electric Circus Studio Session Footage", artist: "Common"))
        XCTAssertFalse(TrackDiscovery.isTrackUpload(
            title: "BILLY COBHAM - GINO VANNELLI I - NOVECENTO (produced by Nicolosi / Novecento", artist: "Chaka Khan"))
        XCTAssertTrue(TrackDiscovery.isTrackUpload(title: "SADE - CHERISH THE DAY - REMIX", artist: "Sade"))
    }

    func testATrackAtAKnownMomentRanksAboveOneAtTheTop() throws {
        let url = try XCTUnwrap(URL(string: "https://soundcloud.com/x/y"))
        func episode(_ id: Int, _ at: Int) -> TrackDiscovery.Appearance {
            .init(artistDiscogsID: id, artist: "A\(id)", title: "Track \(id)",
                  source: .episode(RadioListen(provider: "nts", episode: "s/e\(id)", episodeTitle: "E", showTitle: "Show \(id)",
                                               airedAt: nil, played: "Track \(id)", offsetSeconds: at, archiveURL: url), at: at),
                  artworkURL: nil, genres: [])
        }
        let tracks = TrackDiscovery.rank(neighbours: [neighbour(7, "A7"), neighbour(8, "A8")],
                                         appearances: [episode(7, 0), episode(8, 1510)], taste: .empty,
                                         knownArtists: [], knownTracks: [])
        XCTAssertEqual(tracks.map(\.artistDiscogsID), [8, 7])
    }

    func testAnEpisodeTrackStartsWhereItWasPlayed() throws {
        let url = try XCTUnwrap(URL(string: "https://soundcloud.com/x/y"))
        let track = DiscoveredTrack(artist: "Burial", artistDiscogsID: 9, title: "Archangel",
                                    source: .episode(RadioListen(provider: "nts", episode: "endless/ep", episodeTitle: "Endless",
                                                                 showTitle: "Endless", airedAt: nil, played: "Archangel",
                                                                 offsetSeconds: 1570, archiveURL: url), at: 1570),
                                    artworkURL: nil, reason: "r", via: "v", playable: .yes, score: 1)
        let (item, start) = track.mediaItem
        XCTAssertEqual(start, 1570)
        XCTAssertEqual(item.embedProvider, .soundcloud)
        XCTAssertEqual(item.subtitle, "Burial — Archangel")
    }
}
