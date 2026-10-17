//
//  ListenerRetrievalTests.swift
//  IndigoTests
//
//  Listener Profile v2 retrieval: seeds from every cluster, radio scored by
//  closeness, focus and repetition with hubs damped, merging by identity
//  and never by a shared name, and a second hop never called a
//  collaboration.
//

import XCTest
@testable import Indigo

final class ListenerRetrievalTests: XCTestCase {
    private let vectors: [String: [String: Double]] = [
        "ambient": ["ambient": 0.8, "drone": 0.6], "drone": ["drone": 0.8, "ambient": 0.6],
        "techno": ["techno": 0.8, "house": 0.6], "house": ["house": 0.8, "techno": 0.6],
    ]
    private let asOf = Date(timeIntervalSince1970: 1_800_000_000)

    private func profile(ambient: Int, techno: Int) -> ListenerProfile {
        var evidence: [ListenerProfile.Evidence] = []
        var styles: [String: [String]] = [:]
        for i in 0..<ambient {
            evidence.append(.init(unit: "artist:amb\(i)", level: .artist, artist: "amb\(i)", title: "Amb \(i)", at: asOf.addingTimeInterval(-86_400 * 30), signal: .crated))
            styles["amb\(i)"] = ["ambient"]
        }
        for i in 0..<techno {
            evidence.append(.init(unit: "artist:tek\(i)", level: .artist, artist: "tek\(i)", title: "Tek \(i)", at: asOf.addingTimeInterval(-86_400 * 30), signal: .fullListen))
            styles["tek\(i)"] = ["techno"]
        }
        return ListenerProfile.build(evidence: evidence, styles: [:], artistStyles: styles, vectors: vectors, asOf: asOf)
    }

    /// The small taste still seeds; the large one cannot take every slot.
    func testSeedsComeFromEveryClusterWithAFloor() {
        let seeds = ListenerRetrieval.seeds(profile(ambient: 30, techno: 3), vectors: vectors, limit: 12, floor: 3)
        let byCluster = Dictionary(grouping: seeds, by: \.cluster).mapValues(\.count)
        XCTAssertEqual(byCluster.count, 2)
        XCTAssertEqual(byCluster.values.min(), 3)
        XCTAssertEqual(Set(seeds.map(\.artist)).count, seeds.count)
    }

    private func radio(_ tracklist: [(Int, UUID)], show: UUID, genres: [String] = ["ambient"], showGenres: [String: Int]) -> ListenerRetrieval.Radio {
        let episode = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!
        var r = ListenerRetrieval.Radio()
        r.episodes[episode] = .init(id: episode, show: show, showTitle: "Show", aired: asOf, genres: genres)
        r.tracklists[episode] = tracklist.map { .init(index: $0.0, artist: $0.1) }
        r.showGenres[show] = showGenres
        for (index, artist) in tracklist { r.appearances[artist, default: []].append((episode: episode, index: index)) }
        return r
    }

    private let seed = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let next = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let far = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let show = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    func testCloserTracksAndFocusedProgrammesCountForMore() {
        let centroid = ListenerProfile.vector(["ambient"], vectors)
        let focused = radio([(1, seed), (2, next), (6, far)], show: show, showGenres: ["ambient": 10, "drone": 5])
        let scores = ListenerRetrieval.hop(from: [(row: seed, weight: 1, seed: "s", cluster: 0)], radio: focused,
                                           centroids: [0: centroid], vectors: vectors, exclude: [])
        XCTAssertGreaterThan(scores[next]!.score, scores[far]!.score)
        let eclectic = radio([(1, seed), (2, next)], show: show,
                             showGenres: Dictionary(uniqueKeysWithValues: (0..<20).map { ("g\($0)", 1) }))
        let broad = ListenerRetrieval.hop(from: [(row: seed, weight: 1, seed: "s", cluster: 0)], radio: eclectic,
                                          centroids: [0: centroid], vectors: vectors, exclude: [])
        XCTAssertGreaterThan(scores[next]!.score, broad[next]!.score, "a programme that plays everything says less")
    }

    func testHubsAreDampedAndTheOrderOfSourcesDoesNotMatter() {
        var r = radio([(1, seed), (2, next), (3, far)], show: show, showGenres: ["ambient": 3])
        r.showsPlaying[far] = 200
        r.showsPlaying[next] = 2
        let sources = [(row: seed, weight: 1.0, seed: "s", cluster: 0), (row: next, weight: 0.5, seed: "t", cluster: 0)]
        let a = ListenerRetrieval.hop(from: sources, radio: r, centroids: [:], vectors: vectors, exclude: [])
        let b = ListenerRetrieval.hop(from: sources.reversed(), radio: r, centroids: [:], vectors: vectors, exclude: [])
        XCTAssertEqual(a, b)
        XCTAssertEqual(ListenerRetrieval.hubDamping(200), sqrt(8.0 / 200), accuracy: 1e-12)
        XCTAssertEqual(ListenerRetrieval.hubDamping(3), 1)
    }

    /// One Discogs id is one artist whatever the spelling; one name with two
    /// ids is two artists.
    func testMergeIsByIdentityNotByName() {
        let route = ListenerRetrieval.Route(provenance: .radioAdjacent, score: 1, seed: "s", cluster: 0, why: "Played next to S")
        let merged = ListenerRetrieval.merge([
            .init(name: "Cardinal", discogsID: 1, catalogueRow: nil, route: route),
            .init(name: "Cardinal (2)", discogsID: 1, catalogueRow: nil, route: route),
            .init(name: "Cardinal", discogsID: 2, catalogueRow: nil, route: route),
            .init(name: "Cardinal", discogsID: nil, catalogueRow: nil, route: route),
            .init(name: "Solo", discogsID: nil, catalogueRow: nil, route: route),
            .init(name: "Solo", discogsID: 9, catalogueRow: nil, route: route),
        ])
        XCTAssertEqual(merged.candidates.map(\.identity), ["discogs:1", "discogs:2", "discogs:9", "name:cardinal"])
        XCTAssertEqual(merged.nameCollisions, 1, "a bare 'Cardinal' could be either: left apart")
        XCTAssertEqual(merged.candidates.first { $0.identity == "discogs:9" }?.routes.count, 2, "a bare name joins the one identity that has it")
    }

    func testASecondHopIsNeverCalledACollaboration() {
        var r = ListenerRetrieval.Radio()
        r.names = [next: ("Bridge", nil), far: ("Far", 7)]
        let second = ListenerRetrieval.RadioScore(score: 1, episodes: 1, shows: 1, via: next, episode: show, showTitle: "Show", distance: 1,
                                                  cluster: 0, seed: "s", genres: [:])
        let sightings = ListenerRetrieval.sightings(first: [:], second: [far: second], radio: r, seedNames: ["s": "Seed"])
        XCTAssertEqual(sightings.first?.route.provenance, .radioSecondHop)
        XCTAssertEqual(sightings.first?.route.why, "Played near Bridge on Show; Bridge is played near Seed")
        XCTAssertFalse(sightings.first?.route.why.lowercased().contains("collab") ?? true)
        XCTAssertFalse(sightings.first?.route.why.lowercased().contains("credit") ?? true)
    }

    /// One tracklist, one find: an episode offers its three strongest, and
    /// more of the same tracklist never adds up.
    func testAnEpisodeOffersAFewAndCountsOnce() {
        let others = (2...8).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 100 + $0))! }
        let r = radio([(1, seed)] + others.enumerated().map { ($0.offset + 2, $0.element) }, show: show, showGenres: ["ambient": 3])
        let scores = ListenerRetrieval.hop(from: [(row: seed, weight: 1, seed: "s", cluster: 0)], radio: r, centroids: [:],
                                           vectors: vectors, exclude: [], perEpisode: 3)
        XCTAssertEqual(Set(scores.keys), Set(others.prefix(3)), "the three nearest the seed")
        XCTAssertTrue(scores.values.allSatisfy { $0.episodes == 1 })
    }

    func testTheDatedDirectRouteNeverOffersTheSeedsOwnNames() {
        let seed = ListenerRetrieval.Seed(artist: "seed", name: "Seed", cluster: 0, weight: 1, level: .artist, title: "Seed")
        let entry = ListenerRetrieval.Entry(key: "seed", name: "Seed", collaborators: ["Friend (2)", "Other Name"], members: ["Member"],
                                            labelNeighbours: ["Labelmate"], aliases: ["Other Name"])
        let found = ListenerRetrieval.direct([seed], entries: ["seed": entry], records: [])
        XCTAssertEqual(found.map(\.name), ["Friend", "Member", "Labelmate"])
        XCTAssertEqual(found.map(\.route.provenance), [.direct, .direct, .sharedContext])
    }

    /// A candidate with no style is ranked by how it was reached, not
    /// buried: strong evidence and no style beats weak evidence and a fit.
    func testTheUnstyledAreRankedByEvidenceNotBuried() {
        let profile = profile(ambient: 6, techno: 3)
        func candidate(_ id: String, score: Double, styles: [String]) -> ListenerRetrieval.Candidate {
            var c = ListenerRetrieval.Candidate(identity: id, nameKey: id, name: id,
                                                routes: [.init(provenance: .direct, score: score, seed: "amb0", cluster: 0, why: "Credited with Amb 0")],
                                                aliases: [id])
            c.styles = styles
            return c
        }
        let pool = [candidate("weak-fit", score: 0.1, styles: ["drone"]), candidate("strong-unknown", score: 1, styles: []),
                    candidate("mid-fit", score: 0.5, styles: ["ambient"])]
        let ranked = ListenerRetrieval.rank(pool, profile: profile, vectors: vectors)
        XCTAssertEqual(ranked.first?.identity, "strong-unknown")
        XCTAssertEqual(ranked.last?.identity, "weak-fit")
        XCTAssertEqual(ListenerRetrieval.cluster(of: pool[1], profile: profile, vectors: vectors), 0, "placed by its seed's cluster")
    }

    /// A candidate with a Discogs id is styled by that id alone: another
    /// artist the device files under the same name lends it nothing.
    func testStylesComeOnlyThroughIdentity() {
        let book = ListenerRetrieval.StyleBook(entries: [(key: "gas", id: 1, styles: ["Alternative Rock"]),
                                                         (key: "credited", id: 3, styles: ["Ambient"])],
                                               records: [], vectors: vectors.merging(["alternative rock": ["alternative rock": 1]]) { a, _ in a })
        let route = ListenerRetrieval.Route(provenance: .radioAdjacent, score: 1, seed: "s", cluster: 0, why: "")
        var radio = ListenerRetrieval.Candidate(identity: "discogs:2", nameKey: "gas", name: "Gas", routes: [route], aliases: ["gas"])
        ListenerRetrieval.style(&radio, book: book)
        XCTAssertTrue(radio.styles.isEmpty, "the device's Gas is someone else")
        var credit = ListenerRetrieval.Candidate(identity: "name:credited", nameKey: "credited", name: "Credited", routes: [route], aliases: ["credited"])
        ListenerRetrieval.style(&credit, book: book)
        XCTAssertEqual(credit.styles, ["ambient"], "a credit by name: the device's entry for that name")
        var row = ListenerRetrieval.Candidate(identity: "catalogue:x", nameKey: "credited", name: "Credited", routes: [route], aliases: ["credited"])
        ListenerRetrieval.style(&row, book: book)
        XCTAssertTrue(row.styles.isEmpty, "a catalogue row without an id could be anyone")
    }

    func testAStepUpInPopularityIsDamped() {
        XCTAssertEqual(ListenerRetrieval.popularityStep(from: 10, to: 5), 1)
        XCTAssertEqual(ListenerRetrieval.popularityStep(from: nil, to: 500), 1)
        XCTAssertEqual(ListenerRetrieval.popularityStep(from: 3, to: 315), sqrt(8.0 / 320), accuracy: 1e-12)
    }
}
