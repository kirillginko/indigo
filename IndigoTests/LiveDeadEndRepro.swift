//
//  LiveDeadEndRepro.swift
//  IndigoTests
//
//  The two dead ends reported from the phone, walked as the app walks them,
//  against live Discogs and R2, on a copy of this Mac's stores.
//
//  Opt-in: `INDIGO_LIVE_DEADENDS=1` (as `TEST_RUNNER_INDIGO_LIVE_DEADENDS=1`).
//  Report: `live-dead-ends.txt` in the host's temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class LiveDeadEndRepro: XCTestCase {
    func testTheReportedDeadEndsOpenTheirEntries() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_LIVE_DEADENDS"] == "1", "Live: set INDIGO_LIVE_DEADENDS=1.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("Development")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("DeadEnds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for name in ["UserData.store", "Local.store"] {
            for suffix in ["", "-wal", "-shm"] {
                let from = support.appendingPathComponent(name + suffix)
                if FileManager.default.fileExists(atPath: from.path) {
                    try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix))
                }
            }
        }
        let container = try Persistence.makeSplitContainer(
            userData: copy.appendingPathComponent("UserData.store"), local: copy.appendingPathComponent("Local.store"))
        let context = ModelContext(container)
        // Live, as the app is: the bundled credential and the public R2 copy,
        // which a test process otherwise never touches.
        let bundled = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "IndigoDiscogsToken") as? String)
        let client = DiscogsClient(transport: NetworkEnvironment.metadataSession, token: try XCTUnwrap(ObfuscatedSecret.reveal(bundled)))
        let dig = DigStore(context: context, discogsClient: client)
        dig.readStoredRelease = { id in
            guard let url = MetadataRepository.storedObjectURL(forPath: MetadataRepository.releasePath(id: String(id))),
                  let (data, response) = try? await URLSession.shared.data(from: url) else { return .unavailable }
            if (response as? HTTPURLResponse)?.statusCode == 404 { return .missing }
            return (try? JSONDecoder().decode(DiscogsReleaseDetail.self, from: data)).map { .document($0) } ?? .unavailable
        }
        var out: [String] = []

        func open(_ name: String, discogsID: Int? = nil) async -> ArtistProfile {
            await dig.enrichArtist(name: name, mbid: nil, discogsID: discogsID)
            return await dig.artistProfile(name: name, mbid: nil, discogsID: discogsID)
        }

        // 1. "Guillermo S. Herren", opened by the spelling alone.
        let herren = await open("Guillermo S. Herren")
        let herrenPage = dig.artistPage(ArtistReference(name: "Guillermo S. Herren"))
        let resolved = await open(herrenPage.name, discogsID: herrenPage.discogsID)
        out.append("Guillermo S. Herren: page entry \(herrenPage.discogsID.map(String.init) ?? "none"), opens as \(herrenPage.name), releases \(herren.releases.count) / as resolved \(resolved.releases.count)")

        // 2. Speedy J's page, its credit ids filled, then its "Oberman" link.
        _ = await open("Speedy J")
        let ids = GraphStore(context: context).releaseIDs(creditedTo: RecordingKey.normalizeArtist("Speedy J"))
        let sketches = try context.fetch(FetchDescriptor<DiscogsReleaseRecord>(predicate: #Predicate { $0.title == "Pedestrian Sketches" }))
        out.append("Speedy J's records: \(ids.count); Pedestrian Sketches \(sketches.map { "\($0.discogsID) by \($0.artistNames)" }) among them: \(sketches.contains { ids.contains($0.discogsID) }); credits held: \(sketches.map { ReleaseCreditStore(context: context).credits(releaseID: $0.discogsID) != nil })")
        await dig.backfillReleaseCredits(forArtist: "Speedy J")
        out.append("after backfill, credits held: \(sketches.map { ReleaseCreditStore(context: context).credits(releaseID: $0.discogsID)?.count ?? -1 })")
        let held = ReleaseCreditStore(context: context).entry(credited: "Oberman")
        out.append("Speedy J's records name 'Oberman' as entry \(held?.discogsID.map(String.init) ?? "none")")
        let walk = IdentityGraph(context: context).neighbourhood(of: .artist("Speedy J"))
        let link = walk.edges.all.first { $0.to.kind == .artist && ($0.to.discogsID == 7379925 || $0.reason.contains("Pedestrian Sketches") && $0.reason.hasPrefix("Mixed")) }
        out.append("edges naming Pedestrian Sketches: " + walk.edges.all.filter { $0.reason.contains("Pedestrian Sketches") }
            .map { "\($0.to.title) [\($0.to.id), id \($0.to.discogsID.map(String.init) ?? "-")] \($0.reason)" }.joined(separator: "; "))
        // And what the page's own lanes list, which is what is tapped.
        let related = DigEngine(context: context).relatedArtists(to: "Speedy J")
        out.append("page lanes: " + related.filter { $0.name.contains("Oberman") }.map { "\($0.name) id \($0.discogsID.map(String.init) ?? "-")" }.joined(separator: "; "))
        out.append("Speedy J → Oberman link: \(link.map { "\($0.reason), entry \($0.to.discogsID.map(String.init) ?? "none")" } ?? "absent")")
        let oberman = await open("Oberman", discogsID: link?.to.discogsID)
        let obermanPage = dig.artistPage(ArtistReference(name: link?.to.title ?? "Oberman", discogsID: link?.to.discogsID))
        let shown = await open(obermanPage.name, discogsID: obermanPage.discogsID)
        let onward = DigEngine(context: context).relatedArtists(to: obermanPage.name, discogsID: obermanPage.discogsID)
        out.append("Oberman: page entry \(obermanPage.discogsID.map(String.init) ?? "none") as \(obermanPage.name), releases \(shown.releases.count), routes on \(onward.count): \(onward.prefix(6).map(\.name).joined(separator: ", "))")
        // And by the spelling alone, as an older link would open it.
        let byName = await open("Oberman")
        out.append("Oberman by name alone: page entry \(dig.artistPage(ArtistReference(name: "Oberman")).discogsID.map(String.init) ?? "none"), releases \(byName.releases.count)")

        try out.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("live-dead-ends.txt"),
                                               atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(resolved.releases.count, 0, out.joined(separator: "\n"))
        XCTAssertEqual(obermanPage.discogsID, 7379925, out.joined(separator: "\n"))
        _ = oberman
    }
}
