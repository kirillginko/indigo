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
//  Release recordings are looked up as an artist page does (the backend's
//  shelf cache and R2 release documents, never Discogs itself), each artist
//  once, shared by both sides.
//
//  `testRealListener` does the same for this Mac's own listener, on a copy of
//  its stores: For You's "Tracks to hear" (Discover's ask, twelve starting
//  points) and the For You mix (`ClusterSeedPicks.picks`, with R2 bundles),
//  then the mix with radio candidates (`ForYouRadioCandidatesFeature`) off
//  against on.
//
//  Opt-in: `INDIGO_LIVE_MB_REACH=1`, with the input in the host's temporary
//  directory ({pilotRows, pilotSeeds, partnerSeeds}; `INDIGO_MB_REACH_INPUT`,
//  default `pilot-dig-seeds.json`). Reports `mb-reach-<input>.txt` and
//  `mb-reach-listener.txt` beside it.
//

import XCTest
import SwiftData
import Supabase
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

    private actor Releases {
        var memo: [Int: [TrackDiscovery.Appearance]] = [:]
        func tracks(_ id: Int, _ name: String) async -> [TrackDiscovery.Appearance] {
            if let held = memo[id] { return held }
            let found = await ReleaseVideoTracks.live.tracks(artistID: id, artist: name)
            memo[id] = found
            return found
        }
    }

    private static var inputName: String { ProcessInfo.processInfo.environment["INDIGO_MB_REACH_INPUT"] ?? "pilot-dig-seeds.json" }

    /// Whether R2 publishes a knowledge bundle for each id: references only.
    private static func bundleRefs(_ ids: [Int]) async -> (found: Int, missing: Int, failed: Int) {
        var found = 0, missing = 0, failed = 0
        for chunk in stride(from: 0, to: ids.count, by: 8).map({ Array(ids.dropFirst($0).prefix(8)) }) {
            let statuses = await withTaskGroup(of: Int.self) { group in
                for id in chunk { group.addTask { (try? await BundleFetcher.live("knowledge/v1/refs/artists/\(id).json").status) ?? 0 } }
                var out: [Int] = []
                for await status in group { out.append(status) }
                return out
            }
            for status in statuses { if status == 200 { found += 1 } else if status == 404 || status == 403 { missing += 1 } else { failed += 1 } }
        }
        return (found, missing, failed)
    }

    private struct Page {
        let seed: Int
        let report: TrackDiscoverySource.Report
        let offered: [String]
        let pilotOffered: Int
        let fromReleases: Int
        let neighbours: [UUID: Int]
    }

    private struct Pool {
        let ranked: [String]
        let rowsOf: [String: Set<UUID>]
        let collisions: Int
        let report: ListenerRetrieval.RadioReport
    }

    override func tearDown() {
        DiscogsIdentityRows.override = nil; ForYouRadioCandidatesFeature.override = nil; ClusterSeedPicks.radioShare = 0.5
    }

    private static func ms(since started: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - started
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// The mix's arms, on one listener's inputs: A today's mix (radio off),
    /// B radio candidates with the identity switch off, C with it on, and C
    /// at a quarter and at a whole radio share (one common ranking). Play
    /// checks shared, so arms differ by candidates only. `later`: artists the
    /// listener met after the inputs' cut-off, for finds.
    private func radioArms(inputs: ClusterSeedPicks.Inputs, credits: [String: [ListenerRetrieval.Credit]],
                           bundles held: [String: (id: Int, bundle: ArtistBundle)],
                           fetchBundles: @escaping @Sendable ([Int]) async -> [Int: ArtistBundle],
                           linkedIDs: Set<Int>, plays: Plays, source: (Bool) -> ListenerRetrieval.RadioSource,
                           later: Set<String>?) async -> (lines: [String], finds: [String: [Int: Int]]) {
        struct Arm { let name: String; let radio: Bool; let identity: Bool; let share: Double }
        let armList = [Arm(name: "A  today's mix", radio: false, identity: false, share: 0.5),
                       Arm(name: "B  radio, no MB links", radio: true, identity: false, share: 0.5),
                       Arm(name: "C  radio + MB links", radio: true, identity: true, share: 0.5),
                       Arm(name: "C¼ radio share 0.25", radio: true, identity: true, share: 0.25),
                       Arm(name: "C1 one common ranking", radio: true, identity: true, share: 1.0)]
        func idOf(_ c: ListenerRetrieval.Candidate) -> Int? { Int(c.identity.dropFirst("discogs:".count)) }
        func key(_ name: String) -> String { RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(name)) }
        var lines: [String] = [], finds: [String: [Int: Int]] = [:]
        var basePool = Set<Int>(), baseTop20: [String] = [], basePicks: [Int: [String]] = [:]
        var radioMemo: [String: (ClusterSeedPicks.RadioCandidates, Double)] = [:]
        for arm in armList {
            DiscogsIdentityRows.override = arm.identity
            ForYouRadioCandidatesFeature.override = arm.radio
            ClusterSeedPicks.radioShare = arm.share
            var picker = ClusterSeedPicks()
            picker.store = nil
            picker.plays = { await plays.check($0) }
            picker.bundles = fetchBundles
            picker.radio = source(arm.identity)
            var radio = ClusterSeedPicks.RadioCandidates(), radioMs = 0.0
            if arm.radio {
                if let held = radioMemo["\(arm.identity)"] { (radio, radioMs) = held } else {
                    let started = ContinuousClock.now
                    radio = await picker.radioCandidates(inputs)
                    radioMs = Self.ms(since: started)
                    radioMemo["\(arm.identity)"] = (radio, radioMs)
                }
            }
            let pool = ClusterSeedPicks.ranked(inputs, credits: credits, excluding: [], bundles: held, radio: radio, radioShare: 1, limit: 10_000)
            let ranked = ClusterSeedPicks.ranked(inputs, credits: credits, excluding: [], bundles: held, radio: radio, radioShare: arm.share)
            let poolIDs = Set(pool.compactMap(idOf))
            let top20 = ranked.prefix(20).map(\.name)
            if !arm.radio { basePool = poolIDs; baseTop20 = top20 }
            let sightingIDs = Set(radio.sightings.compactMap(\.discogsID))
            let rowsPerID = Dictionary(grouping: radio.sightings.filter { $0.discogsID != nil }, by: { $0.discogsID! }).filter { Set($0.value.compactMap(\.catalogueRow)).count > 1 }
            let nameClashes = Dictionary(grouping: pool, by: \.nameKey).filter { $0.value.count > 1 }.count
            lines.append(arm.name + ":")
            if arm.radio {
                lines.append(String(format: "    radio: seeds on radio %d; sightings %d (%d Discogs ids, %d linked); left out: %d rows without a Discogs id, %d one-offs at a distance; requests %d, failures %d; %.0f ms",
                                    radio.report.seedsOnRadio, radio.sightings.count, sightingIDs.count, sightingIDs.filter(linkedIDs.contains).count,
                                    radio.unverified, radio.weak, radio.report.requests, radio.report.failures, radioMs))
            }
            let radioTop = ranked.filter { ClusterSeedPicks.isRadioOnly($0) }
            lines.append("    pool \(pool.count) (new musicians vs A \(poolIDs.subtracting(basePool).count), linked \(poolIDs.filter(linkedIDs.contains).count)); ranked 40: \(ranked.count), radio alone \(radioTop.count), linked \(ranked.filter { idOf($0).map(linkedIDs.contains) ?? false }.count); Discogs ids on two rows \(rowsPerID.count), names on two identities \(nameClashes)")
            if arm.radio {
                let added = top20.filter { !baseTop20.contains($0) }, dropped = baseTop20.filter { !top20.contains($0) }
                lines.append("    top 20 vs A: \(added.count) in (\(added.joined(separator: ", "))); out: \(dropped.joined(separator: ", "))")
            }
            let clusterOf = Dictionary(ranked.compactMap { c in idOf(c).map { ($0, c.best.cluster) } }, uniquingKeysWith: { a, _ in a })
            for limit in [8, 20] {
                let started = ContinuousClock.now
                let before = await plays.asked
                let picks = await picker.picks(inputs, excluding: [], limit: limit)
                let ms = Self.ms(since: started)
                let again = arm.radio && arm.share == 0.5 ? await picker.picks(inputs, excluding: [], limit: limit) : picks
                let recordings = picks.filter(\.isRecording).count
                let artists = picks.map(\.artistDiscogsID)
                let ids = picks.map(\.id)
                let found = later.map { set in Set(picks.map { key($0.artist) }).intersection(set) } ?? []
                finds[arm.name, default: [:]][limit] = found.count
                if !arm.radio { basePicks[limit] = ids }
                let kept = Set(ids).intersection(basePicks[limit] ?? []).count
                lines.append(String(format: "    limit %2d: %d picks (%d recordings, %d radio moments); linked %d; reached by radio %d; new musicians vs A's pool %d; clusters %d; repeated artists %d, repeated tracks %d; kept from A %d; deterministic %@; play checks +%d; %.0f ms",
                                    limit, picks.count, recordings, picks.count - recordings, artists.filter(linkedIDs.contains).count,
                                    picks.filter { $0.reason.hasPrefix("Played ") }.count, Set(artists).subtracting(basePool).count,
                                    Set(artists.compactMap { clusterOf[$0] }).count, artists.count - Set(artists).count, ids.count - Set(ids).count,
                                    kept, ids == again.map(\.id) ? "yes" : "NO", await plays.asked - before, ms)
                             + (later == nil ? "" : "; finds \(found.count): \(found.sorted().joined(separator: ", "))"))
                lines.append("      " + picks.map { "\(linkedIDs.contains($0.artistDiscogsID) ? "◆ " : "")\($0.artist) — \($0.title) [\($0.isRecording ? "Play Track" : "Hear in Radio Show")] \($0.reason)" }.joined(separator: " | "))
            }
        }
        DiscogsIdentityRows.override = nil
        ForYouRadioCandidatesFeature.override = nil
        ClusterSeedPicks.radioShare = 0.5
        return (lines, finds)
    }

    func testBeforeAndAfter() async throws {
        guard ProcessInfo.processInfo.environment["INDIGO_LIVE_MB_REACH"] == "1" else {
            throw XCTSkip("Live: set INDIGO_LIVE_MB_REACH=1.")
        }
        let dir = FileManager.default.temporaryDirectory
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: dir.appendingPathComponent(Self.inputName)))
        let pilot = Set(input.pilotRows)
        let pilotIDs = Set(input.pilotSeeds.map(\.discogs))
        let plays = Plays()
        let releases = Releases()
        let refs = await Self.bundleRefs(input.pilotSeeds.map(\.discogs).sorted())

        func page(_ seed: Input.Seed) async -> Page {
            let seen = Seen()
            var source = TrackDiscoverySource.live
            let artists = source.artists
            source.artists = { rows in let found = try await artists(rows); await seen.add(found); return found }
            source.releaseVideos = { await releases.tracks($0, $1) }
            source.plays = { await plays.check($0) }
            source.cache = TrackDiscoveryCache()
            let ask = TrackDiscoverySource.Ask(seeds: [.init(discogsID: seed.discogs, name: seed.name, weight: 1)],
                                               knownArtists: [RecordingKey.normalizeArtist(seed.name)],
                                               limit: 5, ownTracks: 3, releaseLookups: 3)
            let (tracks, report) = await source.discover(ask)
            return Page(seed: seed.discogs, report: report, offered: tracks.map(\.id),
                        pilotOffered: tracks.filter { pilotIDs.contains($0.artistDiscogsID) && $0.artistDiscogsID != seed.discogs }.count,
                        fromReleases: report.releaseVideos, neighbours: await seen.rows)
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

        var lines: [String] = ["Input \(Self.inputName): \(input.pilotRows.count) linked rows, \(input.pilotSeeds.count) readable as seeds, \(input.partnerSeeds.count) radio neighbours with a Discogs entry",
                               "R2 knowledge bundles for the linked Discogs ids: \(refs.found) published, \(refs.missing) none, \(refs.failed) unreadable"]
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
                lines.append(String(format: "  %@: on radio %d/%d; verified neighbours %d; pages with a pilot neighbour %d (%d pilot artists); offered %d (own %d, by pilot artists %d, release recordings found %d); sparse (<3) %d; ids on two rows %d; requests %d, failures %d; median %.0f ms",
                                    name, r.filter { $0.seedsOnRadio > 0 }.count, list.count, r.map(\.verifiedNeighbours).reduce(0, +),
                                    reach.pages, reach.artists, r.map(\.offered).reduce(0, +), r.map(\.own).reduce(0, +),
                                    list.map(\.pilotOffered).reduce(0, +), list.map(\.fromReleases).reduce(0, +), sparse, twoRows, r.map(\.requests).reduce(0, +),
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
        let stem = (Self.inputName as NSString).deletingPathExtension
        try report.write(to: dir.appendingPathComponent("mb-reach-\(stem).txt"), atomically: true, encoding: .utf8)
    }

    /// The shared catalogue as it stood at a cut-off: identity links and
    /// radio appearances created before it, episodes aired before it.
    /// Programme counts (hub damping) are today's: a mild leak, damping only.
    private static func datedRadio(before cutoff: Date, identity on: Bool) -> ListenerRetrieval.RadioSource {
        let stamp = ISO8601DateFormatter().string(from: cutoff)
        var source = ListenerRetrieval.liveRadio
        source.rowsByName = { _ in [:] }
        source.rows = { ids in
            let client = try SupabaseService.requireClient()
            let links: [DiscogsIdentityRows.Link] = try await DiscogsIdentityRows.providerFilter(
                client.from("external_ids").select("entity_id,provider,external_id"), enabled: on)
                .eq("entity_type", value: "artist").in("external_id", values: ids.map(String.init))
                .lt("created_at", value: stamp).limit(200).execute().value
            guard on else { return DiscogsIdentityRows.arrivingRows(byDiscogs: links) }
            let linked = Set(links.filter { $0.provider != "discogs" }.map(\.entity_id))
            guard !linked.isEmpty else { return DiscogsIdentityRows.rows(byDiscogs: links) }
            let others: [DiscogsIdentityRows.Link] = try await client.from("external_ids").select("entity_id,provider,external_id")
                .eq("provider", value: "musicbrainz_discogs").eq("entity_type", value: "artist")
                .in("entity_id", values: linked.map(\.uuidString)).lt("created_at", value: stamp).limit(400).execute().value
            let asked = Set(ids)
            return DiscogsIdentityRows.rows(byDiscogs: links + others.filter { !links.contains($0) }).filter { asked.contains($0.key) }
        }
        source.appearances = { row, given in
            let client = try SupabaseService.requireClient()
            struct Raw: Decodable {
                struct Episode: Decodable {
                    struct Show: Decodable { let title: String? }
                    let id: UUID; let aired_at: Date?; let radio_show_id: UUID?; let genres: [String]?; let radio_shows: Show?
                }
                let track_index: Int?
                let radio_episodes: Episode?
            }
            let before = ISO8601DateFormatter().string(from: min(given, cutoff))
            let raw: [Raw] = try await client.from("radio_appearances")
                .select("track_index,radio_episodes!inner(id,aired_at,radio_show_id,genres,radio_shows(title))")
                .eq("artist_id", value: row.uuidString).lt("radio_episodes.aired_at", value: before).lt("created_at", value: stamp)
                .order("radio_episode_id").order("track_index").limit(200).execute().value
            return raw.compactMap { r in
                guard let e = r.radio_episodes, let aired = e.aired_at, let index = r.track_index else { return nil }
                return (ListenerRetrieval.Radio.Episode(id: e.id, show: e.radio_show_id, showTitle: e.radio_shows?.title, aired: aired, genres: e.genres ?? []), index)
            }
        }
        source.tracklists = { episodes in
            let client = try SupabaseService.requireClient()
            struct Raw: Decodable { let radio_episode_id: UUID; let track_index: Int?; let artist_id: UUID? }
            let raw: [Raw] = try await client.from("radio_appearances").select("radio_episode_id,track_index,artist_id")
                .in("radio_episode_id", values: episodes.map(\.uuidString)).lt("created_at", value: stamp)
                .order("radio_episode_id").order("track_index").limit(1000).execute().value
            var out: [UUID: [ListenerRetrieval.Radio.Slot]] = [:]
            for r in raw { if let artist = r.artist_id, let index = r.track_index { out[r.radio_episode_id, default: []].append(.init(index: index, artist: artist)) } }
            return out
        }
        source.names = { rows in
            let client = try SupabaseService.requireClient()
            struct Name: Decodable { let id: UUID; let name: String }
            let values = rows.map(\.uuidString)
            async let links: [DiscogsIdentityRows.Link] = DiscogsIdentityRows.providerFilter(
                client.from("external_ids").select("entity_id,provider,external_id"), enabled: on).eq("entity_type", value: "artist")
                .in("entity_id", values: values).lt("created_at", value: stamp).limit(1000).execute().value
            async let names: [Name] = client.from("artists").select("id,name").in("id", values: values).limit(1000).execute().value
            let linked = try await links
            let discogs = on ? DiscogsIdentityRows.discogs(byRow: linked) : DiscogsIdentityRows.smallestDiscogs(byRow: linked)
            var out: [UUID: (name: String, discogs: Int?)] = [:]
            for row in try await names { out[row.id] = (row.name, discogs[row.id]) }
            return out
        }
        return source
    }

    /// The arms over dated cut-offs of this Mac's history: the listener as
    /// they were, the catalogue as it was (`datedRadio`), and finds -- artists
    /// first met after the cut-off. "C, today's links" uses links made since:
    /// not a prospective result, shown only to bound what the links could do.
    func testRadioCandidatesOverCutoffs() async throws {
        guard ProcessInfo.processInfo.environment["INDIGO_LIVE_MB_REACH"] == "1" else {
            throw XCTSkip("Live: set INDIGO_LIVE_MB_REACH=1.")
        }
        let dir = FileManager.default.temporaryDirectory
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: dir.appendingPathComponent(Self.inputName)))
        let linkedIDs = Set(input.pilotSeeds.map(\.discogs))
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = dir.appendingPathComponent("MBCutoffs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for (folder, name) in [(support, "UserData.store"), (support.appendingPathComponent("Development"), "Local.store")] {
            for suffix in ["", "-wal", "-shm"] {
                let from = folder.appendingPathComponent(name + suffix)
                if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix)) }
            }
        }
        let container = try Persistence.makeSplitContainer(userData: copy.appendingPathComponent("UserData.store"),
                                                           local: copy.appendingPathComponent("Local.store"))
        let context = ModelContext(container)
        func key(_ name: String) -> String { RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(name)) }
        let allRecords = try context.fetch(FetchDescriptor<DiscogsReleaseRecord>()).map(RecordProfile.init(record:))
        let allRows = try context.fetch(FetchDescriptor<DiscogsArtist>())
        let visits = try context.fetch(FetchDescriptor<DigVisit>())
        let everything = PersonalInputs.read(context: context, asOf: .distantFuture)
        let last = (everything.crate.map(\.addedAt) + everything.met.map(\.lastAt)).max() ?? Date()
        let whole = ListenerProfile.read(context: context)
        let plays = Plays(), bundles = Bundles()
        var lines = ["Radio candidates over dated cut-offs (last activity \(last.formatted(date: .abbreviated, time: .shortened)))"]
        var totals: [String: [Int: Int]] = [:]
        for days in [21, 14, 10, 7] {
            let cutoff = last.addingTimeInterval(-Double(days) * 86_400)
            let openedLater = Set(visits.filter { $0.kind == .artist && $0.firstVisitedAt >= cutoff }.map { key($0.title) })
            let datedRows = allRows.filter { $0.fetchedAt < cutoff && !openedLater.contains($0.nameKey) }
            let rowByKey = Dictionary(datedRows.map { ($0.nameKey, $0) }, uniquingKeysWith: { a, _ in a })
            var onDevice = Set<Int>()
            for visit in visits where visit.firstVisitedAt < cutoff && visit.kind == .release { if let id = visit.discogsID { onDevice.insert(id) } }
            for row in datedRows { onDevice.formUnion(row.releaseDiscogsIDs) }
            let datedPool = allRecords.filter { onDevice.contains($0.id) }
            let vectors = RecordSimilarity(pool: datedPool).vectors
            let book = ListenerRetrieval.StyleBook(entries: datedRows.map { (key: $0.nameKey, id: $0.discogsID, styles: $0.styles) },
                                                   records: datedPool, vectors: vectors)
            var pastRead = ListenerProfile.read(context: context, before: cutoff)
            pastRead.artistStyles = pastRead.artistStyles.filter { rowByKey[$0.key] != nil }
            let past = ListenerProfile.build(evidence: pastRead.evidence, styles: pastRead.styles, artistStyles: pastRead.artistStyles,
                                             vectors: vectors, asOf: cutoff)
            let knownIDs = Set(pastRead.evidence.compactMap { pastRead.sameArtist[$0.artist] })
            var known = Set(pastRead.evidence.map(\.artist))
            known.formUnion(whole.sameArtist.filter { knownIDs.contains($0.value) }.keys)
            let later = Set(whole.evidence.filter { $0.at >= cutoff && $0.signal.weight > 0 }.map(\.artist)).subtracting(known)
            let seeds = ListenerRetrieval.seeds(past, vectors: vectors)
            var entries: [String: ListenerRetrieval.Entry] = [:]
            var releaseIDs: [String: (seed: Int, releases: [Int])] = [:]
            for seed in seeds {
                guard let row = rowByKey[seed.artist] else { continue }
                entries[seed.artist] = .init(key: row.nameKey, name: row.name, collaborators: row.collaboratorNames, members: row.memberNames,
                                             groups: row.groupNames, labelNeighbours: row.labelNeighbourNames,
                                             styleNeighbours: row.styleNeighbourNames, aliases: row.aliasNames)
                if row.discogsID > 0 { releaseIDs[seed.artist] = (row.discogsID, Array(row.releaseDiscogsIDs.prefix(6))) }
            }
            let inputs = ClusterSeedPicks.Inputs(profile: past, vectors: vectors, seeds: seeds, entries: entries, releaseIDs: releaseIDs,
                                                 book: book, known: known)
            guard !past.clusters.isEmpty else { lines.append("== \(days)d: no profile"); continue }
            var credits: [String: [ListenerRetrieval.Credit]] = [:]
            for (artist, held) in inputs.releaseIDs {
                var all: [ListenerRetrieval.Credit] = []
                for id in held.releases { if let document = await ClusterSeedPicks.live.release(id) { all += ListenerRetrieval.credits(seedID: nil, releases: [document]) } }
                credits[artist] = all.filter { $0.id != held.seed }
            }
            let seedIDs = inputs.releaseIDs.values.map(\.seed).sorted()
            let found = await bundles.bundles(seedIDs)
            var heldBundles: [String: (id: Int, bundle: ArtistBundle)] = [:]
            for (artist, ids) in inputs.releaseIDs { if let bundle = found[ids.seed] { heldBundles[artist] = (ids.seed, bundle) } }
            lines.append("== cut-off \(days)d (\(cutoff.formatted(date: .abbreviated, time: .shortened))): \(later.count) later artists; seeds \(seeds.count) over \(past.clusters.count) clusters, \(seedIDs.count) with a Discogs entry")
            let arms = await radioArms(inputs: inputs, credits: credits, bundles: heldBundles, fetchBundles: { await bundles.bundles($0) },
                                       linkedIDs: linkedIDs, plays: plays, source: { Self.datedRadio(before: cutoff, identity: $0) }, later: later)
            lines += arms.lines
            // Bounding only: the links made since, on the dated catalogue otherwise.
            DiscogsIdentityRows.override = true
            ForYouRadioCandidatesFeature.override = true
            var leaky = ClusterSeedPicks()
            leaky.store = nil
            leaky.plays = { await plays.check($0) }
            leaky.bundles = { await bundles.bundles($0) }
            var today = Self.datedRadio(before: cutoff, identity: true)
            today.names = ListenerRetrieval.liveRadio.names
            today.rows = RadioListenFinder.live.rows
            leaky.radio = today
            for limit in [8, 20] {
                let picks = await leaky.picks(inputs, excluding: [], limit: limit)
                let hits = Set(picks.map { key($0.artist) }).intersection(later)
                totals["C† today's links (leaks)", default: [:]][limit, default: 0] += hits.count
                lines.append("C† today's links (leaks, bound only), limit \(limit): \(picks.count) picks, linked \(picks.filter { linkedIDs.contains($0.artistDiscogsID) }.count), finds \(hits.count): \(hits.sorted().joined(separator: ", "))")
            }
            DiscogsIdentityRows.override = nil
            ForYouRadioCandidatesFeature.override = nil
            for (arm, byLimit) in arms.finds { for (limit, n) in byLimit { totals[arm, default: [:]][limit, default: 0] += n } }
        }
        lines.insert(contentsOf: ["Finds summed over the cut-offs (artists first met after the cut-off, among the picks):"]
                     + totals.sorted { $0.key < $1.key }.map { "  \($0.key): limit 8 \($0.value[8] ?? 0), limit 20 \($0.value[20] ?? 0)" }, at: 1)
        lines.append("Play checks asked: \(await plays.asked)")
        let report = lines.joined(separator: "\n")
        print(report)
        try report.write(to: dir.appendingPathComponent("mb-reach-cutoffs.txt"), atomically: true, encoding: .utf8)
    }

    private actor Bundles {
        var cache = BundleCache()
        func bundles(_ ids: [Int]) async -> [Int: ArtistBundle] {
            var held = cache
            _ = await BundleFetcher.refresh(&held, discogsIDs: ids, now: Date())
            cache = held
            var out: [Int: ArtistBundle] = [:]
            for id in ids { if let digest = held.refs[String(id)]?.ref?.digest, let bundle = held.bundles[digest] { out[id] = bundle } }
            return out
        }
    }

    private actor Asked {
        var found: [Int: [UUID]] = [:]
        func add(_ more: [Int: [UUID]], asked: [Int]) { for id in asked { found[id] = more[id] ?? [] } }
    }

    /// This Mac's own listener, on a copy of its stores, switch off against on.
    func testRealListener() async throws {
        guard ProcessInfo.processInfo.environment["INDIGO_LIVE_MB_REACH"] == "1" else {
            throw XCTSkip("Live: set INDIGO_LIVE_MB_REACH=1.")
        }
        let dir = FileManager.default.temporaryDirectory
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: dir.appendingPathComponent(Self.inputName)))
        let linkedRows = Set(input.pilotRows)
        let linkedIDs = Set(input.pilotSeeds.map(\.discogs))

        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = dir.appendingPathComponent("MBReach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for (folder, name) in [(support, "UserData.store"), (support.appendingPathComponent("Development"), "Local.store")] {
            for suffix in ["", "-wal", "-shm"] {
                let from = folder.appendingPathComponent(name + suffix)
                if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix)) }
            }
        }
        let container = try Persistence.makeSplitContainer(userData: copy.appendingPathComponent("UserData.store"),
                                                           local: copy.appendingPathComponent("Local.store"))
        let context = ModelContext(container)
        let plays = Plays(), releases = Releases()
        var lines: [String] = ["This Mac's listener, store copy; linked: \(input.pilotRows.count) rows, \(linkedIDs.count) Discogs ids (\(Self.inputName))"]

        // For You "Tracks to hear": Discover's own ask.
        let discover = DigStore.discoverInputs(context: context, collaborators: true)
        lines.append("Tracks to hear: \(discover.seeds.count) starting points (\(discover.seeds.filter { linkedIDs.contains($0.discogsID) }.count) of them linked artists), \(discover.collaborators.count) collaborators")
        func hear() async -> (tracks: [DiscoveredTrack], report: TrackDiscoverySource.Report, neighbours: [UUID: Int]) {
            let seen = Seen()
            var source = TrackDiscoverySource.live
            let artists = source.artists
            source.artists = { rows in let found = try await artists(rows); await seen.add(found); return found }
            source.releaseVideos = { await releases.tracks($0, $1) }
            source.plays = { await plays.check($0) }
            source.cache = TrackDiscoveryCache()
            let ask = TrackDiscoverySource.Ask(seeds: discover.seeds, collaborators: discover.collaborators, taste: discover.taste,
                                               knownArtists: discover.knownArtists, knownTracks: discover.knownTracks,
                                               limit: 12, releaseLookups: 2)
            let (tracks, report) = await source.discover(ask)
            return (tracks, report, await seen.rows)
        }
        DiscogsIdentityRows.override = false
        let hearOff = await hear()
        DiscogsIdentityRows.override = true
        let hearOn = await hear(), hearAgain = await hear()
        for (name, run) in [("off", hearOff), ("on ", hearOn)] {
            let linkedNeighbours = run.neighbours.keys.filter(linkedRows.contains).count
            lines.append(String(format: "  %@: seeds on radio %d; verified neighbours %d (linked %d); offered %d (by linked artists %d, release recordings found %d); requests %d, failures %d; %.0f ms",
                                name, run.report.seedsOnRadio, run.report.verifiedNeighbours, linkedNeighbours, run.tracks.count,
                                run.tracks.filter { linkedIDs.contains($0.artistDiscogsID) }.count, run.report.releaseVideos,
                                run.report.requests, run.report.failures, run.report.milliseconds))
        }
        let offIDs = hearOff.tracks.map(\.id), onIDs = hearOn.tracks.map(\.id)
        lines.append("  list changed: \(offIDs != onIDs); added \(Set(onIDs).subtracting(offIDs).count), displaced \(Set(offIDs).subtracting(onIDs).count); on twice identical: \(onIDs == hearAgain.tracks.map(\.id) && hearOn.neighbours == hearAgain.neighbours)")

        // The For You mix: Listener Profile v2 cluster seeds.
        guard let inputs = ClusterSeedPicks.inputs(context: context, vectors: [:]) else {
            lines.append("For You mix: no inputs")
            try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("mb-reach-listener.txt"), atomically: true, encoding: .utf8)
            return
        }
        let bundles = Bundles()
        let seedIDs = inputs.releaseIDs.values.map(\.seed).sorted()
        let seedBundles = await bundles.bundles(seedIDs)
        lines.append("For You mix: \(inputs.seeds.count) seeds over \(inputs.profile.clusters.count) clusters, \(seedIDs.count) with a Discogs entry (\(seedIDs.filter(linkedIDs.contains).count) linked), \(seedBundles.count) with an R2 bundle")
        // The candidate pool, as `picks` builds it: credits on the seeds' own releases, and bundles.
        var credits: [String: [ListenerRetrieval.Credit]] = [:]
        for (artist, held) in inputs.releaseIDs {
            var all: [ListenerRetrieval.Credit] = []
            for id in held.releases { if let document = await ClusterSeedPicks.live.release(id) { all += ListenerRetrieval.credits(seedID: nil, releases: [document]) } }
            credits[artist] = all.filter { $0.id != held.seed }
        }
        var heldBundles: [String: (id: Int, bundle: ArtistBundle)] = [:]
        for (artist, ids) in inputs.releaseIDs { if let bundle = seedBundles[ids.seed] { heldBundles[artist] = (ids.seed, bundle) } }
        let pool = ClusterSeedPicks.ranked(inputs, credits: credits, excluding: [], bundles: heldBundles, limit: 10_000)
        func idOf(_ c: ListenerRetrieval.Candidate) -> Int? { Int(c.identity.dropFirst("discogs:".count)) }
        let bundleIDs = Set(ListenerRetrieval.bundled(inputs.seeds, bundles: heldBundles, names: inputs.entries.mapValues(\.name)).compactMap(\.discogsID))
        let linkedInPool = pool.filter { idOf($0).map(linkedIDs.contains) ?? false }
        lines.append("  candidates \(pool.count) (named by a bundle \(pool.filter { idOf($0).map(bundleIDs.contains) ?? false }.count)); linked artists among them \(linkedInPool.count), in the top 25 \(pool.prefix(25).filter { idOf($0).map(linkedIDs.contains) ?? false }.count): \(pool.enumerated().filter { idOf($0.element).map(linkedIDs.contains) ?? false }.map { "\($0.element.name) #\($0.offset + 1) via \($0.element.best.why)" }.joined(separator: "; "))")

        func mix(_ limit: Int) async -> (picks: [DiscoveredTrack], radio: [Int: [UUID]]) {
            let asked = Asked()
            var picker = ClusterSeedPicks()
            picker.store = nil
            picker.plays = { await plays.check($0) }
            picker.bundles = { await bundles.bundles($0) }
            let rows = picker.rows
            picker.rows = { ids in let found = try await rows(ids); await asked.add(found, asked: ids); return found }
            let picks = await picker.picks(inputs, excluding: [], limit: limit)
            return (picks, await asked.found)
        }
        for limit in [8, 20] {
            DiscogsIdentityRows.override = false
            let off = await mix(limit)
            DiscogsIdentityRows.override = true
            let on = await mix(limit), again = await mix(limit)
            for (name, run) in [("off", off), ("on ", on)] {
                let recordings = run.picks.filter { if case .recording = $0.source { true } else { false } }.count
                let withRadio = run.radio.filter { !$0.value.isEmpty }
                lines.append("  limit \(limit) \(name): \(run.picks.count) picks (\(recordings) recordings, \(run.picks.count - recordings) radio moments; by linked artists \(run.picks.filter { linkedIDs.contains($0.artistDiscogsID) }.count)); asked radio for \(run.radio.count) candidates, \(withRadio.count) found on radio (\(withRadio.values.filter { !Set($0).isDisjoint(with: linkedRows) }.count) through a linked row)")
            }
            lines.append("  limit \(limit): list changed \(off.picks.map(\.id) != on.picks.map(\.id)); on twice identical \(on.picks.map(\.id) == again.picks.map(\.id))")
        }

        // Radio candidates in the mix: A today's mix, B radio without the
        // MusicBrainz links, C radio with them (and C at other radio shares).
        let arms = await radioArms(inputs: inputs, credits: credits, bundles: heldBundles, fetchBundles: { await bundles.bundles($0) },
                                   linkedIDs: linkedIDs, plays: plays, source: { _ in ClusterSeedPicks().radio }, later: nil)
        lines += arms.lines
        // Cold and warm: C on a fresh store and fresh play checks, then again on that store.
        let storeFile = dir.appendingPathComponent("radio-arms-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeFile) }
        let store = ClusterSeedStore(file: storeFile)
        DiscogsIdentityRows.override = true
        ForYouRadioCandidatesFeature.override = true
        ClusterSeedPicks.radioShare = 0.5
        for (name, limit) in [("cold", 20), ("warm", 20)] {
            let fresh = Plays()
            var picker = ClusterSeedPicks()
            picker.store = store
            picker.plays = { await fresh.check($0) }
            picker.bundles = { await bundles.bundles($0) }
            let started = ContinuousClock.now
            let picks = await picker.picks(inputs, excluding: [], limit: limit)
            lines.append(String(format: "  C %@ (limit %d): %d picks; play checks %d; %.0f ms (radio is read every time; the store keeps credits and play checks)",
                                name, limit, picks.count, await fresh.asked, Self.ms(since: started)))
        }
        ForYouRadioCandidatesFeature.override = nil
        ClusterSeedPicks.radioShare = 0.5
        lines.append("Play checks asked: \(await plays.asked)")
        let report = lines.joined(separator: "\n")
        print(report)
        try report.write(to: dir.appendingPathComponent("mb-reach-listener.txt"), atomically: true, encoding: .utf8)
    }
}
