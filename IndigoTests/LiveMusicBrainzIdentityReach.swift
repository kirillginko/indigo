//
//  LiveMusicBrainzIdentityReach.swift
//  IndigoTests
//
//  What `musicbrainz_discogs` links change, switch off against switch on,
//  through the live readers (`DiscogsIdentityRows`):
//
//  - DIG artist pages (Discover's own ask, without release lookups or the
//    device's collaborators) of the pilot artists and of the radio artists
//    played next to them: verified neighbours, offered tracks that play,
//    sparse pages, ids reached through two rows, cost.
//  - For You's radio pool (`ListenerRetrieval.radio`, then merge and rank) for
//    listeners made of ten of those artists each: candidates, identities,
//    merges, the top 25, cost.
//  - Determinism: switched on twice, on fresh caches, the same pools.
//
//  A play check is asked once and its answer reused by both sides, so the two
//  differ only by identity. Live and read-only.
//
//  Opt-in: `INDIGO_LIVE_MB_REACH=1`, with `pilot-dig-seeds.json` in the host's
//  temporary directory ({pilotRows, pilotSeeds, partnerSeeds}). Report:
//  `musicbrainz-identity-reach.txt` beside it.
//

import XCTest
@testable import Indigo

final class LiveMusicBrainzIdentityReach: XCTestCase {
    private struct Input: Decodable {
        struct Seed: Decodable { let discogs: Int; let name: String }
        let pilotRows: [UUID]
        let pilotSeeds: [Seed]
        let partnerSeeds: [Seed]
    }

    private actor Seen {
        var rows: [UUID: Int] = [:]
        func add(_ found: [UUID: (discogs: Int, name: String)]) { for (row, entry) in found { rows[row] = entry.discogs } }
    }

    private actor Plays {
        var memo: [String: Bool?] = [:]
        var asked = 0
        func check(_ source: DiscoveredTrack.Source) async -> Bool? {
            let key = String(describing: source)
            if let held = memo[key] { return held }
            asked += 1
            let answer = await TrackDiscoverySource.live.plays(source)
            memo[key] = answer
            return answer
        }
    }

    private struct Page {
        let seed: Int
        let report: TrackDiscoverySource.Report
        let offered: [String]
        let pilotOffered: Int
        let neighbours: [UUID: Int]
    }

    private struct Pool {
        let ranked: [String]
        let rowsOf: [String: Set<UUID>]
        let collisions: Int
        let report: ListenerRetrieval.RadioReport
    }

    override func tearDown() { DiscogsIdentityRows.override = nil }

    func testBeforeAndAfter() async throws {
        guard ProcessInfo.processInfo.environment["INDIGO_LIVE_MB_REACH"] == "1" else {
            throw XCTSkip("Live: set INDIGO_LIVE_MB_REACH=1.")
        }
        let dir = FileManager.default.temporaryDirectory
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: dir.appendingPathComponent("pilot-dig-seeds.json")))
        let pilot = Set(input.pilotRows)
        let pilotIDs = Set(input.pilotSeeds.map(\.discogs))
        let plays = Plays()

        func page(_ seed: Input.Seed) async -> Page {
            let seen = Seen()
            var source = TrackDiscoverySource.live
            let artists = source.artists
            source.artists = { rows in let found = try await artists(rows); await seen.add(found); return found }
            source.releaseVideos = { _, _ in [] }
            source.plays = { await plays.check($0) }
            source.cache = TrackDiscoveryCache()
            let ask = TrackDiscoverySource.Ask(seeds: [.init(discogsID: seed.discogs, name: seed.name, weight: 1)],
                                               knownArtists: [RecordingKey.normalizeArtist(seed.name)],
                                               limit: 5, ownTracks: 3)
            let (tracks, report) = await source.discover(ask)
            return Page(seed: seed.discogs, report: report, offered: tracks.map(\.id),
                        pilotOffered: tracks.filter { pilotIDs.contains($0.artistDiscogsID) && $0.artistDiscogsID != seed.discogs }.count,
                        neighbours: await seen.rows)
        }
        func pages(_ seeds: [Input.Seed]) async -> [Int: Page] {
            var out: [Int: Page] = [:]
            for chunk in stride(from: 0, to: seeds.count, by: 4).map({ Array(seeds.dropFirst($0).prefix(4)) }) {
                await withTaskGroup(of: Page.self) { group in
                    for seed in chunk { group.addTask { await page(seed) } }
                    for await result in group { out[result.seed] = result }
                }
            }
            return out
        }

        // For You: listeners of ten artists each, in a fixed order.
        func listeners(_ seeds: [Input.Seed]) -> [[Input.Seed]] {
            let sorted = seeds.sorted { $0.discogs < $1.discogs }
            return stride(from: 0, to: sorted.count, by: 10).map { Array(sorted.dropFirst($0).prefix(10)) }
        }
        let profile = ListenerProfile(asOf: Date(), units: [], clusters: [
            .init(id: 0, label: [], longTermShare: 1, recentShare: 1, emerging: false, examples: [], centroid: [:],
                  units: 10, evidence: 10, confidence: 1)
        ], emerging: [], coverage: [:], skips: 0, dismissals: 0)
        func pool(_ group: [Input.Seed]) async -> Pool {
            let seeds = group.map { ListenerRetrieval.Seed(artist: RecordingKey.normalizeArtist($0.name), name: $0.name, cluster: 0,
                                                           weight: 1, level: .artist, title: $0.name) }
            let ids = Dictionary(group.map { (RecordingKey.normalizeArtist($0.name), $0.discogs) }, uniquingKeysWith: { a, _ in a })
            let radio = await ListenerRetrieval.radio(seeds: seeds, discogsIDs: ids, profile: profile, vectors: [:],
                                                      knownKeys: Set(ids.keys), before: Date(), source: ListenerRetrieval.liveRadio,
                                                      perEpisode: 3)
            let names = Dictionary(seeds.map { ($0.artist, $0.name) }, uniquingKeysWith: { a, _ in a })
            let sightings = ListenerRetrieval.sightings(first: radio.first, second: radio.second, radio: radio.radio, seedNames: names)
            let merged = ListenerRetrieval.merge(sightings)
            let ranked = ListenerRetrieval.rank(merged.candidates, profile: profile, vectors: [:])
            var rowsOf: [String: Set<UUID>] = [:]
            var rowToDiscogs: [UUID: Int] = [:]
            for s in sightings { if let row = s.catalogueRow, let id = s.discogsID { rowToDiscogs[row] = id } }
            for s in sightings {
                guard let row = s.catalogueRow else { continue }
                let identity = (s.discogsID ?? rowToDiscogs[row]).map { "discogs:\($0)" } ?? "catalogue:\(row.uuidString.lowercased())"
                rowsOf[identity, default: []].insert(row)
            }
            return Pool(ranked: ranked.map(\.identity), rowsOf: rowsOf, collisions: merged.nameCollisions, report: radio.report)
        }
        func pools(_ groups: [[Input.Seed]]) async -> [Pool] {
            var out: [Pool] = []
            for group in groups { out.append(await pool(group)) }
            return out
        }

        let allPages = input.pilotSeeds + input.partnerSeeds
        let groups = listeners(input.partnerSeeds) + listeners(input.pilotSeeds)

        DiscogsIdentityRows.override = false
        let digOff = await pages(allPages)
        let forYouOff = await pools(groups)
        let digOffAgain = await pages(allPages)
        DiscogsIdentityRows.override = true
        let digOn = await pages(allPages)
        let forYouOn = await pools(groups)
        let digAgain = await pages(allPages)
        let forYouAgain = await pools(groups)

        var lines: [String] = []
        func median(_ values: [Double]) -> Double { let s = values.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        func describe(_ label: String, _ seeds: [Input.Seed]) {
            let off = seeds.compactMap { digOff[$0.discogs] }, on = seeds.compactMap { digOn[$0.discogs] }
            func pilotNeighbours(_ list: [Page]) -> (pages: Int, artists: Int) {
                let reached = list.map { page in Set(page.neighbours.filter { pilot.contains($0.key) && $0.value != page.seed }.keys) }
                return (reached.filter { !$0.isEmpty }.count, reached.reduce(into: Set<UUID>()) { $0.formUnion($1) }.count)
            }
            func line(_ name: String, _ list: [Page]) {
                let r = list.map(\.report)
                let sparse = list.filter { $0.offered.count < 3 }.count
                let reach = pilotNeighbours(list)
                let twoRows = list.map { Dictionary(grouping: $0.neighbours.values, by: { $0 }).filter { $0.value.count > 1 }.count }.reduce(0, +)
                lines.append(String(format: "  %@: on radio %d/%d; verified neighbours %d; pages with a pilot neighbour %d (%d pilot artists); offered %d (own %d, by pilot artists %d); sparse (<3) %d; ids on two rows %d; requests %d, failures %d; median %.0f ms",
                                    name, r.filter { $0.seedsOnRadio > 0 }.count, list.count, r.map(\.verifiedNeighbours).reduce(0, +),
                                    reach.pages, reach.artists, r.map(\.offered).reduce(0, +), r.map(\.own).reduce(0, +),
                                    list.map(\.pilotOffered).reduce(0, +), sparse, twoRows, r.map(\.requests).reduce(0, +),
                                    r.map(\.failures).reduce(0, +), median(r.map(\.milliseconds))))
            }
            lines.append("DIG artist pages, \(label) (\(seeds.count)):")
            line("off", off); line("on ", on)
            var rescued = 0, lost = 0, changed = 0, displaced = 0, added = 0
            for seed in seeds {
                guard let a = digOff[seed.discogs], let b = digOn[seed.discogs] else { continue }
                if a.offered.count < 3 && b.offered.count >= 3 { rescued += 1 }
                if b.offered.count < a.offered.count { lost += 1 }
                if a.offered != b.offered { changed += 1 }
                displaced += Set(a.offered).subtracting(b.offered).count
                added += Set(b.offered).subtracting(a.offered).count
            }
            lines.append("  sparse pages rescued (<3 → ≥3): \(rescued); pages offering fewer: \(lost); pages whose list changed: \(changed); tracks added \(added), displaced \(displaced)")
        }
        describe("of the pilot artists", input.pilotSeeds)
        describe("of radio neighbours of the pilot", input.partnerSeeds)

        lines.append("For You radio pools, \(groups.count) listeners of 10 (\(listeners(input.partnerSeeds).count) of neighbours, \(listeners(input.pilotSeeds).count) of pilot artists):")
        for (name, list) in [("off", forYouOff), ("on ", forYouOn)] {
            let candidates = list.map(\.ranked.count).reduce(0, +)
            let discogsKeyed = list.map { $0.ranked.filter { $0.hasPrefix("discogs:") }.count }.reduce(0, +)
            let pilotCandidates = list.map { pool in pool.ranked.filter { !(pool.rowsOf[$0] ?? []).isDisjoint(with: pilot) }.count }.reduce(0, +)
            let pilotDiscogs = list.map { pool in pool.ranked.filter { $0.hasPrefix("discogs:") && !(pool.rowsOf[$0] ?? []).isDisjoint(with: pilot) }.count }.reduce(0, +)
            let multiRow = list.map { $0.rowsOf.values.filter { $0.count > 1 }.count }.reduce(0, +)
            let top = list.map { pool in pool.ranked.prefix(25).filter { !(pool.rowsOf[$0] ?? []).isDisjoint(with: pilot) }.count }.reduce(0, +)
            lines.append(String(format: "  %@: seeds on radio %d; candidates %d (discogs-keyed %d); pilot candidates %d (discogs-keyed %d, in a top 25 %d); identities over two rows %d; name collisions %d; requests %d, failures %d; median %.0f ms",
                                name, list.map(\.report.seedsOnRadio).reduce(0, +), candidates, discogsKeyed, pilotCandidates, pilotDiscogs, top,
                                multiRow, list.map(\.collisions).reduce(0, +), list.map(\.report.requests).reduce(0, +),
                                list.map(\.report.failures).reduce(0, +), median(list.map(\.report.milliseconds))))
        }
        var overlap: [Double] = []
        for (a, b) in zip(forYouOff, forYouOn) {
            // By row, since an identity's key can change from catalogue: to discogs:.
            func rows(_ pool: Pool) -> [Set<UUID>] { pool.ranked.prefix(25).map { pool.rowsOf[$0] ?? [] } }
            let before = rows(a), after = rows(b)
            let kept = before.filter { set in after.contains { !$0.isDisjoint(with: set) } }.count
            overlap.append(before.isEmpty ? 1 : Double(kept) / Double(before.count))
        }
        lines.append(String(format: "  top 25 kept from off to on, by row: median %.0f%%, lowest %.0f%%", 100 * median(overlap), 100 * (overlap.min() ?? 1)))

        let digSame = allPages.filter { digOn[$0.discogs]?.neighbours == digAgain[$0.discogs]?.neighbours }.count
        let digTracksSame = allPages.filter { digOn[$0.discogs]?.offered == digAgain[$0.discogs]?.offered }.count
        let poolsSame = zip(forYouOn, forYouAgain).filter { $0.ranked == $1.ranked }.count
        lines.append("Determinism, switched on twice on fresh caches: DIG neighbour sets \(digSame)/\(allPages.count), offered lists \(digTracksSame)/\(allPages.count); For You ranked pools \(poolsSame)/\(groups.count)")
        let offSame = allPages.filter { digOff[$0.discogs]?.neighbours == digOffAgain[$0.discogs]?.neighbours }.count
        let offTracksSame = allPages.filter { digOff[$0.discogs]?.offered == digOffAgain[$0.discogs]?.offered }.count
        lines.append("Baseline, switched off twice: DIG neighbour sets \(offSame)/\(allPages.count), offered lists \(offTracksSame)/\(allPages.count)")
        for (label, a, b) in [("on", digOn, digAgain), ("off", digOff, digOffAgain)] {
            for seed in allPages {
                guard let x = a[seed.discogs], let y = b[seed.discogs], x.neighbours != y.neighbours || x.offered != y.offered else { continue }
                let rows = Set(x.neighbours.keys).symmetricDifference(y.neighbours.keys)
                lines.append("  \(label) differs: Discogs \(seed.discogs) (pilot \(pilotIDs.contains(seed.discogs))): neighbours \(x.neighbours.count) vs \(y.neighbours.count), \(rows.count) rows in one only, pilot among them \(!rows.isDisjoint(with: pilot)); offered \(x.offered.count) vs \(y.offered.count); verified \(x.report.verifiedNeighbours) vs \(y.report.verifiedNeighbours); failures \(x.report.failures)/\(y.report.failures)")
            }
        }
        lines.append("Play checks asked: \(await plays.asked) (each once, shared by both sides)")
        let report = lines.joined(separator: "\n")
        print(report)
        try report.write(to: dir.appendingPathComponent("musicbrainz-identity-reach.txt"), atomically: true, encoding: .utf8)
    }
}
