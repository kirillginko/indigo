//
//  CataloguePilotMeasurement.swift
//  IndigoTests
//
//  The DIG catalogue pilot on real pages, against the live network: what 30
//  of the 300 dead-end artists' pages offer with the pilot off (at first paint,
//  and after the live Discogs enrichment opening the page does) and with it on
//  (cold, from disk, from memory). Opt-in: `TEST_RUNNER_INDIGO_MEASURE_PILOT=1`.
//
//  Every artist is opened in a fresh in-memory store: nobody's history, no
//  CloudKit, nothing kept. Writes `catalogue-pilot-pages.json` to the host's
//  temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class CataloguePilotMeasurement: XCTestCase {
    /// Every tenth of the 300, by Discogs id (supabase/functions/_shared/catalogue_pilot.ts).
    static let sample: [(Int, String)] = [
        (1212, "Rick White"), (65642, "John Wall"), (149284, "Remy Unger"), (236110, "The Legends"), (343258, "Virgo (8)"),
        (500146, "Greg Ward (2)"), (656630, "Maddzart"), (905358, "Quartetto Cetra"), (1094557, "Hong Chulki"),
        (1262401, "Y-Dresta"), (1535009, "Chris Liberator & Sterling Moss"), (1838167, "The Squires Of The Subterrain"),
        (2407754, "Willie Jolley"), (2599936, "Bobby Floyd (2)"), (2940588, "Slugbug (2)"), (3285198, "John Wholetrain"),
        (3918839, "Trig (4)"), (4489198, "La Division Technique"), (4868658, "Ryan De La Cruz"), (5369498, "Lewis OfMan"),
        (5851908, "Maga (6)"), (6185944, "Ty Da Dale"), (7041670, "Jeremy-Pastell"), (7705484, "Lehay"),
        (8195299, "Decent Rides"), (9467677, "Eyedoublecross"), (10801636, "Yung Xabo"), (11706239, "Kid Sportswear"),
        (12836132, "DJ Cali4it"), (15250716, "Che (38)"),
    ]

    struct Side: Codable {
        var related = 0
        var relatedByID = 0
        var labels = 0
        var ms = 0
    }
    struct Page: Codable {
        var discogsID = 0
        var name = ""
        var offFirstPaint = Side()
        var offAfterLiveEnrichment = Side()
        var onFirstPaint = Side()
        var onCold = Side()
        var onFromDisk = Side()
        var onFromMemory = Side()
        var pilotOutcome = ""
        var routes: [String] = []
        var navigationChecked = 0
        var navigationWrong: [String] = []
        var safety: [String] = []
    }
    struct Report: Codable {
        var pages: [Page] = []
        var fallback = ""
    }

    private func store() throws -> (ModelContainer, DigStore) {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let dig = DigStore(context: ModelContext(container))
        dig.portraitDefaults = UserDefaults(suiteName: "indigo.tests.pilot.\(UUID().uuidString)")!
        return (container, dig)
    }

    private func side(_ profile: ArtistProfile, ms: Int) -> Side {
        Side(related: profile.related.count, relatedByID: profile.related.filter { $0.discogsID != nil }.count,
             labels: profile.labels.count, ms: ms)
    }

    private func timed<T>(_ work: () async -> T) async -> (T, Int) {
        let started = ContinuousClock.now
        let value = await work()
        let elapsed = ContinuousClock.now - started
        return (value, Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
    }

    func testMeasureThePilotOnRealPages() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_MEASURE_PILOT"] == "1",
                          "Set TEST_RUNNER_INDIGO_MEASURE_PILOT=1 to measure the catalogue pilot on real pages.")
        let pilot = CataloguePilot.shared
        let disk = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-measure-\(UUID().uuidString)")
        pilot.directory = disk
        defer { pilot.enabledOverride = nil; pilot.reset() }
        var report = Report()

        for (id, discogsName) in Self.sample {
            let name = DiscogsClient.withoutDisambiguator(discogsName)
            var page = Page(discogsID: id, name: name)

            // Off: the page as DIG has it today.
            pilot.enabledOverride = false
            pilot.reset()
            do {
                let (container, dig) = try store()
                let (first, firstMs) = await timed { await dig.artistProfile(name: name, mbid: nil, discogsID: id) }
                page.offFirstPaint = side(first, ms: firstMs)
                let (_, enrichMs) = await timed { await dig.enrichArtist(name: name, mbid: nil, discogsID: id) }
                let after = await dig.artistProfile(name: name, mbid: nil, discogsID: id)
                page.offAfterLiveEnrichment = side(after, ms: enrichMs)
                _ = container
            }

            // On: cold (bundle from R2), then from disk (a later launch), then from memory.
            pilot.enabledOverride = true
            pilot.reset()
            let (container, dig) = try store()
            // First paint never waits on the pilot; then the time until the
            // bundle's routes are on the page.
            let (firstPaint, firstMs) = await timed { await dig.artistProfile(name: name, mbid: nil, discogsID: id) }
            page.onFirstPaint = side(firstPaint, ms: firstMs)
            let (cold, coldMs) = await timed {
                _ = await pilot.ensure(id)
                return await dig.artistProfile(name: name, mbid: nil, discogsID: id)
            }
            page.onCold = side(cold, ms: coldMs + firstMs)
            page.pilotOutcome = pilot.bundle(for: id) == nil ? "no bundle" : "bundle"
            pilot.reset()
            let (fromDisk, diskMs) = await timed {
                _ = await pilot.ensure(id)
                return await dig.artistProfile(name: name, mbid: nil, discogsID: id)
            }
            page.onFromDisk = side(fromDisk, ms: diskMs)
            let (memory, memoryMs) = await timed { await dig.artistProfile(name: name, mbid: nil, discogsID: id) }
            page.onFromMemory = side(memory, ms: memoryMs)

            // Every route opens its own entry; none is the artist, none twice, none from nowhere.
            let bundle = pilot.bundle(for: id)
            let named = Set((bundle?.collaborators.compactMap(\.artist.discogsID) ?? []) + (bundle?.credits.compactMap(\.artist.discogsID) ?? []))
            var seen = Set<Int>()
            for row in cold.related {
                page.routes.append("\(row.name) \(row.discogsID.map(String.init) ?? "-") \(row.reasons.first.map { String(describing: $0.kind) } ?? "")")
                guard let target = row.discogsID else { continue }
                if target == id { page.safety.append("own page offered: \(row.name)") }
                if !seen.insert(target).inserted { page.safety.append("twice: \(row.name) \(target)") }
                if !named.contains(target) { page.safety.append("not in the bundle: \(row.name) \(target)") }
                let opened = dig.artistPage(ArtistReference(name: row.name, discogsID: target))
                page.navigationChecked += 1
                if opened.discogsID != target { page.navigationWrong.append("\(row.name): opened \(opened.discogsID.map(String.init) ?? "nil"), wanted \(target)") }
            }
            _ = container
            report.pages.append(page)
        }

        // Fallback: an artist the pilot does not list.
        pilot.enabledOverride = true
        pilot.reset()
        let outside = await pilot.ensure(398459)
        report.fallback = "\(outside)"

        let data = try JSONEncoder().encode(report)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalogue-pilot-pages.json")
        try data.write(to: url)
        print("PILOT_REPORT \(url.path)")
    }
}
