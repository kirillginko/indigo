//
//  ClusterSeedPicksTests.swift
//  IndigoTests
//
//  The cluster seeds in For You: only verified people, never anyone the
//  listener knows or For You already offers, recordings before moments,
//  and a selection said as one.
//

import XCTest
@testable import Indigo

final class ClusterSeedPicksTests: XCTestCase {
    private let vectors: [String: [String: Double]] = ["ambient": ["ambient": 1], "drone": ["drone": 0.8, "ambient": 0.6]]

    private func inputs() -> ClusterSeedPicks.Inputs {
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let evidence = (0..<4).map { i in
            ListenerProfile.Evidence(unit: "artist:seed\(i)", level: .artist, artist: "seed\(i)", title: "Seed \(i)",
                                     at: at.addingTimeInterval(-86_400), signal: .crated)
        }
        let profile = ListenerProfile.build(evidence: evidence, styles: [:],
                                            artistStyles: Dictionary(uniqueKeysWithValues: (0..<4).map { ("seed\($0)", ["ambient"]) }),
                                            vectors: vectors, asOf: at)
        let seed = ListenerRetrieval.Seed(artist: "seed0", name: "Seed 0", cluster: 0, weight: 1, level: .artist, title: "Seed 0")
        let book = ListenerRetrieval.StyleBook(entries: [(key: "made", id: 1, styles: ["Drone"]), (key: "chosen", id: 2, styles: ["Ambient"]),
                                                         (key: "offered", id: 4, styles: ["Ambient"])],
                                               records: [], vectors: vectors)
        return .init(profile: profile, vectors: vectors, seeds: [seed],
                     entries: ["seed0": .init(key: "seed0", name: "Seed 0", collaborators: ["Nameless"])],
                     releaseIDs: ["seed0": (seed: 100, releases: [10, 11])], book: book, known: ["seed1", "known"])
    }

    private func source() throws -> ClusterSeedPicks {
        let json = """
        {"10": {"id": 10, "title": "Own Album", "artists": [{"id": 100, "name": "Seed 0"}],
                "extraartists": [{"id": 1, "name": "Made", "role": "Bass"}, {"id": 3, "name": "Known", "role": "Drums"},
                                 {"id": 4, "name": "Offered", "role": "Vocals"}]},
         "11": {"id": 11, "title": "A Mix", "artists": [{"id": 100, "name": "Seed 0"}],
                "formats": [{"name": "CD", "descriptions": ["Mixed"]}],
                "tracklist": [{"title": "T", "artists": [{"id": 2, "name": "Chosen"}]}]}}
        """
        let releases = try JSONDecoder().decode([String: DiscogsReleaseDetail].self, from: Data(json.utf8))
        let rowOf: [Int: UUID] = [1: UUID(), 2: UUID(), 4: UUID()]
        let artistOf = Dictionary(uniqueKeysWithValues: rowOf.map { ($0.value, $0.key) })
        let episode = """
        {"provider": "nts", "external_id": "show/ep", "archive_url": "https://www.mixcloud.com/x/y/", "title": "Ep",
         "aired_at": null, "image_url": null, "genres": ["Ambient"], "radio_shows": {"title": "Show"}}
        """
        let decodedEpisode = try JSONDecoder().decode(TrackDiscoverySource.Row.Episode.self, from: Data(episode.utf8))
        return ClusterSeedPicks(
            release: { releases[String($0)] },
            videos: ReleaseVideoTracks(shelf: { _ in nil }, release: { _ in nil }),
            rows: { ids in Dictionary(uniqueKeysWithValues: ids.compactMap { id in rowOf[id].map { (id, [$0]) } }) },
            appearances: { rows in
                rows.map { row in
                    // "Made" has an upload of the track; "Chosen" only the moment in a show.
                    artistOf[row] == 1
                        ? TrackDiscoverySource.Row(artist_id: row, raw_track_title: "Made Track", offset_seconds: 30,
                                                   media_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", radio_episodes: decodedEpisode)
                        : TrackDiscoverySource.Row(artist_id: row, raw_track_title: "Chosen Track", offset_seconds: 30,
                                                   media_url: nil, radio_episodes: decodedEpisode)
                }
            },
            plays: { _ in true })
    }

    func testOnlyVerifiedUnknownPeopleThatPlayRecordingsFirst() async throws {
        let picks = try await source().picks(inputs(), excluding: ["offered"])
        XCTAssertEqual(picks.map(\.artist), ["Made", "Chosen"], "no name-only credit, nobody known, nobody For You offers")
        XCTAssertTrue(picks[0].isRecording)
        XCTAssertFalse(picks[1].isRecording, "a moment in a show, after every recording")
        XCTAssertEqual(picks[0].reason, "On Own Album with Seed 0")
        XCTAssertEqual(picks[1].reason, "Chosen by Seed 0 for A Mix")
        XCTAssertEqual(picks[0].viaDiscogsID, 100)
        XCTAssertEqual(picks.map(\.playable), [.yes, .yes])
    }

    func testOffByDefaultOutsideTheSwitch() {
        ForYouClusterSeedsFeature.override = nil
        UserDefaults.standard.removeObject(forKey: ForYouClusterSeedsFeature.switchKey)
        XCTAssertFalse(ForYouClusterSeedsFeature.isEnabled)
    }
}
