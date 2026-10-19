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
    actor Counter {
        var counts: [String: Int] = [:]
        func add(_ name: String) { counts[name, default: 0] += 1 }
    }

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

    private func source(store: ClusterSeedStore? = nil, asked: Counter = Counter()) throws -> ClusterSeedPicks {
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
            release: { id in await asked.add("release"); return releases[String(id)] },
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
            plays: { _ in await asked.add("plays"); return true },
            store: store, bundles: nil)
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

    /// Kept: the same history and caches give back the same picks without
    /// asking anything; a release's credits and an artist's recording are
    /// not asked for twice.
    func testWhatWasWorkedOutIsKept() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-seed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ClusterSeedStore(file: file)
        let first = Counter(), second = Counter()
        let picks = try await source(store: store, asked: first).picks(inputs(), excluding: [])
        await store.keep(picks: picks, for: "history-1")
        let again = try await source(store: store, asked: second).picks(inputs(), excluding: [])
        XCTAssertEqual(again.map(\.artist), picks.map(\.artist))
        let asked = await second.counts
        XCTAssertNil(asked["release"], "credits kept per release document")
        XCTAssertNil(asked["plays"], "each artist's recording kept")
        let firstAsked = await first.counts
        XCTAssertGreaterThan(firstAsked["release"] ?? 0, 0)

        // From disk, by another store: the picks for the same fingerprint only.
        let reopened = ClusterSeedStore(file: file)
        let kept = await reopened.picks(for: "history-1")
        XCTAssertEqual(kept?.map(\.artist), picks.map(\.artist))
        let other = await reopened.picks(for: "history-2")
        XCTAssertNil(other, "another history: worked out again")
    }

    /// Radio candidates: from the seed's own row, reached by its Discogs id;
    /// only rows with a verified Discogs id, nobody the listener knows, and
    /// an artist with no styles on the device placed by its episodes' genres.
    func testRadioCandidatesAreVerifiedRowsNextToTheSeed() async throws {
        let seedRow = UUID(), neighbour = UUID(), stranger = UUID(), known = UUID(), far = UUID(), episode = UUID()
        let names: [UUID: (name: String, discogs: Int?)] = [neighbour: ("Neighbour", 7), stranger: ("Stranger", nil), known: ("Known", 8), far: ("Far", 9)]
        let asked = Counter()
        var picker = try source()
        picker.radio = ListenerRetrieval.RadioSource(
            rows: { ids in Dictionary(uniqueKeysWithValues: ids.filter { $0 == 100 }.map { ($0, [seedRow]) }) },
            rowsByName: { _ in await asked.add("name"); return [:] },
            appearances: { row, _ in
                row == seedRow ? [(ListenerRetrieval.Radio.Episode(id: episode, show: nil, showTitle: "Show", aired: Date(timeIntervalSinceReferenceDate: 790_000_000),
                                                                   genres: ["Ambient"]), 1)] : []
            },
            tracklists: { _ in [episode: [.init(index: 0, artist: known), .init(index: 1, artist: seedRow),
                                          .init(index: 2, artist: neighbour), .init(index: 3, artist: far), .init(index: 4, artist: stranger)]] },
            showGenres: { _ in [:] }, showsPlaying: { _ in [:] },
            names: { rows in names.filter { rows.contains($0.key) } })
        let inputs = inputs()
        let radio = await picker.radioCandidates(inputs, now: Date(timeIntervalSinceReferenceDate: 800_000_000))
        XCTAssertEqual(radio.sightings.map(\.name), ["Neighbour"], "a row without a Discogs id is nobody yet; a known name is out; a one-off two slots away is too weak")
        XCTAssertEqual(radio.unverified, 1)
        XCTAssertEqual(radio.weak, 1)
        let names0 = await asked.counts["name"]
        XCTAssertNil(names0, "a seed reaches radio by Discogs id only")
        let ranked = ClusterSeedPicks.ranked(inputs, credits: [:], excluding: [], radio: radio)
        let found = try XCTUnwrap(ranked.first { $0.identity == "discogs:7" })
        XCTAssertEqual(found.styleSource, "none", "a programme's genres are context, not the artist's styles")
        XCTAssertTrue(found.styles.isEmpty)
        XCTAssertEqual(found.best.provenance, .radioAdjacent)
        XCTAssertNil(ranked.first { $0.name == "Known" || $0.name == "Stranger" })
        // Off, as everywhere: the mix never asks radio for candidates.
        ForYouRadioCandidatesFeature.override = nil
        UserDefaults.standard.removeObject(forKey: ForYouRadioCandidatesFeature.switchKey)
        XCTAssertFalse(ForYouRadioCandidatesFeature.isEnabled)
        let byName = try await ClusterSeedPicks().radio.rowsByName(["seed 0"])
        XCTAssertTrue(byName.isEmpty, "the live source never resolves a seed by name")
    }

    /// Fill only, the default: the picks without radio stay exactly as they
    /// were, radio is read only when they leave a slot empty, and what it
    /// finds comes after them.
    func testRadioOnlyFillsWhatTheCreditsLeave() async throws {
        defer { ForYouRadioCandidatesFeature.override = nil }
        let asked = Counter()
        let seedRow = UUID(), neighbour = UUID(), episode = UUID()
        var picker = try source()
        let rows = picker.rows, appearances = picker.appearances
        let show = try JSONDecoder().decode(TrackDiscoverySource.Row.Episode.self, from: Data("""
        {"provider": "nts", "external_id": "show/ep2", "archive_url": "https://www.mixcloud.com/x/z/", "title": "Ep",
         "aired_at": null, "image_url": null, "genres": ["Ambient"], "radio_shows": {"title": "Show"}}
        """.utf8))
        // Neighbour (Discogs 7) is reached, and plays, only through radio.
        picker.rows = { ids in var found = try await rows(ids); if ids.contains(7) { found[7] = [neighbour] }; return found }
        picker.appearances = { list in
            try await appearances(list.filter { $0 != neighbour }) + (list.contains(neighbour)
                ? [TrackDiscoverySource.Row(artist_id: neighbour, raw_track_title: "Neighbour Track", offset_seconds: 30,
                                            media_url: nil, radio_episodes: show)] : [])
        }
        picker.radio = ListenerRetrieval.RadioSource(
            rows: { ids in await asked.add("radio"); return Dictionary(uniqueKeysWithValues: ids.filter { $0 == 100 }.map { ($0, [seedRow]) }) },
            rowsByName: { _ in [:] },
            appearances: { row, _ in
                row == seedRow ? [(ListenerRetrieval.Radio.Episode(id: episode, show: nil, showTitle: "Show", aired: Date(timeIntervalSinceReferenceDate: 790_000_000),
                                                                   genres: ["Ambient"]), 1)] : []
            },
            tracklists: { _ in [episode: [.init(index: 1, artist: seedRow), .init(index: 2, artist: neighbour)]] },
            showGenres: { _ in [:] }, showsPlaying: { _ in [:] },
            names: { rows in rows.contains(neighbour) ? [neighbour: ("Neighbour", 7)] : [:] })
        ForYouRadioCandidatesFeature.override = false
        let off = await picker.picks(inputs(), excluding: [], limit: 8)
        ForYouRadioCandidatesFeature.override = true
        let full = await picker.picks(inputs(), excluding: [], limit: 2)
        let radioWhenFull = await asked.counts["radio"]
        XCTAssertNil(radioWhenFull, "nothing left to fill: radio is never read")
        XCTAssertEqual(full.map(\.artist), Array(off.map(\.artist).prefix(2)))
        let filled = await picker.picks(inputs(), excluding: [], limit: 8)
        XCTAssertEqual(Array(filled.prefix(off.count)).map(\.id), off.map(\.id), "the picks without radio, unchanged and first")
        XCTAssertEqual(filled.dropFirst(off.count).map(\.artist), ["Neighbour"])
    }
}
