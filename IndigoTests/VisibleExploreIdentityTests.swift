//
//  VisibleExploreIdentityTests.swift
//  IndigoTests
//
//  DIG's graph — DEEP, RELATED and connections — walked under identity keys,
//  through the engines the pages call. Each verified artist is one row however
//  they were reached and opens their own entry; aliases and namesakes stay
//  apart; the listener's crate, visits and steps are matched by the names they
//  hold and are never rewritten; and a name is only counted toward an entry
//  when a complete check says nobody else answers to it.
//

import XCTest
import SwiftData
@testable import Indigo

private let forsyth = #"""
{"id":6947405,"title":"Forsyth Gardens","year":2015,
 "artists":[{"id":3722,"name":"Prefuse 73"}],
 "labels":[{"id":6000,"name":"Temporary Residence Limited","catno":"TRR 210"}],
 "extraartists":[{"id":229415,"name":"Scott Herren","anv":"Guillermo S. Herren","role":"Written-By, Producer"}]}
"""#
private let oneNation = #"""
{"id":1,"title":"One Nation","year":2010,"artists":[{"id":1874027,"name":"Hype Williams (2)"}],
 "extraartists":[{"id":2419343,"name":"Dean Blunt","anv":"Blunt","role":"Producer"}]}
"""#
private let belly = #"{"id":2,"title":"Belly","year":1998,"artists":[{"id":82,"name":"Hype Williams"}]}"#
private let blackMetal = #"""
{"id":3,"title":"Black Metal","year":2014,"artists":[{"id":2419343,"name":"Dean Blunt"}],
 "extraartists":[{"id":1053396,"name":"Joanne Robertson","role":"Vocals"}]}
"""#
private let ciro = #"""
{"id":900,"title":"Tides","year":2021,"artists":[{"id":777,"name":"Ciro Vitiello"}],
 "extraartists":[{"id":1720124,"name":"Attilio Novellino","role":"Producer"}]}
"""#

@MainActor
final class VisibleExploreIdentityTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        IdentityChecks.shared.reset()
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    // MARK: Fixture

    private func store(_ json: String, _ id: Int) throws {
        DiscogsEnricher(context: context, client: DiscogsClient())
            .store(try JSONDecoder().decode(DiscogsReleaseDetail.self, from: Data(json.utf8)), id: id)
    }

    private func file(_ name: String, _ id: Int, releases: [(Int, String)] = [], aliases: [String] = []) {
        let record = DiscogsArtist(nameKey: RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(name)),
                                   discogsID: id, name: name)
        record.aliasNames = aliases
        record.releaseTitles = releases.map(\.1); record.releaseDiscogsIDs = releases.map(\.0)
        record.releaseYears = releases.map { _ in "2015" }
        record.releaseImageURLStrings = releases.map { _ in "" }; record.releaseLabels = releases.map { _ in "" }
        context.insert(record)
    }

    @discardableResult
    private func radio(_ artists: [String]) throws -> MusicNode {
        let recordings = RecordingStore(context: context)
        for (index, artist) in artists.enumerated() {
            let recording = try recordings.upsert(title: "Track \(index)", artistName: artist)
            recordings.note(appearance: MediaAppearance(
                providerID: "nts", stationName: "NTS 1", showTitle: "Guests", showID: "guests",
                heardAt: Date(timeIntervalSince1970: 1_788_000_000 + Double(index)),
                offsetSeconds: Double(index * 300), isLive: false, method: .providerTracklist
            ), on: recording)
        }
        try context.save()
        return .broadcast(providerID: "nts", showID: "guests", title: "Guests")
    }

    private func crate(_ name: String) {
        CrateService(context: context).add(dig: .artist, identifier: name, providerID: "discogs",
                                           title: name, subtitle: nil, artworkURL: nil)
    }

    /// The populated world: what a long-used Mac holds about these artists.
    @discardableResult
    private func populated() throws -> MusicNode {
        let identity = ArtistIdentityStore(context: context)
        identity.record(DiscogsSpellingCheck(spelling: "Prefuse73", verdict: .variation(3722), resultCount: 15,
                                             results: [], facts: [try ArtistIdentityFixtures.facts(3722)]))
        for id in [229415, 227795] { identity.record(try ArtistIdentityFixtures.facts(id)) }
        for (json, id) in [(forsyth, 6947405), (oneNation, 1), (belly, 2), (blackMetal, 3), (ciro, 900)] {
            try store(json, id)
        }
        file("Prefuse 73", 3722, releases: [(6947405, "Forsyth Gardens")], aliases: ["Scott Herren", "Piano Overlord"])
        file("Scott Herren", 229415, aliases: ["Prefuse 73", "Piano Overlord"])
        file("Hype Williams (2)", 1874027, releases: [(1, "One Nation")])
        file("Dean Blunt", 2419343, releases: [(3, "Black Metal")])
        file("Ciro Vitiello", 777, releases: [(900, "Tides")])
        try context.save()
        return try radio(["Prefuse73", "Unfiled Selector", "Hype Williams", "Ciro Vitiello", "Attilio Novellino"])
    }

    private func deep(_ origin: MusicNode, showing: Set<String> = []) -> [DeepResult] {
        DeepEngine(context: context).results(from: origin, showing: showing)
    }

    private func rows(_ results: [DeepResult], titled title: String) -> [DeepResult] {
        results.filter { $0.node.title == title }
    }

    // MARK: Prefuse73 and Scott Herren

    func testTheShowReachesPrefuse73OnceAndOpensHisEntry() throws {
        let show = try populated()
        let results = deep(show)

        let prefuse = results.filter { $0.node.kind == .artist && ["Prefuse 73", "Prefuse73"].contains($0.node.title) }
        XCTAssertEqual(prefuse.count, 1, "One row, however the tracklist spelled him")
        XCTAssertEqual(prefuse.first?.node.id, "artist:discogs:3722")
        XCTAssertEqual(prefuse.first?.node.destination, .digArtist(mbid: nil, name: "Prefuse 73", discogsID: 3722))
        XCTAssertEqual(rows(results, titled: "Unfiled Selector").first?.node.id, "artist:unfiled selector",
                       "A name nothing identifies is still offered")
    }

    func testScottHerrenIsOneRowUnderEitherCreditedSpelling() throws {
        try populated()
        let results = deep(.release("Forsyth Gardens", discogsID: 6947405))
        let herren = results.filter { $0.node.discogsID == 229415 }

        XCTAssertEqual(herren.count, 1)
        XCTAssertEqual(herren.first?.node.title, "Scott Herren", "Called what his entry is called")
        XCTAssertTrue(herren.first?.reasons.contains { $0.kind == .producer } ?? false, "The credit's role stays the reason")
        XCTAssertEqual(herren.first?.node.destination, .digArtist(mbid: nil, name: "Scott Herren", discogsID: 229415))
    }

    func testPianoOverlordStaysItsOwnArtist() throws {
        try populated()
        let connections = DigEngine(context: context).connections(from: .artist("Scott Herren", discogsID: 229415))
        let piano = connections.filter { $0.to.title == "Piano Overlord" }
        let prefuse = connections.filter { $0.to.title == "Prefuse 73" }

        XCTAssertEqual(piano.map(\.to.id), ["artist:discogs:227795"], "An alias is its own identity, not merged")
        XCTAssertEqual(prefuse.map(\.to.id), ["artist:discogs:3722"])
    }

    // MARK: Namesakes, Dean Blunt and Joanne Robertson

    func testTheHypeWilliamsNamesakesOpenTheirOwnPages() throws {
        try populated()
        let duo = deep(.release("One Nation", discogsID: 1)).first { $0.node.title == "Hype Williams" }?.node
        let director = deep(.release("Belly", discogsID: 2)).first { $0.node.title == "Hype Williams" }?.node

        XCTAssertEqual(duo?.destination, .digArtist(mbid: nil, name: "Hype Williams", discogsID: 1874027))
        XCTAssertEqual(director?.destination, .digArtist(mbid: nil, name: "Hype Williams", discogsID: 82))
        // The radio's bare "Hype Williams" could be either, and stays a name.
        let fromShow = deep(.broadcast(providerID: "nts", showID: "guests", title: "Guests"))
        XCTAssertEqual(rows(fromShow, titled: "Hype Williams").map(\.node.id), ["artist:hype williams"])
    }

    func testBluntOnTheDuosRecordIsDeanBluntAndStillCrated() throws {
        try populated()
        crate("Dean Blunt")
        let results = deep(.release("One Nation", discogsID: 1))
        let blunt = try XCTUnwrap(results.first { $0.node.discogsID == 2419343 })

        XCTAssertEqual(blunt.node.title, "Dean Blunt")
        XCTAssertEqual(blunt.node.destination, .digArtist(mbid: nil, name: "Dean Blunt", discogsID: 2419343))
        XCTAssertEqual(blunt.signals.crateCount, 1, "Crated as \"Dean Blunt\", reached as \"Blunt\": still kept")
        XCTAssertNil(results.first { $0.node.title == "Blunt" }, "No second row under the credited spelling")

        let related = DigEngine(context: context).relatedArtists(to: "Hype Williams", discogsID: 1874027)
        XCTAssertEqual(related.filter { $0.name == "Dean Blunt" }.map(\.discogsID), [2419343])
    }

    /// What a page already shows is matched under every name behind a row.
    func testAnArtistThePageShowsByNameIsNotRepeated() throws {
        try populated()
        let shown = deep(.release("One Nation", discogsID: 1), showing: [MusicNode.artist("Dean Blunt").id])
        XCTAssertNil(shown.first { $0.node.discogsID == 2419343 })
    }

    func testJoanneRobertsonKeepsHerCrateStatusUnderHerEntry() throws {
        try populated()
        crate("Joanne Robertson")
        let joanne = try XCTUnwrap(deep(.release("Black Metal", discogsID: 3)).first { $0.node.title == "Joanne Robertson" })

        XCTAssertEqual(joanne.node.id, "artist:discogs:1053396")
        XCTAssertEqual(joanne.signals.crateCount, 1)
    }

    // MARK: Attilio Novellino: a name route and a credit route

    private func attilio(_ related: [RelatedArtist]) -> [RelatedArtist] {
        related.filter { $0.name == "Attilio Novellino" }
    }

    /// Only a credit names his entry; the radio route reaches the name, which
    /// nothing identifies. One row — his — on the credit alone: the radio route
    /// is not his until a check says so, and the name is asked about.
    func testTheNameRouteIsOneRowButDoesNotCountTowardHim() throws {
        try populated()
        let rows = attilio(DigEngine(context: context).relatedArtists(to: "Ciro Vitiello", discogsID: 777))

        XCTAssertEqual(rows.map(\.discogsID), [1720124], "Not \"Attilio Novellino\" twice")
        XCTAssertEqual(Set(rows[0].reasons.map(\.kind)), [.producer], "The credit alone")
        XCTAssertTrue(IdentityChecks.shared.take(50).contains("Attilio Novellino"), "Asked about, once")
    }

    /// DIG filed his record under the name: the same answer.
    func testAFiledRecordShowsOneRowWithoutCountingTheNameRoute() throws {
        try populated()
        file("Attilio Novellino", 1720124)
        try context.save()
        let rows = attilio(DigEngine(context: context).relatedArtists(to: "Ciro Vitiello", discogsID: 777))

        XCTAssertEqual(rows.map(\.discogsID), [1720124])
        XCTAssertEqual(Set(rows[0].reasons.map(\.kind)), [.producer])
    }

    /// DIG's page for the name is somebody else's entry: two artists, two rows.
    func testANameWhosePageIsAnotherEntryKeepsItsRow() throws {
        try populated()
        file("Attilio Novellino", 555)
        try context.save()
        let rows = attilio(DigEngine(context: context).relatedArtists(to: "Ciro Vitiello", discogsID: 777))
        XCTAssertEqual(Set(rows.map(\.id)), ["discogs:1720124", "Attilio Novellino"])
    }

    /// A complete check found two entries under the name: namesakes, so the
    /// name's row comes back and is nobody's.
    func testANameACheckFoundSharedKeepsItsRow() throws {
        try populated()
        ArtistIdentityStore(context: context).record(DiscogsSpellingCheck(
            spelling: "Attilio Novellino", verdict: .ambiguous([555, 1720124]), resultCount: 2, results: [], facts: []))
        try context.save()
        let rows = attilio(DigEngine(context: context).relatedArtists(to: "Ciro Vitiello", discogsID: 777))
        XCTAssertEqual(Set(rows.map(\.id)), ["discogs:1720124", "Attilio Novellino"])
    }

    /// A complete check found nobody else under the name: the radio route is his
    /// too, and counts. The name's own rows are untouched.
    func testACompleteCheckLetsTheNameRouteReinforceHim() throws {
        try populated()
        file("Attilio Novellino", 1720124)
        try context.save()
        let before = try XCTUnwrap(attilio(DigEngine(context: context).relatedArtists(to: "Ciro Vitiello", discogsID: 777)).first)

        let facts = DiscogsIdentityFacts(id: 1720124, name: "Attilio Novellino", realName: nil,
                                         nameVariations: [], aliases: [], groups: [], members: [])
        ArtistIdentityStore(context: context).record(DiscogsSpellingCheck(
            spelling: "Attilio Novellino", verdict: .canonical([1720124]), resultCount: 1, results: [], facts: [facts]))
        try context.save()
        let rows = attilio(DigEngine(context: context).relatedArtists(to: "Ciro Vitiello", discogsID: 777))

        XCTAssertEqual(rows.map(\.discogsID), [1720124], "Still one row")
        XCTAssertTrue(Set(rows[0].reasons.map(\.kind)).isSuperset(of: [.producer, .sharedBroadcast]),
                      "The radio route now counts toward him")
        XCTAssertGreaterThan(rows[0].weight, before.weight)
        let recordings = try context.fetch(FetchDescriptor<Recording>()).filter { $0.artistName == "Attilio Novellino" }
        XCTAssertEqual(recordings.count, 1, "His radio row is still filed under the name")
    }

    /// The whole loop: the walk notes the name, DIG asks Discogs (stubbed), a
    /// complete check names his entry, and the next walk counts the radio route.
    func testTheNotedNameIsCheckedAndThenCounts() async throws {
        try populated()
        IdentityChecks.shared.reset()
        let facts = #"{"id":1720124,"name":"Attilio Novellino","namevariations":[],"aliases":[],"groups":[],"members":[]}"#
        let transport = StubDiscogs(routes: [
            "type=artist&per_page=50": #"{"pagination":{"items":1},"results":[{"id":1720124,"title":"Attilio Novellino"}]}"#,
            "artists/1720124": facts
        ])
        let store = DigStore(context: context, discogsClient: DiscogsClient(transport: transport, token: "t"))
        store.settlesGraphNames = true
        let before = try XCTUnwrap(attilio(DigEngine(context: context).relatedArtists(to: "Ciro Vitiello", discogsID: 777)).first)
        XCTAssertEqual(Set(before.reasons.map(\.kind)), [.producer])

        await store.settleGraphNames()

        XCTAssertEqual(ArtistIdentityStore(context: context).verdict(for: "Attilio Novellino"), .canonical([1720124]))
        let after = attilio(DigEngine(context: context).relatedArtists(to: "Ciro Vitiello", discogsID: 777))
        XCTAssertEqual(after.map(\.discogsID), [1720124])
        XCTAssertTrue(Set(after[0].reasons.map(\.kind)).isSuperset(of: [.producer, .sharedBroadcast]))
        XCTAssertEqual(transport.requests.filter { $0.contains("search") }.count, 1, "One search, once")
        await store.settleGraphNames()
        XCTAssertEqual(transport.requests.filter { $0.contains("search") }.count, 1, "Not asked again")
    }

    // MARK: History

    /// Crate items, visits and steps hold the names they always held, open the
    /// pages they always opened, and a walk writes none of them.
    func testHistoryOpensTheRightPagesAndIsNotRewritten() throws {
        let show = try populated()
        let history = DigHistory(context: context)
        history.record(.artist("Prefuse73"), from: show)
        history.record(.artist("Dean Blunt"), from: .artist("Prefuse73"))
        crate("Prefuse73")
        try context.save()
        let before = try context.fetch(FetchDescriptor<DigVisit>()).map(\.nodeID).sorted()

        _ = deep(show)
        _ = DigEngine(context: context).relatedArtists(to: "Prefuse 73", discogsID: 3722)

        let visits = try context.fetch(FetchDescriptor<DigVisit>())
        XCTAssertEqual(visits.map(\.nodeID).sorted(), before)
        XCTAssertTrue(before.contains("artist:prefuse73"), "Kept under the spelling it was visited by")
        let store = DigStore(context: context)
        let page = store.artistPage(ArtistReference(name: "Prefuse73"))
        XCTAssertEqual(page.discogsID, 3722, "and it still opens Prefuse 73")
        XCTAssertEqual(page.name, "Prefuse 73")
        XCTAssertEqual(store.artistPage(ArtistReference(name: "Dean Blunt")).discogsID, 2419343)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DigStep>()), 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CrateItem>()).map(\.displayTitle), ["Prefuse73"])
    }

    // MARK: Determinism

    func testTheSameRowsInAnyOrder() throws {
        let show = try populated()
        func walk(_ engine: DeepEngine) -> [String] {
            [show, .release("One Nation", discogsID: 1), .release("Forsyth Gardens", discogsID: 6947405)]
                .flatMap { engine.results(from: $0) }
                .map { "\($0.node.id)|\($0.level)|\($0.reasons.map(\.kind.rawValue).sorted())" }
                .sorted()
        }
        let first = walk(DeepEngine(context: context))
        let other = DeepEngine(context: context)
        _ = other.results(from: .artist("Scott Herren", discogsID: 229415))
        XCTAssertEqual(walk(other), first)
        XCTAssertEqual(walk(other), first, "And twice")
    }

    // MARK: A cold device

    /// An empty store: one show heard, and the Forsyth Gardens page opened —
    /// its credits are the only evidence there is.
    func testAColdDeviceReachesTheSameIdentities() throws {
        let show = try radio(["Prefuse73", "Unfiled Selector"])
        try store(forsyth, 6947405)
        try context.save()

        let fromShow = deep(show)
        XCTAssertEqual(rows(fromShow, titled: "Prefuse73").map(\.node.id), ["artist:prefuse73"],
                       "Nothing has checked the spelling yet, so it is still a name")
        let fromRelease = deep(.release("Forsyth Gardens", discogsID: 6947405))
        XCTAssertEqual(fromRelease.filter { $0.node.discogsID == 229415 }.map(\.node.title), ["Scott Herren"])
        XCTAssertEqual(fromRelease.filter { $0.node.discogsID == 3722 }.map(\.node.title), ["Prefuse 73"])
    }
}

private final class StubDiscogs: DiscogsTransport, @unchecked Sendable {
    let routes: [String: String]
    private let lock = NSLock()
    private var seen: [String] = []
    var requests: [String] { lock.withLock { seen } }
    init(routes: [String: String]) { self.routes = routes }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url?.absoluteString ?? ""
        lock.withLock { seen.append(url) }
        let route = routes.keys.filter(url.contains).max { $0.count < $1.count }
        let body = route.flatMap { routes[$0] } ?? "{}"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: route == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
    }
}
