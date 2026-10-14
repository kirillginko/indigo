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
        // A shade under the device's own credit of the same kind: on a tie, its own finds come first.
        XCTAssertEqual(byTitle["Ben Chasny"]?.confidence ?? 0, RelationshipKind.personnel.baseConfidence * CataloguePilot.confidenceShare, accuracy: 1e-9)
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

/// A clock a test can move.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

/// The remote config, as a test sets it; nil is a network failure.
private final class RemoteConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DigEnrichmentSwitch.Config?
    private(set) var reads = 0
    func set(_ config: DigEnrichmentSwitch.Config?) { lock.withLock { value = config } }
    func read() throws -> DigEnrichmentSwitch.Config {
        try lock.withLock {
            reads += 1
            guard let value else { throw URLError(.notConnectedToInternet) }
            return value
        }
    }
}

/// The remote switch (0084) in front of the pilot: every way it can be on, off,
/// stale or unreachable, and that turning it off deletes nothing.
@MainActor
final class DigEnrichmentSwitchTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    fileprivate var storage: PilotStorage!
    fileprivate var clock: TestClock!
    fileprivate var remote: RemoteConfig!
    var gate: DigEnrichmentSwitch!
    var pilot: CataloguePilot { .shared }
    var manifestDigest = ""

    override func setUp() async throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        storage = PilotStorage()
        clock = TestClock()
        remote = RemoteConfig()

        // The published pilot, as CataloguePilotTests publishes it.
        let data = Data(CataloguePilotTests.bundle.utf8)
        let digest = BundleFetcher.digest(data)
        let key = "knowledge/v1/bundles/\(digest.prefix(2))/\(digest).json"
        storage.objects[key] = data
        let manifest = Data(#"{"artists":{"272472":{"digest":"\#(digest)","key":"\#(key)","bytes":\#(data.count)}},"format":"indigo.catalogue-pilot/1","missing":[]}"#.utf8)
        manifestDigest = BundleFetcher.digest(manifest)
        let manifestKey = "knowledge/v1/catalogue/manifests/\(manifestDigest.prefix(2))/\(manifestDigest).json"
        storage.objects[manifestKey] = manifest
        storage.objects[CataloguePilot.pointerKey] = Data(#"{"manifest":"\#(manifestKey)","digest":"\#(manifestDigest)"}"#.utf8)

        gate = DigEnrichmentSwitch()
        gate.defaults = UserDefaults(suiteName: "indigo.tests.switch.\(UUID().uuidString)")!
        gate.cohort = .debug
        let clock = clock!, remote = remote!, storage = storage!
        gate.now = { clock.now }
        gate.fetch = { try remote.read() }

        pilot.reset()
        pilot.enabledOverride = nil
        pilot.remote = gate
        pilot.directory = FileManager.default.temporaryDirectory.appendingPathComponent("switch-\(UUID().uuidString)")
        pilot.read = { key, _ in storage.read(key) }
    }

    override func tearDown() {
        pilot.reset()
        pilot.remote = .shared
        pilot.read = CataloguePilot.live
        context = nil
        container = nil
    }

    private func config(enabled: Bool = true, cohorts: [String] = ["debug"], manifest: String? = nil) -> DigEnrichmentSwitch.Config {
        .init(version: 1, enabled: enabled, cohorts: cohorts, manifest: manifest ?? manifestDigest, ttlSeconds: 900, offlineGraceSeconds: 86_400)
    }

    private func routes() -> [MusicEdge] {
        IdentityGraph(context: context).neighbors(of: .artist("Magic Carpathians Project", discogsID: 272472))
    }

    func testNeverReadIsOffAndReadsNothing() async {
        XCTAssertEqual(gate.decision(), .off("never read"))
        XCTAssertFalse(pilot.isEnabled)
        let outcome = await pilot.ensure(272472)
        XCTAssertEqual(outcome, .off)
        XCTAssertEqual(storage.count, 0)
        XCTAssertTrue(routes().isEmpty)
    }

    func testOnThenOffRemotelyAndCachedBundlesStopToo() async {
        remote.set(config())
        await gate.refreshIfDue()
        XCTAssertTrue(pilot.isEnabled)
        let first = await pilot.ensure(272472)
        XCTAssertEqual(first, .fetched)
        XCTAssertFalse(routes().isEmpty, "On: the page has its routes")

        // Switched off; the device asks again once its 15 minutes are up.
        remote.set(config(enabled: false))
        await gate.refreshIfDue()
        XCTAssertTrue(pilot.isEnabled, "Within its TTL the device has not asked yet")
        let changed = expectation(forNotification: .digEnrichmentSwitchChanged, object: nil)
        clock.advance(901)
        await gate.refreshIfDue()
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(gate.decision(), .off("disabled"))
        XCTAssertNil(pilot.bundle(for: 272472), "A bundle already in memory is not read either")
        XCTAssertTrue(routes().isEmpty, "Off: the page is as it was")
    }

    func testAnUnlistedCohortIsOff() async {
        remote.set(config(cohorts: ["testflight"]))
        await gate.refreshIfDue()
        XCTAssertEqual(gate.decision(), .off("cohort debug not listed"))
        gate.cohort = .appstore
        XCTAssertFalse(gate.isOn)
        gate.cohort = .testflight
        XCTAssertTrue(gate.isOn)
    }

    func testOfflineStartupKeepsTheLastAnswerUntilItsGraceRunsOut() async {
        remote.set(config())
        await gate.refreshIfDue()
        _ = await pilot.ensure(272472)

        // A later launch, offline: the kept answer, the kept manifest, the bundle on disk.
        pilot.reset()
        remote.set(nil)
        storage.objects = [:]
        clock.advance(3_600)
        await gate.refreshIfDue()
        XCTAssertTrue(gate.isOn, "A failed refresh keeps the last answer")
        let offline = await pilot.ensure(272472)
        XCTAssertEqual(offline, .held)
        XCTAssertFalse(routes().isEmpty)

        // Still offline a day later: expired, off.
        clock.advance(86_400)
        XCTAssertEqual(gate.decision(), .off("expired"))
        XCTAssertTrue(routes().isEmpty)
    }

    func testOnlyThePinnedManifestIsRead() async {
        remote.set(config(manifest: String(repeating: "0", count: 64)))
        await gate.refreshIfDue()
        XCTAssertTrue(gate.isOn)
        guard case .failed = await pilot.ensure(272472) else { return XCTFail("a manifest the switch did not pin is refused") }
        XCTAssertTrue(routes().isEmpty)
    }

    func testTurningItOffDeletesNothing() async throws {
        let portrait = ArtistPortrait(nameKey: "anna nacher", name: "Anna Nacher")
        portrait.imageURLString = "https://img.test/anna.jpg"
        context.insert(portrait)
        try context.save()
        remote.set(config())
        await gate.refreshIfDue()
        _ = await pilot.ensure(272472)

        remote.set(config(enabled: false))
        clock.advance(901)
        await gate.refreshIfDue()
        XCTAssertFalse(gate.isOn)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<ArtistPortrait>()).count, 1, "The device's own data stays")

        // And back on: the bundle comes from disk, with no network read for it.
        pilot.reset()
        remote.set(config())
        clock.advance(901)
        await gate.refreshIfDue()
        let reads = storage.count
        let back = await pilot.ensure(272472)
        XCTAssertEqual(back, .held)
        XCTAssertEqual(storage.count, reads + 2, "Pointer and manifest only")
        XCTAssertFalse(routes().isEmpty)
    }
}

/// What the page takes from the catalogue (`DigStore.forPage`).
@MainActor
final class DigPageFromCatalogueTests: XCTestCase {
    func testThePageGetsItsBundlesLabelsAndKnowsWhichRoutesLeadOn() async throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let storage = PilotStorage()
        // Two bundles: the page's, and Six Organs Of Admittance's own.
        func put(_ body: String) -> (String, String, Int) {
            let data = Data(body.utf8)
            let digest = BundleFetcher.digest(data)
            let key = "knowledge/v1/bundles/\(digest.prefix(2))/\(digest).json"
            storage.objects[key] = data
            return (digest, key, data.count)
        }
        let page = put(CataloguePilotTests.bundle)
        let six = put(#"{"artist":{"discogsID":274469,"name":"Six Organs Of Admittance"},"collaborators":[],"credits":[],"format":"indigo.artist-knowledge/1","genres":[],"labels":[],"releases":[],"styles":[],"stylesAround":[]}"#)
        let manifest = Data(#"{"artists":{"272472":{"digest":"\#(page.0)","key":"\#(page.1)","bytes":\#(page.2)},"274469":{"digest":"\#(six.0)","key":"\#(six.1)","bytes":\#(six.2)}},"format":"indigo.catalogue-pilot/1","missing":[]}"#.utf8)
        let manifestDigest = BundleFetcher.digest(manifest)
        let manifestKey = "knowledge/v1/catalogue/manifests/\(manifestDigest.prefix(2))/\(manifestDigest).json"
        storage.objects[manifestKey] = manifest
        storage.objects[CataloguePilot.pointerKey] = Data(#"{"manifest":"\#(manifestKey)","digest":"\#(manifestDigest)"}"#.utf8)

        let pilot = CataloguePilot.shared
        pilot.reset()
        pilot.enabledOverride = true
        pilot.directory = FileManager.default.temporaryDirectory.appendingPathComponent("page-\(UUID().uuidString)")
        pilot.read = { key, _ in storage.read(key) }
        defer { pilot.reset(); pilot.enabledOverride = nil; pilot.read = CataloguePilot.live }

        let dig = DigStore(context: ModelContext(container))
        dig.portraitDefaults = UserDefaults(suiteName: "indigo.tests.page.\(UUID().uuidString)")!
        _ = await pilot.ensure(272472)
        let profile = await dig.artistProfile(name: "Magic Carpathians Project", mbid: nil, discogsID: 272472)

        XCTAssertEqual(profile.labels.first { $0.name == "Mental Telemetry" }?.discogsID, 79314, "The bundle's label, openable by its id")
        let byName = Dictionary(profile.related.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byName["Six Organs Of Admittance"]?.leadsOn, true, "Has a bundle of its own: leads somewhere")
        XCTAssertEqual(byName["Ben Chasny"]?.leadsOn, false, "Nothing known beyond the credit")
    }
}
