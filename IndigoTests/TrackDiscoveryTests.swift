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
        XCTAssertEqual(tracks.last?.knownArtist, true)
    }

    /// Two artists on one compilation: one track from the record.
    func testOneTrackPerRecord() {
        var first = recording(2, "Todd Rundgren", "Fair Warning", channel: "One")
        first.release = "A Wizard"; first.releaseDiscogsID = 100
        var second = recording(3, "Grouper", "Little Gray Cat", channel: "Two")
        second.release = "A Wizard (Remaster)"; second.releaseDiscogsID = 100
        var third = recording(4, "Laraaji", "Being Here", channel: "Three")
        third.release = "Day Of Radiance"
        let tracks = TrackDiscovery.rank(neighbours: [neighbour(2, "Todd Rundgren", episodes: 4), neighbour(3, "Grouper"),
                                                      neighbour(4, "Laraaji")],
                                         appearances: [first, second, third], taste: .empty, knownArtists: [], knownTracks: [])
        XCTAssertEqual(tracks.map(\.artist), ["Todd Rundgren", "Laraaji"])
        XCTAssertEqual(tracks.first?.releaseDiscogsID, 100)
    }

    /// What they are into now steers the list, at most half of it.
    func testRecentStartingPointsTakeAtMostHalf() {
        let now = TrackDiscovery.Seed(discogsID: 1, name: "Now", weight: 1, signal: .recent)
        let kept = TrackDiscovery.Seed(discogsID: 9, name: "Kept", weight: 0.5, signal: .longTerm)
        let neighbours = (2...7).map { TrackDiscovery.Neighbour(discogsID: $0, name: "N\($0)", seed: now, reason: "r", strength: 2) }
            + (10...13).map { TrackDiscovery.Neighbour(discogsID: $0, name: "K\($0)", seed: kept, reason: "r", strength: 1) }
        let appearances = (Array(2...7) + Array(10...13)).map { recording($0, "A\($0)", "T\($0)", channel: "C\($0)") }
        let tracks = TrackDiscovery.rank(neighbours: neighbours, appearances: appearances, taste: .empty,
                                         knownArtists: ["a13"], knownTracks: [], limit: 6, perSeed: 6)
        XCTAssertEqual(tracks.count, 6)
        XCTAssertEqual(tracks.filter { $0.signal == .recent }.count, 3)
        XCTAssertEqual(tracks.filter { $0.signal == .longTerm }.count, 3)
        XCTAssertEqual(tracks.first?.signal, .recent, "Now still leads")
        XCTAssertFalse(tracks.contains { $0.artist == "A13" }, "A known artist is the first left out")
        XCTAssertTrue(tracks.allSatisfy { $0.knownArtist == false })
    }

    /// A list held from before the new fields still reads.
    func testAHeldListFromBeforeStillDecodes() throws {
        var track = TrackDiscovery.rank(neighbours: [neighbour(2, "A")], appearances: [recording(2, "A", "T")],
                                        taste: .empty, knownArtists: [], knownTracks: []).first
        track?.signal = .recent
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(track))) as? [String: Any])
        for key in ["signal", "knownArtist", "releaseDiscogsID"] { object[key] = nil }
        let old = try JSONDecoder().decode(DiscoveredTrack.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.signal)
        XCTAssertNil(old.knownArtist)
        XCTAssertEqual(old.id, track?.id)
    }

    /// A YouTube still is drawn from its sharp 16:9 frame, with the small
    /// 16:9 still to fall back on; anything else as it is.
    func testATrackIsDrawnFromItsSharpFrame() {
        var track = TrackDiscovery.rank(neighbours: [neighbour(2, "A")], appearances: [recording(2, "A", "T")],
                                        taste: .empty, knownArtists: [], knownTracks: []).first
        track?.artworkURL = URL(string: "https://i.ytimg.com/vi/j_JCt0jv86I/hqdefault.jpg")
        XCTAssertEqual(track?.sharpArtwork.full?.absoluteString, "https://i.ytimg.com/vi/j_JCt0jv86I/maxresdefault.jpg")
        XCTAssertEqual(track?.sharpArtwork.preview?.absoluteString, "https://i.ytimg.com/vi/j_JCt0jv86I/mqdefault.jpg")
        let show = URL(string: "https://media2.ntslive.co.uk/resize/1600x1600/x.jpeg")
        track?.artworkURL = show
        XCTAssertEqual(track?.sharpArtwork.full, show)
        XCTAssertNil(track?.sharpArtwork.preview)
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

// MARK: - Release recordings, batching, progress

final class TrackDiscoverySourceTests: XCTestCase {
    private func release(_ json: String) throws -> DiscogsReleaseDetail {
        try JSONDecoder().decode(DiscogsReleaseDetail.self, from: Data(json.utf8))
    }

    func testARecordingIsTheirTrackOnlyWhenTheReleaseAndTheTracklistAgree() throws {
        let own = try release(#"""
        {"id":1,"title":"Untrue","year":2007,"artists":[{"id":9,"name":"Burial"}],
         "tracklist":[{"position":"1","title":"Archangel"},{"position":"2","title":"Near Dark"}],
         "videos":[{"uri":"https://www.youtube.com/watch?v=aaaaaaaaaaa","title":"Burial - Archangel"},
                   {"uri":"https://www.youtube.com/watch?v=bbbbbbbbbbb","title":"Burial - Untrue (Documentary Footage)"},
                   {"uri":"https://www.youtube.com/watch?v=ccccccccccc","title":"Burial live in London"}]}
        """#)
        let found = ReleaseVideoTracks.match(own, artistID: 9, artist: "Burial")
        XCTAssertEqual(found.map(\.title), ["Archangel"], "Footage and a video naming no track are not tracks")
        XCTAssertEqual(found.first?.release, "Untrue")
        XCTAssertEqual(found.first?.year, 2007)

        let compilation = try release(#"""
        {"id":2,"title":"Comp","artists":[{"id":194,"name":"Various"}],
         "tracklist":[{"position":"1","title":"Archangel","artists":[{"id":9,"name":"Burial"}]},
                      {"position":"2","title":"Someone Else's Song","artists":[{"id":7,"name":"Other"}]}],
         "videos":[{"uri":"https://www.youtube.com/watch?v=ddddddddddd","title":"Other - Someone Else's Song"},
                   {"uri":"https://www.youtube.com/watch?v=eeeeeeeeeee","title":"Burial - Archangel"}]}
        """#)
        XCTAssertEqual(ReleaseVideoTracks.match(compilation, artistID: 9, artist: "Burial").map(\.title), ["Archangel"],
                       "On a compilation, only the track credited to them")
    }

    private actor Calls { var count = 0; func add() { count += 1 } }

    private func fake(calls: Calls) -> TrackDiscoverySource {
        let seedRow = UUID(), neighbourRow = UUID()
        return TrackDiscoverySource(
            rows: { ids in await calls.add(); return Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 == 1 ? [seedRow] : [neighbourRow]) }) },
            neighbours: { _ in await calls.add(); await calls.add(); return [.init(a: seedRow, b: neighbourRow, episodes: 3)] },
            relations: { row in await calls.add(); return [.init(a: row, b: neighbourRow, episodes: 3)] },
            artists: { rows in await calls.add(); await calls.add()
                return Dictionary(uniqueKeysWithValues: rows.filter { $0 == neighbourRow }.map { ($0, (discogs: 2, name: "Neighbour")) }) },
            appearances: { _ in
                await calls.add()
                let episode = TrackDiscoverySource.Row.Episode(provider: "nts", external_id: "s/e", archive_url: nil, title: "E",
                                                               aired_at: nil, image_url: nil, genres: nil, radio_shows: nil)
                return [
                    .init(artist_id: neighbourRow, raw_track_title: "Their Track", offset_seconds: nil,
                          media_url: "https://www.youtube.com/watch?v=nnnnnnnnnn1", radio_episodes: episode),
                    .init(artist_id: seedRow, raw_track_title: "Own Track", offset_seconds: nil,
                          media_url: "https://www.youtube.com/watch?v=sssssssss1s", radio_episodes: episode)
                ]
            },
            plays: { _ in true },
            cache: TrackDiscoveryCache())
    }

    func testOneLookIsAFewBatchedReadsAndASecondReusesThem() async {
        let calls = Calls()
        let source = fake(calls: calls)
        let ask = TrackDiscoverySource.Ask(seeds: [.init(discogsID: 1, name: "Seed", weight: 1)])
        let (tracks, report) = await source.discover(ask)
        XCTAssertEqual(tracks.map(\.title), ["Their Track"], "Never the starting point's own track, outside its page")
        XCTAssertEqual(report.requests, 5, "Identity, the live neighbours of one starting point, names and ids, tracks")
        let first = await calls.count
        let (_, again) = await source.discover(ask)
        XCTAssertEqual(again.requests, 1, "Identities and neighbours kept: only the tracks are read again")
        let second = await calls.count
        XCTAssertEqual(second - first, 1)
    }

    func testAnArtistPageLeadsWithTheirOwnTracksAndTracksArriveOneByOne() async {
        let source = fake(calls: Calls())
        final class Seen: @unchecked Sendable { var counts: [Int] = [] }
        let seen = Seen()
        let ask = TrackDiscoverySource.Ask(seeds: [.init(discogsID: 1, name: "Seed", weight: 1)], limit: 5, ownTracks: 3)
        let (tracks, report) = await source.discover(ask) { so in seen.counts.append(so.count) }
        XCTAssertEqual(tracks.map(\.title), ["Own Track", "Their Track"])
        XCTAssertEqual(report.own, 1)
        XCTAssertEqual(seen.counts, [1, 2], "Each track handed over as it passes")
        XCTAssertEqual(tracks.map(\.playLabel), ["Play track", "Play track"])
    }
}
