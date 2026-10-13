//
//  CataloguePilotTests.swift
//  IndigoTests
//
//  The DIG catalogue pilot (`CataloguePilot`): a dead-end artist's page gains
//  the routes its bundle names, each to an entry by Discogs id; off, missing
//  or failing its digest, the page is exactly what it was. The bundle is the
//  published one for Magic Carpathians Project (272472), trimmed.
//

import XCTest
import SwiftData
@testable import Indigo

/// R2, answered from a table, counting reads.
private final class PilotStorage: @unchecked Sendable {
    private let lock = NSLock()
    var objects: [String: Data] = [:]
    private(set) var reads: [String] = []
    func read(_ key: String) -> (status: Int, data: Data?) {
        lock.withLock {
            reads.append(key)
            return objects[key].map { (200, $0) } ?? (404, nil)
        }
    }
    var count: Int { lock.withLock { reads.count } }
}

@MainActor
final class CataloguePilotTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    fileprivate var storage: PilotStorage!
    var pilot: CataloguePilot { .shared }

    static let bundle = """
    {"artist":{"discogsID":272472,"name":"Magic Carpathians Project","nameKey":"magic carpathians project"},\
    "collaborators":[{"artist":{"discogsID":274469,"name":"Six Organs Of Admittance"},"how":["joint"],"releases":[863079]}],\
    "credits":[{"artist":{"discogsID":274470,"name":"Ben Chasny"},"roles":[{"kind":"performance","releases":[{"id":863079,"tracks":["3"]}],"role":"Performer"}]},\
    {"artist":{"discogsID":967691,"name":"Anonymous"},"roles":[{"kind":"writing","releases":[{"id":863079,"tracks":["1"]}],"role":"Written-By"}]},\
    {"artist":{"discogsID":0,"name":"B. Beard-J. Minor"},"roles":[{"kind":"performance","releases":[{"id":863079,"tracks":["2"]}],"role":"Vocals"}]},\
    {"artist":{"anv":"Anna Nachter","discogsID":520128,"name":"Anna Nacher"},"roles":[{"kind":"performance","releases":[{"id":863079,"tracks":["1","2"]}],"role":"Performer"}]}],\
    "format":"indigo.artist-knowledge/1","genres":[],"labels":[{"discogsID":79314,"display":"Mental Telemetry","name":"Mental Telemetry","ownName":false,"placeholder":false,"releases":1}],\
    "releases":[{"compilation":false,"id":863079,"masterID":null,"relation":"joint","title":"Magic Carpathians Project / Six Organs Of Admittance / Vibracathedral Orchestra","year":2006}],\
    "styles":[],"stylesAround":[]}
    """

    override func setUp() async throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        storage = PilotStorage()
        publish(Self.bundle, for: 272472)
        let storage = storage!
        pilot.reset()
        pilot.enabledOverride = true
        pilot.directory = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-\(UUID().uuidString)")
        pilot.read = { key, _ in storage.read(key) }
    }

    override func tearDown() {
        pilot.reset()
        pilot.enabledOverride = nil
        pilot.read = CataloguePilot.live
        context = nil
        container = nil
    }

    private func publish(_ bundle: String, for id: Int, digestOf: String? = nil) {
        let data = Data(bundle.utf8)
        let digest = BundleFetcher.digest(Data((digestOf ?? bundle).utf8))
        let key = "knowledge/v1/bundles/\(digest.prefix(2))/\(digest).json"
        storage.objects[key] = data
        let manifest = Data(#"{"artists":{"\#(id)":{"digest":"\#(digest)","key":"\#(key)","bytes":\#(data.count)}},"format":"indigo.catalogue-pilot/1","missing":[]}"#.utf8)
        let manifestDigest = BundleFetcher.digest(manifest)
        let manifestKey = "knowledge/v1/catalogue/manifests/\(manifestDigest.prefix(2))/\(manifestDigest).json"
        storage.objects[manifestKey] = manifest
        storage.objects[CataloguePilot.pointerKey] = Data(#"{"manifest":"\#(manifestKey)","digest":"\#(manifestDigest)"}"#.utf8)
    }

    private func neighbours() -> [MusicEdge] {
        IdentityGraph(context: context).neighbors(of: .artist("Magic Carpathians Project", discogsID: 272472))
    }

    func testADeadEndGainsItsBundlesRoutesEachByDiscogsID() async {
        XCTAssertTrue(neighbours().isEmpty, "A dead end: nothing before")
        let outcome = await pilot.ensure(272472)
        XCTAssertEqual(outcome, .fetched)
        let edges = neighbours()
        let byTitle = Dictionary(edges.map { ($0.to.title, $0) }, uniquingKeysWith: { a, _ in a })

        XCTAssertEqual(byTitle["Six Organs Of Admittance"]?.kind, .collaborator)
        XCTAssertEqual(byTitle["Six Organs Of Admittance"]?.reason.hasPrefix("Made "), true)
        XCTAssertEqual(byTitle["Ben Chasny"]?.kind, .personnel)
        XCTAssertEqual(byTitle["Mental Telemetry"]?.kind, .sharedLabel)
        // Every route opens its own entry, not whoever shares the name.
        guard case .digArtist(_, _, let chasny)? = byTitle["Ben Chasny"]?.to.destination else { return XCTFail() }
        XCTAssertEqual(chasny, 274470)
        guard case .digDiscogsLabel(_, let label)? = byTitle["Mental Telemetry"]?.to.destination else { return XCTFail() }
        XCTAssertEqual(label, 79314)
        XCTAssertTrue(edges.filter { $0.to.kind == .artist }.allSatisfy { ($0.to.discogsID ?? 0) > 0 }, "No name-only route")
        XCTAssertNil(byTitle["Anonymous"], "A stand-in is nobody to go to")
        XCTAssertNil(byTitle["B. Beard-J. Minor"], "A credit with no entry is no route")
    }

    func testTheSecondAskIsHeldAndALaterLaunchReadsTheDisk() async {
        _ = await pilot.ensure(272472)
        let reads = storage.count
        let outcome1 = await pilot.ensure(272472)
        XCTAssertEqual(outcome1, .held)
        XCTAssertEqual(storage.count, reads, "Held in memory: no read")

        pilot.reset()   // a new launch: the pointer and manifest again, the bundle from disk
        let outcome2 = await pilot.ensure(272472)
        XCTAssertEqual(outcome2, .held)
        XCTAssertEqual(storage.count, reads + 2)
    }

    func testOffMissingOrFailingLeavesThePageAsItWas() async {
        pilot.enabledOverride = false
        let outcome3 = await pilot.ensure(272472)
        XCTAssertEqual(outcome3, .off)
        XCTAssertNil(pilot.bundle(for: 272472))
        XCTAssertEqual(storage.count, 0, "Off: not a single read")

        pilot.enabledOverride = true
        let outcome4 = await pilot.ensure(1234)
        XCTAssertEqual(outcome4, .notInPilot)
        XCTAssertTrue(IdentityGraph(context: context).neighbors(of: .artist("Somebody", discogsID: 1234)).isEmpty)

        pilot.reset()
        publish(#"{"tampered":true}"#, for: 272472, digestOf: Self.bundle)
        guard case .failed = await pilot.ensure(272472) else { return XCTFail("a bundle not its digest is refused") }
        XCTAssertTrue(neighbours().isEmpty)
    }

    func testANamesakeRowIsNotTheRouteAndTheArtistIsNotItsOwnNeighbour() async {
        // A device row for another "Ben Chasny"-spelled name, and the page's own id in a credit.
        _ = await pilot.ensure(272472)
        let edges = neighbours()
        XCTAssertFalse(edges.contains { $0.to.discogsID == 272472 }, "Not its own neighbour")
        XCTAssertEqual(edges.filter { $0.to.title == "Ben Chasny" }.compactMap(\.to.discogsID), [274470])
    }

    func testAnUnreachableHostCostsOneWaitNotOneAPage() async {
        let storage = storage!
        storage.objects = [:]   // nothing answers
        guard case .failed = await pilot.ensure(272472) else { return XCTFail() }
        let reads = storage.count
        guard case .failed = await pilot.ensure(274469) else { return XCTFail() }
        XCTAssertEqual(storage.count, reads, "Within the cooldown nothing is asked again")
        XCTAssertTrue(neighbours().isEmpty, "And the page is what it was")
    }

    func testAnUnreachableHostFallsBackToTheLastCheckedManifest() async {
        let storage = storage!
        _ = await pilot.ensure(272472)        // a good launch keeps the manifest and the bundle
        pilot.reset()
        storage.objects = [:]                 // the next launch cannot reach the host
        let outcome = await pilot.ensure(272472)
        XCTAssertEqual(outcome, .held, "From the kept manifest and the bundle on disk")
        XCTAssertFalse(neighbours().isEmpty)
    }

    func testAReadThatFailsOnceIsTriedAgain() async {
        let storage = storage!
        let flaky = FlakyOnce()
        pilot.read = { key, _ in
            if flaky.first(key) { throw URLError(.timedOut) }
            return storage.read(key)
        }
        let outcome = await pilot.ensure(272472)
        XCTAssertEqual(outcome, .fetched)
    }
}

/// Fails the first read of each key.
private final class FlakyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []
    func first(_ key: String) -> Bool { lock.withLock { seen.insert(key).inserted } }
}
