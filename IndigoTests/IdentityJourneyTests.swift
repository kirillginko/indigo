//
//  IdentityJourneyTests.swift
//  IndigoTests
//
//  A discovery journey through the identity-keyed shadow graph: radio show →
//  artist → label → another artist → release → credited producer → alias.
//  Each verified artist is one node however they were reached; aliases and
//  namesakes stay apart; names nothing identifies stay in the graph.
//
//  Twice: on a graph populated the way a long-used Mac's is, and on a cold
//  device that has heard one NTS show and opened two pages.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
private func container() throws -> (ModelContainer, ModelContext) {
    let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
    return (container, ModelContext(container))
}

@MainActor
private func radio(_ context: ModelContext, _ lines: [(artist: String, title: String)]) throws -> MusicNode {
    let store = RecordingStore(context: context)
    for (index, line) in lines.enumerated() {
        let recording = try store.upsert(title: line.title, artistName: line.artist)
        store.note(appearance: MediaAppearance(
            providerID: "nts", stationName: "NTS 1", showTitle: "Guests", showID: "guests",
            heardAt: Date(timeIntervalSince1970: 1_788_000_000 + Double(index)),
            offsetSeconds: Double(index * 300), isLive: false, method: .providerTracklist
        ), on: recording)
    }
    try context.save()
    return .broadcast(providerID: "nts", showID: "guests", title: "Guests")
}

private let forsyth = #"""
{"id":6947405,"title":"Forsyth Gardens","year":2015,
 "artists":[{"id":3722,"name":"Prefuse 73"}],
 "labels":[{"id":6000,"name":"Temporary Residence Limited","catno":"TRR 210"}],
 "extraartists":[{"id":229415,"name":"Scott Herren","anv":"Guillermo S. Herren","role":"Written-By, Producer"}]}
"""#

private let wilderness = #"""
{"id":5002,"title":"The Wilderness","year":2016,
 "artists":[{"id":5001,"name":"Explosions In The Sky"}],
 "labels":[{"id":6000,"name":"Temporary Residence Limited","catno":"TRR 260"}],
 "extraartists":[{"id":229415,"name":"Scott Herren","anv":"S. Herren","role":"Producer"}]}
"""#

private func edge(_ edges: [MusicEdge], to title: String) -> MusicEdge? {
    edges.first { $0.to.title == title }
}

@MainActor
final class IdentityJourneyTests: XCTestCase {
    // MARK: A populated graph

    private func populated() throws -> (ModelContainer, ModelContext, MusicNode) {
        let (container, context) = try container()
        let identity = ArtistIdentityStore(context: context)
        identity.record(DiscogsSpellingCheck(spelling: "Prefuse73", verdict: .variation(3722), resultCount: 15,
                                             results: [], facts: [try ArtistIdentityFixtures.facts(3722)]))
        for id in [229415, 227795] { identity.record(try ArtistIdentityFixtures.facts(id)) }

        let enricher = DiscogsEnricher(context: context, client: DiscogsClient())
        for (json, id) in [(forsyth, 6947405), (wilderness, 5002)] {
            enricher.store(try JSONDecoder().decode(DiscogsReleaseDetail.self, from: Data(json.utf8)), id: id)
        }
        for (json, id) in [(#"{"id":1,"title":"One Nation","artists":[{"id":1874027,"name":"Hype Williams (2)"}]}"#, 1),
                           (#"{"id":2,"title":"Belly","artists":[{"id":82,"name":"Hype Williams"}]}"#, 2)] {
            enricher.store(try JSONDecoder().decode(DiscogsReleaseDetail.self, from: Data(json.utf8)), id: id)
        }
        func filed(_ name: String, _ id: Int, releases: [(Int, String)], aliases: [String] = []) {
            let record = DiscogsArtist(nameKey: RecordingKey.normalizeArtist(name), discogsID: id, name: name)
            record.labelNames = ["Temporary Residence Limited"]
            record.aliasNames = aliases
            record.releaseTitles = releases.map(\.1); record.releaseDiscogsIDs = releases.map(\.0)
            record.releaseYears = releases.map { _ in "2015" }
            record.releaseImageURLStrings = releases.map { _ in "" }; record.releaseLabels = releases.map { _ in "" }
            context.insert(record)
        }
        filed("Prefuse 73", 3722, releases: [(6947405, "Forsyth Gardens")], aliases: ["Scott Herren", "Piano Overlord"])
        filed("Explosions In The Sky", 5001, releases: [(5002, "The Wilderness")])
        filed("Scott Herren", 229415, releases: [], aliases: ["Prefuse 73", "Piano Overlord"])
        try context.save()

        let show = try radio(context, [("Prefuse73", "Intro"), ("Unfiled Selector", "Tape Loop"), ("Hype Williams", "Untitled")])
        return (container, context, show)
    }

    func testTheJourneyKeepsEachArtistOneNode() throws {
        let (container, context, show) = try populated()
        _ = container
        let shadow = ShadowGraph(context: context)

        // Radio show → artist.
        let fromShow = shadow.neighbors(of: show)
        let prefuse = try XCTUnwrap(edge(fromShow, to: "Prefuse 73") ?? edge(fromShow, to: "Prefuse73")).to
        XCTAssertEqual(prefuse.id, "artist:discogs:3722", "\"Prefuse73\" on the tracklist is Prefuse 73")
        XCTAssertEqual(edge(fromShow, to: "Unfiled Selector")?.to.id, "artist:unfiled selector",
                       "Nothing identifies them, and they are still here")
        XCTAssertEqual(edge(fromShow, to: "Hype Williams")?.to.id, "artist:hype williams",
                       "A bare name two artists share stays a name")

        // Artist → label.
        let fromPrefuse = shadow.neighbors(of: prefuse)
        let label = try XCTUnwrap(fromPrefuse.first { $0.to.id == "label:temporary residence limited" }).to

        // Label → another artist, and the same artist reached back.
        let fromLabel = shadow.neighbors(of: label)
        let explosions = try XCTUnwrap(edge(fromLabel, to: "Explosions In The Sky")).to
        XCTAssertEqual(explosions.id, "artist:discogs:5001")
        XCTAssertEqual(edge(fromLabel, to: "Prefuse 73")?.to.id, prefuse.id, "The roster reaches the same Prefuse 73")

        // Another artist → release.
        let fromExplosions = shadow.neighbors(of: explosions)
        let release = try XCTUnwrap(fromExplosions.first { $0.to.kind == .release && $0.to.title == "The Wilderness" }).to
        XCTAssertEqual(release.discogsID, 5002)

        // Release → credited producer: "S. Herren" on The Wilderness.
        let producerEdge = try XCTUnwrap(fromExplosions.first { $0.kind == .producer && $0.reason.contains("The Wilderness") })
        let producer = producerEdge.to
        XCTAssertEqual(producer.id, "artist:discogs:229415")
        XCTAssertEqual(producer.title, "Scott Herren")
        // The same producer credited as "Guillermo S. Herren" on Forsyth Gardens,
        // and listed as Prefuse 73's alias.
        XCTAssertEqual(fromPrefuse.first { $0.kind == .producer }?.to.id, producer.id)
        XCTAssertEqual(fromPrefuse.first { $0.kind == .sameAlias && $0.to.title == "Scott Herren" }?.to.id, producer.id)

        // Producer → related alias: back to Prefuse 73, and Piano Overlord apart.
        let fromProducer = shadow.neighbors(of: producer)
        XCTAssertEqual(fromProducer.first { $0.kind == .sameAlias && $0.to.title == "Prefuse 73" }?.to.id, prefuse.id)
        XCTAssertEqual(fromProducer.first { $0.kind == .sameAlias && $0.to.title == "Piano Overlord" }?.to.id,
                       "artist:discogs:227795", "An alias is its own identity")

        // The credited spellings are kept as the references that placed him.
        let spellings = Set(shadow.canonicalizer.placements.filter { $0.key == .discogs(229415) }.map(\.reference.title))
        XCTAssertTrue(spellings.isSuperset(of: ["S. Herren", "Guillermo S. Herren", "Scott Herren"]))
    }

    func testNamesakesStaySeparateOnTheJourney() throws {
        let (container, context, _) = try populated()
        _ = container
        let shadow = ShadowGraph(context: context)

        let duo = try XCTUnwrap(shadow.neighbors(of: .release("One Nation", discogsID: 1)).first { $0.to.kind == .artist }).to
        let director = try XCTUnwrap(shadow.neighbors(of: .release("Belly", discogsID: 2)).first { $0.to.kind == .artist }).to

        XCTAssertEqual(duo.id, "artist:discogs:1874027")
        XCTAssertEqual(director.id, "artist:discogs:82")
        XCTAssertEqual(shadow.node(.artist("Hype Williams")).id, "artist:hype williams")
    }

    func testTheJourneyIsTheSameInAnyOrderAndTwice() throws {
        let (container, context, show) = try populated()
        _ = container
        func walk(_ shadow: ShadowGraph, _ start: MusicNode) -> [String] {
            var seen: [String] = []
            var frontier = [start]
            for _ in 0..<3 {
                let next = frontier.flatMap { shadow.neighbors(of: $0) }.map(\.to)
                seen += next.map(\.id)
                frontier = Array(Set(next)).sorted { $0.id < $1.id }.prefix(12).map { $0 }
            }
            return seen.sorted()
        }
        let first = walk(ShadowGraph(context: context), show)
        let again = ShadowGraph(context: context)
        _ = again.neighbors(of: .artist("Scott Herren"))   // a different first question
        XCTAssertEqual(walk(again, show), first)
        XCTAssertEqual(walk(again, show), first, "And asked twice")
    }

    func testHistoryIsReadNotRewritten() throws {
        let (container, context, _) = try populated()
        _ = container
        let shadow = ShadowGraph(context: context)
        let personal = PersonalInputs(
            crate: [], plays: [],
            met: [PersonalInputs.Met(node: .artist("Prefuse73"), weight: 1, lastAt: Date(timeIntervalSince1970: 0)),
                  PersonalInputs.Met(node: .artist("Hype Williams"), weight: 1, lastAt: Date(timeIntervalSince1970: 0))],
            artistPlays: [:], haunts: [])

        let read = shadow.canonicalizer.canonical(personal)

        XCTAssertEqual(read.met.map(\.node.id), ["artist:discogs:3722", "artist:hype williams"])
        XCTAssertEqual(personal.met.map(\.node.id), ["artist:prefuse73", "artist:hype williams"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DigVisit>()), 0, "No history written")
    }

    // MARK: A cold device

    /// One NTS show heard, Prefuse73's page opened, Forsyth Gardens opened —
    /// everything else empty. Identity comes from what those two pages asked.
    func testAColdDeviceReachesTheSameIdentities() async throws {
        let (container, context) = try container()
        _ = container
        let show = try radio(context, [("Prefuse73", "Intro"), ("Unfiled Selector", "Tape Loop")])
        let shelf = #"{"pagination":{"items":1},"releases":[{"id":6947405,"title":"Forsyth Gardens","year":2015,"role":"Main","type":"release","label":"Temporary Residence Limited","artist":"Prefuse 73"}]}"#
        let transport = JourneyTransport(routes: [
            "q=Prefuse73&type=artist&per_page=5": #"{"results":[{"id":3722,"title":"Prefuse 73"}]}"#,
            "q=Prefuse73&type=artist&per_page=50": #"{"pagination":{"items":1},"results":[{"id":3722,"title":"Prefuse 73"}]}"#,
            "artists/3722": ArtistIdentityFixtures.entries[3722]!,
            "artists/3722/releases": shelf,
            "releases/6947405": forsyth,
            "type=release": #"{"results":[]}"#
        ])
        let store = DigStore(context: context, discogsClient: DiscogsClient(transport: transport, token: "t"))
        await store.enrichArtist(name: "Prefuse73", mbid: nil)
        await store.enrichRelease(id: 6947405)
        try context.save()

        let shadow = ShadowGraph(context: context, store: store)
        let fromShow = shadow.neighbors(of: show)
        let prefuse = try XCTUnwrap(edge(fromShow, to: "Prefuse 73") ?? edge(fromShow, to: "Prefuse73")).to
        XCTAssertEqual(prefuse.id, "artist:discogs:3722")
        XCTAssertEqual(edge(fromShow, to: "Unfiled Selector")?.to.id, "artist:unfiled selector")

        let fromPrefuse = shadow.neighbors(of: prefuse)
        let viaCredit = try XCTUnwrap(fromPrefuse.first { $0.kind == .producer }).to
        let viaAlias = try XCTUnwrap(fromPrefuse.first { $0.kind == .sameAlias && $0.to.title == "Scott Herren" }).to
        XCTAssertEqual(viaCredit.id, "artist:discogs:229415")
        XCTAssertEqual(viaAlias.id, viaCredit.id, "Credited producer and listed alias are one node on a cold device too")
        XCTAssertEqual(fromPrefuse.first { $0.kind == .sameAlias && $0.to.title == "Piano Overlord" }?.to.id,
                       "artist:discogs:227795")
    }
}

private final class JourneyTransport: DiscogsTransport, @unchecked Sendable {
    let routes: [String: String]
    private let lock = NSLock()
    private var seen: [String] = []
    var requests: [String] { lock.withLock { seen } }
    init(routes: [String: String]) { self.routes = routes }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url?.absoluteString ?? ""
        lock.withLock { seen.append(String(url.dropFirst("https://api.discogs.com/".count).prefix(70))) }
        let route = routes.keys.filter(url.contains).max { $0.count < $1.count }
        let body = route.flatMap { routes[$0] } ?? "{}"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: route == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
    }
}
