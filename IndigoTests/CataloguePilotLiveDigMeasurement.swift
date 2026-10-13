//
//  CataloguePilotLiveDigMeasurement.swift
//  IndigoTests
//
//  The DIG catalogue pilot beside the real app's own Discogs fetching, on the
//  live network. For each artist: the page is opened as the app opens it --
//  the walk, and the enrichment that reads Discogs (counted) -- with the pilot
//  on, watched until both settle. Then the same store is walked with the pilot
//  off, which is what the page would show from its own discovery alone.
//  Opt-in: `TEST_RUNNER_INDIGO_MEASURE_PILOT_LIVE=1`. Fresh in-memory stores:
//  nobody's history, no CloudKit. Writes `catalogue-pilot-live.json` to the
//  host's temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

/// Discogs requests, counted.
private final class CountingTransport: DiscogsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { count += 1 }
        return try await NetworkEnvironment.metadataSession.data(for: request)
    }
}

@MainActor
final class CataloguePilotLiveDigMeasurement: XCTestCase {
    /// Every fifth of the 300 by Discogs id, and Mayday (Derrick May's alias).
    static let pilot: [(Int, String)] = [(1212, "Rick White"), (22043, "Soul Circuit"), (65642, "John Wall"), (115113, "Vitor Joaquim"), (149284, "Remy Unger"), (180792, "South (2)"), (236110, "The Legends"), (272472, "Magic Carpathians Project"), (343258, "Virgo (8)"), (416861, "Kim Salmon"), (500146, "Greg Ward (2)"), (569621, "Shuttle (2)"), (656630, "Maddzart"), (790552, "Victoria Jordanova"), (905358, "Quartetto Cetra"), (963427, "Oliver Hess"), (1094557, "Hong Chulki"), (1129543, "Elisabeth Kontomanou"), (1262401, "Y-Dresta"), (1386362, "Ortho Acusto"), (1535009, "Chris Liberator & Sterling Moss"), (1678206, "DJ Strong"), (1838167, "The Squires Of The Subterrain"), (2141906, "Kaela Kimura"), (2407754, "Willie Jolley"), (2517131, "Cunnilingus"), (2599936, "Bobby Floyd (2)"), (2764694, "DKMD"), (2940588, "Slugbug (2)"), (3136840, "DJ Bazooka Joe"), (3285198, "John Wholetrain"), (3719448, "Stahl (5)"), (3918839, "Trig (4)"), (4100826, "Andrew Pinnock (2)"), (4489198, "La Division Technique"), (4712643, "Gardna"), (4868658, "Ryan De La Cruz"), (5068121, "Sam Wilkes (2)"), (5369498, "Lewis OfMan"), (5585947, "Niilas"), (5851908, "Maga (6)"), (5944688, "Athlete Whippet"), (6185944, "Ty Da Dale"), (6571442, "DJ Couta"), (7041670, "Jeremy-Pastell"), (7493539, "Sir Bobby Jukebox"), (7705484, "Lehay"), (7964992, "Isabell Gustafsson-Ny"), (8195299, "Decent Rides"), (8443047, "Kaleidoscope Saxophone Quartet"), (9467677, "Eyedoublecross"), (10348369, "Fines Double"), (10801636, "Yung Xabo"), (11357960, "Thingamajigs Performance Group"), (11706239, "Kid Sportswear"), (12226912, "Koperblond"), (12836132, "DJ Cali4it"), (14250457, "Craz Digga"), (15250716, "Che (38)"), (16446748, "A2P Fred"), (4978, "Mayday")]
    /// Not in the pilot: a namesake, another namesake, an alias pair, a spelling.
    static let outside: [(Int, String)] = [(398459, "Hype Williams"), (316464, "Speedy J"), (2576890, "Mica Levi"),
                                           (1172814, "Micachu"), (3722, "Prefuse 73")]

    struct Row: Codable { var name: String; var discogsID: Int?; var kinds: [String] }
    struct Page: Codable {
        var discogsID = 0
        var name = ""
        var inPilot = true
        var bundle = ""
        var firstRouteMs: Int?          // pilot on: first moment the page offered any route
        var firstLocalRouteMs: Int?     // the first route the device's own discovery gave
        var firstBundleRouteMs: Int?
        var settledMs = 0
        var discogsRequests = 0
        var requestsBeforeFirstLocalRoute: Int?
        var on: [Row] = []
        var off: [Row] = []
        var gained = 0                  // rows on the page only because of the bundle
        var alsoLocal = 0               // rows the bundle and the device both found
        var duplicates: [String] = []
        var aliasConfusion: [String] = []
        var navigationWrong: [String] = []
        var aliases: [Int] = []
    }
    struct Probe: Codable { var ms: [Int] = []; var errors: [String] = [] }
    struct Report: Codable { var pages: [Page] = []; var r2: Probe = Probe() }

    private func millis(_ since: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - since
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    private func rows(_ profile: ArtistProfile) -> [Row] {
        profile.related.map { Row(name: $0.name, discogsID: $0.discogsID, kinds: $0.reasons.map { String(describing: $0.kind) }) }
    }

    private func token() -> String? {
        guard let bundled = Bundle.main.object(forInfoDictionaryKey: "IndigoDiscogsToken") as? String else { return nil }
        return ObfuscatedSecret.reveal(bundled)
    }

    /// The host itself: 30 plain reads of the pointer, timed, errors kept.
    private func probeR2() async -> Probe {
        var probe = Probe()
        for _ in 0..<30 {
            let started = ContinuousClock.now
            do {
                let (status, _) = try await CataloguePilot.live(CataloguePilot.pointerKey, true)
                probe.ms.append(millis(started))
                if status != 200 { probe.errors.append("HTTP \(status)") }
            } catch {
                probe.ms.append(millis(started))
                probe.errors.append((error as? URLError).map { "URLError \($0.code.rawValue)" } ?? "\(error)")
            }
        }
        return probe
    }

    func testThePilotBesideTheAppsOwnDiscovery() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_MEASURE_PILOT_LIVE"] == "1",
                          "Set TEST_RUNNER_INDIGO_MEASURE_PILOT_LIVE=1.")
        let token = try XCTUnwrap(token(), "The build's Discogs token")
        let pilot = CataloguePilot.shared
        pilot.directory = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-live-\(UUID().uuidString)")
        defer { pilot.enabledOverride = nil; pilot.reset() }
        var report = Report()
        report.r2 = await probeR2()

        for (id, discogsName, inPilot) in Self.pilot.map({ ($0.0, $0.1, true) }) + Self.outside.map({ ($0.0, $0.1, false) }) {
            let name = DiscogsClient.withoutDisambiguator(discogsName)
            var page = Page(discogsID: id, name: name, inPilot: inPilot)
            let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
            let transport = CountingTransport()
            let discogs = DiscogsClient(transport: transport, token: token, gateway: .shared)
            let dig = DigStore(context: ModelContext(container), discogsClient: discogs)
            dig.portraitDefaults = UserDefaults(suiteName: "indigo.tests.pilot-live.\(UUID().uuidString)")!

            pilot.enabledOverride = true
            pilot.reset()
            let started = ContinuousClock.now
            let enrichment = Task { await dig.enrichArtist(name: name, mbid: nil, discogsID: id) }
            var enriched = false
            Task { _ = await enrichment.value; enriched = true }
            while millis(started) < 120_000 {
                let profile = await dig.artistProfile(name: name, mbid: nil, discogsID: id)
                let bundleIDs = Set((pilot.bundle(for: id)?.collaborators.compactMap(\.artist.discogsID) ?? [])
                                    + (pilot.bundle(for: id)?.credits.compactMap(\.artist.discogsID) ?? []))
                if !profile.related.isEmpty, page.firstRouteMs == nil { page.firstRouteMs = millis(started) }
                if page.firstBundleRouteMs == nil, profile.related.contains(where: { $0.discogsID.map(bundleIDs.contains) == true }) {
                    page.firstBundleRouteMs = millis(started)
                }
                if page.firstLocalRouteMs == nil, profile.related.contains(where: { $0.discogsID.map { !bundleIDs.contains($0) } ?? true }) {
                    page.firstLocalRouteMs = millis(started)
                    page.requestsBeforeFirstLocalRoute = transport.requests
                }
                if enriched, inPilot ? pilot.bundle(for: id) != nil || millis(started) > 30_000 : true { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            _ = await enrichment.value
            page.settledMs = millis(started)
            page.discogsRequests = transport.requests
            page.bundle = pilot.bundle(for: id) == nil ? "none" : "read"

            let on = await dig.artistProfile(name: name, mbid: nil, discogsID: id)
            page.on = rows(on)
            // The same store, walked by a store that has never seen the pilot.
            pilot.enabledOverride = false
            let local = DigStore(context: ModelContext(container), discogsClient: discogs)
            local.portraitDefaults = dig.portraitDefaults
            page.off = rows(await local.artistProfile(name: name, mbid: nil, discogsID: id))

            let offKeys = Set(page.off.map { $0.discogsID.map { "d\($0)" } ?? "n" + RecordingKey.normalizeArtist($0.name) })
            for row in page.on {
                let key = row.discogsID.map { "d\($0)" } ?? "n" + RecordingKey.normalizeArtist(row.name)
                if offKeys.contains(key) { page.alsoLocal += 1 } else { page.gained += 1 }
            }
            // One artist twice: the same entry, or the same name once with an entry and once without.
            var byID: [Int: Int] = [:], byName: [String: Set<String>] = [:]
            for row in page.on {
                if let d = row.discogsID { byID[d, default: 0] += 1 }
                byName[RecordingKey.normalizeArtist(row.name), default: []].insert(row.discogsID.map(String.init) ?? "-")
            }
            page.duplicates = byID.filter { $0.value > 1 }.map { "entry \($0.key) x\($0.value)" }
                + byName.filter { $0.value.count > 1 }.map { "\($0.key): \($0.value.sorted().joined(separator: ","))" }
            let identityStore = ArtistIdentityStore(context: ModelContext(container))
            page.aliases = identityStore.facts(id)?.aliases.map(\.id) ?? []
            for row in page.on where row.discogsID.map(page.aliases.contains) == true
                && !row.kinds.contains(where: { $0 == "sameAlias" || $0 == "aliasOrProject" }) {
                page.aliasConfusion.append("\(row.name) \(row.discogsID!) \(row.kinds)")
            }
            for row in on.related {
                guard let target = row.discogsID else { continue }
                let opened = dig.artistPage(ArtistReference(name: row.name, discogsID: target))
                if opened.discogsID != target { page.navigationWrong.append("\(row.name): \(opened.discogsID.map(String.init) ?? "nil") for \(target)") }
            }
            report.pages.append(page)
            print("PILOT_LIVE \(name) on=\(page.on.count) off=\(page.off.count) gained=\(page.gained) first=\(page.firstRouteMs ?? -1) local=\(page.firstLocalRouteMs ?? -1) req=\(page.discogsRequests)")
        }

        let data = try JSONEncoder().encode(report)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalogue-pilot-live.json")
        try data.write(to: url)
        print("PILOT_LIVE_REPORT \(url.path)")
    }
}
