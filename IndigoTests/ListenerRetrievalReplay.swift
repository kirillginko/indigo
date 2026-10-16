//
//  ListenerRetrievalReplay.swift
//  IndigoTests
//
//  Listener Profile v2, Phase 3: does drawing candidates from every taste
//  cluster, two radio hops and records like the listener's reach what they
//  went on to find -- without drowning it in noise?
//
//  At several cut-offs, built only from what came before each (radio
//  episodes too: none aired after the cut-off is read), three pools:
//
//    A  For You's walk today.
//    B  One step from each cluster's strongest units, on the device.
//    C  B plus radio adjacency, second-hop radio and records like yours.
//
//  The same rankers run on every pool -- today's taste vector first, so a
//  change is retrieval's -- then v2 relevance and v2 spread across clusters.
//  Then: what the second hop brings (related or noise), stability under
//  small changes to the history, determinism, and where the unstyled share
//  of the listener's weight could get styles from.
//
//  Reads the shared catalogue (read-only) and R2 (a few release documents).
//  Opt-in: `INDIGO_RETRIEVAL_REPLAY=1`. Report (private, artist names):
//  `listener-retrieval-replay.txt` in the host's temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

final class ListenerRetrievalReplay: XCTestCase {
    /// A stable hash: Swift's own is seeded per process.
    private func fnv(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return h
    }

    func testPoolsAcrossCutoffs() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_RETRIEVAL_REPLAY"] == "1", "Set INDIGO_RETRIEVAL_REPLAY=1.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Retrieval-\(UUID().uuidString)")
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
        var out: [String] = []
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%.0f%%", 100 * Double(a) / Double(b)) }

        let similarity = RecordSimilarity(pool: try context.fetch(FetchDescriptor<DiscogsReleaseRecord>()).map(RecordProfile.init(record:)))
        let vectors = similarity.vectors
        var styleByKey: [String: [String]] = [:]
        for row in try context.fetch(FetchDescriptor<DiscogsArtist>()) where !row.styles.isEmpty {
            styleByKey[row.nameKey] = ListeningLog.foldTags(row.styles).filter { vectors[$0] != nil }
        }
        let artistRows = Dictionary(try context.fetch(FetchDescriptor<DiscogsArtist>()).map { ($0.nameKey, $0) }, uniquingKeysWith: { a, _ in a })
        var recordStyles: [String: [String]] = [:]
        for record in similarity.pool { for key in record.artistKeys { recordStyles[key, default: []] += record.styles.filter { vectors[$0] != nil } } }
        recordStyles = recordStyles.mapValues { Array(NSOrderedSet(array: $0).array as! [String]) }

        let everything = PersonalInputs.read(context: context, asOf: .distantFuture)
        let last = (everything.crate.map(\.addedAt) + everything.met.map(\.lastAt)).max() ?? Date()
        let whole = ListenerProfile.read(context: context)

        // The alias audit (whole history).
        out.append("== alias identity: \(whole.aliasLinks) alias links between names in the history; \(whole.confirmedLinks) confirmed by both entries")
        out.append("  groups by name alone (the old rule): \(whole.groupsByName); by confirmed Discogs ids: \(whole.groupsByID); names in them: \(whole.sameArtist.count)")
        out.append("  projects are no longer merged in the profile; a group only keeps its other names out of recommendations")
        for (id, names) in Dictionary(grouping: whole.sameArtist.keys.sorted(), by: { whole.sameArtist[$0]! }).sorted(by: { $0.key < $1.key }).prefix(12) {
            out.append("    discogs:\(id) = " + names.joined(separator: ", "))
        }

        var examples: [String] = []
        var summary: [String] = []

        for days in [21, 14, 7] {
            let cutoff = last.addingTimeInterval(-Double(days) * 86_400)
            let pastRead = ListenerProfile.read(context: context, before: cutoff)
            let past = ListenerProfile.build(evidence: pastRead.evidence, styles: pastRead.styles, artistStyles: pastRead.artistStyles,
                                             vectors: vectors, asOf: cutoff)
            let knownIDs = Set(pastRead.evidence.compactMap { pastRead.sameArtist[$0.artist] })
            var known = Set(pastRead.evidence.map(\.artist))
            known.formUnion(whole.sameArtist.filter { knownIDs.contains($0.value) }.keys)
            let future = whole.evidence.filter { $0.at >= cutoff && $0.signal.weight > 0 }
            let later = Set(future.map(\.artist)).subtracting(known)
            var futureTaste: [String: Double] = [:]
            for item in future {
                let styles = (whole.styles[item.unit] ?? whole.artistStyles[item.artist] ?? item.tags).filter { vectors[$0] != nil }
                for style in styles { futureTaste[style, default: 0] += item.signal.weight * item.strength / Double(styles.count) }
            }
            let futureVector = MusicalCompass.embed(futureTaste, vectors: vectors)
            out.append("")
            out.append("######## cut-off \(days) days before the last activity (\(cutoff.formatted(date: .abbreviated, time: .omitted)))")
            out.append("history before: \(pastRead.evidence.count) pieces of evidence, \(past.clusters.count) clusters (" + past.clusters.map { "\($0.label.prefix(2).joined(separator: "/")) \(Int((100 * max($0.longTermShare, $0.recentShare)).rounded()))%" }.joined(separator: ", ") + ")")
            out.append("after: \(future.count) positive actions, \(later.count) artists new to the listener")

            // A: For You's walk.
            var t = ContinuousClock.now
            var personal = PersonalInputs.read(context: context, asOf: cutoff)
            personal.crate = personal.crate.filter { $0.addedAt < cutoff }
            personal.met = personal.met.filter { $0.lastAt < cutoff }
            personal.haunts = personal.haunts.filter { $0.lastVisitedAt < cutoff }
            personal.plays = personal.plays.filter { $0.at < cutoff }
            personal.artistPlays = [:]
            let worker = DigWorker(modelContainer: container)
            let run = await worker.exploreRun(asOf: cutoff, period: ExplorePeriod.containing(cutoff), generation: 0, scenes: false,
                                              rebuild: false, now: cutoff, personal: personal)
            let v1 = ExploreRanker.taste(personal: run.personal, knowledge: run.knowledge, asOf: cutoff)
            let walk = ExploreRanker.suggestions(personal: run.personal, knowledge: run.knowledge, taste: v1, limit: 400,
                                                 alsoKnown: run.alsoKnown).filter { $0.node.kind == .artist }
            let aTime = ms(ContinuousClock.now - t)
            let aSightings = walk.map {
                ListenerRetrieval.Sighting(name: $0.node.title, discogsID: $0.node.discogsID, catalogueRow: nil,
                                           route: .init(provenance: .forYou, score: $0.score, seed: RecordingKey.normalizeArtist($0.via),
                                                        cluster: -1, why: "\($0.reason) · via \($0.via)"))
            }
            let forYouOrder = Dictionary(walk.enumerated().map { (RecordingKey.normalizeArtist($0.element.node.title), $0.offset) },
                                         uniquingKeysWith: { a, _ in a })

            // Seeds and B.
            let seeds = ListenerRetrieval.seeds(past, vectors: vectors)
            let perCluster: [String] = Dictionary(grouping: seeds, by: \.cluster).sorted { $0.key < $1.key }.map { "c\($0.key): \($0.value.count)" }
            let perLevel: [String] = Dictionary(grouping: seeds, by: \.level.rawValue).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            let starting = ExploreRanker.startingPoints(run.personal).count
            out.append("seeds: \(seeds.count) across \(Set(seeds.map(\.cluster)).count) clusters (\(perCluster.joined(separator: ", "))); levels \(perLevel.joined(separator: ", ")); For You's starting points: \(starting)")
            t = ContinuousClock.now
            let graph = IdentityGraph(context: context)
            let direct = ListenerRetrieval.direct(seeds, graph: graph)
            let bTime = ms(ContinuousClock.now - t)

            // C: radio and records like yours.
            let radio = await ListenerRetrieval.radio(seeds: seeds, discogsIDs: pastRead.discogsIDs, profile: past, vectors: vectors,
                                                      knownKeys: known, before: cutoff, source: ListenerRetrieval.liveRadio)
            let seedNames = Dictionary(seeds.map { ($0.artist, $0.name) }, uniquingKeysWith: { a, _ in a })
            let radioSightings = ListenerRetrieval.sightings(first: radio.first, second: radio.second, radio: radio.radio, seedNames: seedNames)
            t = ContinuousClock.now
            // Only records provably on the device before the cut-off: on a
            // page visited before it, or in the release list of an artist
            // the listener knew or opened before it. (Records carry no date
            // of their own; a record cached by a later visit would leak.)
            var onDevice = Set<Int>()
            for visit in try context.fetch(FetchDescriptor<DigVisit>()) where visit.firstVisitedAt < cutoff {
                if visit.kind == .release, let id = visit.discogsID { onDevice.insert(id) }
                if visit.kind == .artist, let row = artistRows[RecordingKey.normalizeArtist(visit.title)] { onDevice.formUnion(row.releaseDiscogsIDs) }
            }
            for artist in known { if let row = artistRows[artist] { onDevice.formUnion(row.releaseDiscogsIDs) } }
            let datedPool = similarity.pool.filter { onDevice.contains($0.id) }
            let similar = ListenerRetrieval.similar(past, pool: datedPool, vectors: vectors, known: known, seeds: seeds)
            let cTime = ms(ContinuousClock.now - t)
            out.append("records like yours: \(datedPool.count) of \(similarity.pool.count) records provably on the device before the cut-off")
            out.append(String(format: "cost: A walk %.0f ms (on device); B graph %.0f ms (on device); radio %.0f ms, %d requests (%d failed), %d seeds on radio, %d bridges, %d episodes; records %.0f ms",
                              aTime, bTime, radio.report.milliseconds, radio.report.requests, radio.report.failures,
                              radio.report.seedsOnRadio, radio.report.bridges, radio.report.episodes, cTime))

            // Candidates' styles: their own on the device, else their
            // records', else the genres of the radio they were heard on.
            func styled(_ c: inout ListenerRetrieval.Candidate) {
                let keys = [c.nameKey] + c.aliases.sorted()
                if let own = keys.lazy.compactMap({ styleByKey[$0] }).first(where: { !$0.isEmpty }) { c.styles = own; c.styleSource = "artist"; return }
                if let records = keys.lazy.compactMap({ recordStyles[$0] }).first(where: { !$0.isEmpty }) { c.styles = Array(records.prefix(6)); c.styleSource = "records"; return }
                var genres: [String: Double] = [:]
                if let row = UUID(uuidString: c.identity.replacingOccurrences(of: "catalogue:", with: "")) ?? radio.radio.names.first(where: { "discogs:\($0.value.discogs ?? -1)" == c.identity })?.key {
                    for (g, w) in radio.first[row]?.genres ?? [:] { genres[g, default: 0] += w }
                    for (g, w) in radio.second[row]?.genres ?? [:] { genres[g, default: 0] += w }
                }
                if !genres.isEmpty {
                    c.styles = genres.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(4).map(\.key)
                    c.styleSource = "radio genres"
                }
            }
            var lastMerge = (0, 0)
            func pool(_ sightings: [ListenerRetrieval.Sighting]) -> (candidates: [ListenerRetrieval.Candidate], surface: Int, collisions: Int) {
                let merged = ListenerRetrieval.merge(sightings)
                lastMerge = (merged.surfaceKeys, merged.candidates.count)
                var kept = merged.candidates.filter { c in !c.aliases.contains(where: known.contains) && !known.contains(c.nameKey) }
                for i in kept.indices { styled(&kept[i]) }
                return (kept, merged.surfaceKeys, merged.nameCollisions)
            }
            let boundedRadio = ListenerRetrieval.sightings(
                first: ListenerRetrieval.bound(radio.first, per: \.seed, keep: 12),
                second: ListenerRetrieval.bound(radio.second, per: { $0.via.uuidString }, keep: 4),
                radio: radio.radio, seedNames: seedNames)
            let pools: [(String, [ListenerRetrieval.Sighting])] = [
                ("A For You walk", aSightings), ("B cluster-seeded", direct),
                ("C B + radio + records", direct + radioSightings + similar),
                ("Cb C, radio bounded", direct + boundedRadio + similar),
            ]
            out.append("")
            out.append("pool                       size  later in pool (recall)  dup.rate  collisions  styled   by best route")
            var pooled: [String: [ListenerRetrieval.Candidate]] = [:]
            for (name, sightings) in pools {
                let p = pool(sightings)
                pooled[name] = p.candidates
                let hits = p.candidates.filter { c in later.contains(c.nameKey) || c.aliases.contains(where: later.contains) }
                let byRoute = Dictionary(grouping: p.candidates, by: { $0.best.provenance.rawValue }).mapValues(\.count)
                    .sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                // Surface keys (ids and names) that turned out to be one identity.
                let raw = lastMerge.0, mergedCount = lastMerge.1
                out.append(String(format: "%-26@ %5d  %3d of %3d (%@)         %@      %3d        %@    %@", name as NSString, p.candidates.count, hits.count, later.count,
                                  pct(hits.count, later.count) as NSString,
                                  pct(max(0, raw - mergedCount), raw) as NSString, p.collisions,
                                  pct(p.candidates.filter { !$0.styles.isEmpty }.count, p.candidates.count) as NSString, byRoute as NSString))
                if name.hasPrefix("C ") {
                    let hitRoutes = Dictionary(grouping: hits, by: { $0.best.provenance.rawValue }).mapValues(\.count).sorted { $0.key < $1.key }
                    out.append("    later finds in C by best route: " + hitRoutes.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                    out.append("    later finds in C by any route: " + ListenerRetrieval.Provenance.allCases.compactMap { prov in
                        let n = hits.filter { $0.provenances.contains(prov) }.count
                        return n == 0 ? nil : "\(prov.rawValue) \(n)" }.joined(separator: ", "))
                    examples.append("== cut-off \(days)d: later finds C reached, and why")
                    for c in hits.sorted(by: { $0.name < $1.name }) {
                        examples.append("  \(c.name) [\(c.styles.prefix(3).joined(separator: ", "))] — " + c.routes.prefix(3).map { "\($0.provenance.rawValue): \($0.why)" }.joined(separator: " | "))
                    }
                }
            }

            // Rankers, the same on every pool.
            func evidence(_ pool: [ListenerRetrieval.Candidate]) -> [String: Double] {
                var rank: [String: Double] = [:]
                for prov in ListenerRetrieval.Provenance.allCases {
                    var scored: [(id: String, score: Double)] = []
                    for c in pool {
                        let best = c.routes.filter { $0.provenance == prov }.map(\.score).max()
                        if let best { scored.append((c.identity, best)) }
                    }
                    scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
                    let count = Double(max(1, scored.count))
                    for (i, item) in scored.enumerated() {
                        let value: Double = 1 - Double(i) / count
                        rank[item.id] = max(rank[item.id] ?? 0, value)
                    }
                }
                for c in pool { rank[c.identity] = min(1, (rank[c.identity] ?? 0) + 0.1 * Double(c.provenances.count - 1)) }
                return rank
            }
            func evaluate(_ label: String, _ ranked: [ListenerRetrieval.Candidate]) -> String {
                let top = Array(ranked.prefix(20))
                let hits = top.filter { c in later.contains(c.nameKey) || c.aliases.contains(where: later.contains) }
                let fits = top.compactMap { c -> Double? in c.styles.isEmpty ? nil : MusicalCompass.dot(ListenerProfile.vector(c.styles, vectors), futureVector) }
                let leading = Set(top.compactMap(\.styles.first)).count
                let clusters = Set(top.compactMap { past.relevance(styles: $0.styles, vectors: vectors)?.cluster }).count
                let perSeed = Dictionary(grouping: top, by: \.best.seed).mapValues(\.count).values.max() ?? 0
                let routes = Dictionary(grouping: top, by: { $0.best.provenance.rawValue }).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                return String(format: "    %-34@ finds %d  fit %.3f (%2d styled)  styles %2d  clusters %d  max/seed %2d  [%@]%@",
                              label as NSString, hits.count, fits.isEmpty ? 0 : fits.reduce(0, +) / Double(fits.count), fits.count, leading,
                              clusters, perSeed, routes as NSString, hits.isEmpty ? "" : " ← " + hits.map(\.name).joined(separator: ", "))
            }
            out.append("")
            out.append("top 20 by ranker")
            var cResults: [String] = []
            for (name, _) in pools {
                let candidates = pooled[name] ?? []
                let ev = evidence(candidates)
                let tieBreak: (ListenerRetrieval.Candidate, ListenerRetrieval.Candidate) -> Bool = { ($0.identity) < ($1.identity) }
                let r1 = candidates.sorted { a, b in
                    let x = v1.affinity(for: a.styles), y = v1.affinity(for: b.styles)
                    if x != y { return x > y }
                    if ev[a.identity] != ev[b.identity] { return (ev[a.identity] ?? 0) > (ev[b.identity] ?? 0) }
                    return tieBreak(a, b)
                }
                let v2: (ListenerRetrieval.Candidate) -> Double = { c in
                    (past.relevance(styles: c.styles, vectors: vectors)?.score ?? 0) * (0.5 + (ev[c.identity] ?? 0))
                }
                let r2 = candidates.sorted { v2($0) != v2($1) ? v2($0) > v2($1) : tieBreak($0, $1) }
                let r3 = past.spread(r2, limit: 20, styles: \.styles, vectors: vectors)
                out.append("  \(name):")
                if name.hasPrefix("A") {
                    out.append(evaluate("For You's own order", candidates.sorted { (forYouOrder[$0.nameKey] ?? .max, $0.identity) < (forYouOrder[$1.nameKey] ?? .max, $1.identity) }))
                }
                out.append(evaluate("R1 today's taste vector", r1))
                out.append(evaluate("R2 v2 relevance x evidence", r2))
                let spreadLine = evaluate("R3 v2, slots by cluster", r3)
                out.append(spreadLine)
                if name.hasPrefix("Cb") {
                    cResults.append(spreadLine)
                    examples.append("== cut-off \(days)d: C bounded, R3's top 20")
                    for c in r3 { examples.append("  \(c.name) [\(c.styles.prefix(3).joined(separator: ", ")) · \(c.styleSource)] — \(c.best.provenance.label): \(c.best.why)") }
                }
            }

            // What the radio routes bring: related, or noise.
            let c = pooled["C B + radio + records"] ?? []
            let cb = pooled["Cb C, radio bounded"] ?? []
            out.append("")
            out.append("bounded radio: first hop \(cb.filter { $0.best.provenance == .radioAdjacent }.count), second hop \(cb.filter { $0.best.provenance == .radioSecondHop }.count); later finds kept: \(cb.filter { later.contains($0.nameKey) }.count) of C's \(c.filter { later.contains($0.nameKey) }.count)")
            out.append("radio in C: related = fits a taste cluster at ≥ 0.5; noise = styled and < 0.3; unknown = no style")
            for prov in [ListenerRetrieval.Provenance.radioAdjacent, .radioSecondHop, .direct, .sharedContext, .musicalSimilarity] {
                let group = c.filter { $0.best.provenance == prov }
                let fit = group.map { past.relevance(styles: $0.styles, vectors: vectors)?.score }
                let related = fit.filter { ($0 ?? -1) >= 0.5 }.count, noise = fit.filter { $0 != nil && $0! < 0.3 }.count
                let unknown = fit.filter { $0 == nil }.count
                let hits = group.filter { later.contains($0.nameKey) || $0.aliases.contains(where: later.contains) }.count
                out.append("  \(prov.rawValue): \(group.count); later finds \(hits) (\(pct(hits, group.count)) precision); related \(pct(related, group.count)), noise \(pct(noise, group.count)), unknown \(pct(unknown, group.count))")
            }
            let second = c.filter { $0.best.provenance == .radioSecondHop }
                .sorted { $0.best.score != $1.best.score ? $0.best.score > $1.best.score : $0.identity < $1.identity }
            examples.append("== cut-off \(days)d: strongest second-hop candidates")
            for item in second.prefix(15) {
                let fit = past.relevance(styles: item.styles, vectors: vectors)
                examples.append(String(format: "  %@ [%@] fit %@ — %@", item.name, item.styles.prefix(3).joined(separator: ", "),
                                       fit.map { String(format: "%.2f c%d", $0.score, $0.cluster) } ?? "–", item.best.why))
            }
            summary.append(String(format: "%2dd | later %3d | recall A %@ B %@ C %@ Cb %@ (size %d) | Cb R3: %@", days, later.count,
                                      pct((pooled["A For You walk"] ?? []).filter { later.contains($0.nameKey) }.count, later.count) as NSString,
                                      pct((pooled["B cluster-seeded"] ?? []).filter { later.contains($0.nameKey) }.count, later.count) as NSString,
                                      pct(c.filter { later.contains($0.nameKey) }.count, later.count) as NSString,
                                      pct(cb.filter { later.contains($0.nameKey) }.count, later.count) as NSString, cb.count,
                                      (cResults.first ?? "").trimmingCharacters(in: .whitespaces) as NSString))

            // Stability, at the longest cut-off: drop one piece of evidence
            // in twenty, five ways.
            if days == 21 {
                out.append("")
                out.append("stability: one piece of evidence in twenty dropped, five ways")
                let baseSeeds = Set(seeds.map(\.artist))
                for trial in 0..<5 {
                    let kept = pastRead.evidence.filter { fnv("\(trial)|\($0.unit)|\($0.at.timeIntervalSince1970)") % 20 != 0 }
                    let p = ListenerProfile.build(evidence: kept, styles: pastRead.styles, artistStyles: pastRead.artistStyles, vectors: vectors, asOf: cutoff)
                    let matched = past.clusters.map { base in p.clusters.map { MusicalCompass.dot(base.centroid, $0.centroid) }.max() ?? 0 }
                    let s = Set(ListenerRetrieval.seeds(p, vectors: vectors).map(\.artist))
                    out.append(String(format: "  trial %d: clusters %d → %d; matched centroid cosine mean %.3f, min %.3f; seeds kept %.0f%%",
                                      trial, past.clusters.count, p.clusters.count, matched.reduce(0, +) / Double(max(1, matched.count)),
                                      matched.min() ?? 0, 100 * Double(s.intersection(baseSeeds).count) / Double(max(1, baseSeeds.count))))
                }
                // Determinism: shuffled input; and the same rows with a tenth
                // of the artist styles missing (another device's caches).
                var shuffled = pastRead.evidence
                shuffled.sort { fnv("\($0.unit)\($0.at)") < fnv("\($1.unit)\($1.at)") }
                let again = ListenerProfile.build(evidence: shuffled, styles: pastRead.styles, artistStyles: pastRead.artistStyles, vectors: vectors, asOf: cutoff)
                let rehop = ListenerRetrieval.hop(from: seeds.compactMap { s in radio.rows[s.artist].map { (row: $0, weight: 0.5 + 0.5 * s.weight, seed: s.artist, cluster: s.cluster) } }.reversed(),
                                                  radio: radio.radio, centroids: Dictionary(uniqueKeysWithValues: past.clusters.map { ($0.id, $0.centroid) }),
                                                  vectors: vectors, exclude: [])
                let rehop2 = ListenerRetrieval.hop(from: seeds.compactMap { s in radio.rows[s.artist].map { (row: $0, weight: 0.5 + 0.5 * s.weight, seed: s.artist, cluster: s.cluster) } },
                                                   radio: radio.radio, centroids: Dictionary(uniqueKeysWithValues: past.clusters.map { ($0.id, $0.centroid) }),
                                                   vectors: vectors, exclude: [])
                out.append("  determinism: same profile from shuffled history \(again == past); same radio scores from reordered seeds \(rehop == rehop2)")
                let thinner = pastRead.artistStyles.filter { fnv($0.key) % 10 != 0 }
                let other = ListenerProfile.build(evidence: pastRead.evidence, styles: pastRead.styles, artistStyles: thinner, vectors: vectors, asOf: cutoff)
                let otherSeeds = Set(ListenerRetrieval.seeds(other, vectors: vectors).map(\.artist))
                out.append(String(format: "  with a tenth of artist styles missing (a device whose caches differ): same profile %@; clusters %d → %d; seeds kept %.0f%% -- so a cached profile's key must include the style caches, not only the synced history",
                                  "\(other == past)", past.clusters.count, other.clusters.count,
                                  100 * Double(otherSeeds.intersection(baseSeeds).count) / Double(max(1, baseSeeds.count))))
            }
        }

        // The unstyled share: where styles could come from.
        let profile = ListenerProfile.build(evidence: whole.evidence, styles: whole.styles, artistStyles: whole.artistStyles,
                                            vectors: vectors, asOf: last.addingTimeInterval(3_600))
        let unstyled = profile.units.filter { $0.longTerm > 0 && $0.styles.isEmpty }
        let totalWeight = profile.units.filter { $0.longTerm > 0 }.reduce(0) { $0 + $1.longTerm }
        let byArtist = Dictionary(grouping: unstyled, by: \.artist).mapValues { $0.reduce(0) { $0 + $1.longTerm } }
        let rows = try context.fetch(FetchDescriptor<DiscogsArtist>())
        let rowByKey = Dictionary(rows.map { ($0.nameKey, $0) }, uniquingKeysWith: { a, _ in a })
        var bucket: [String: Double] = [:]
        var r2Asked = 0, r2Found = 0, r2Requests = 0
        var radioAsked: [String] = []
        for (artist, weight) in byArtist.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            if let row = rowByKey[artist] {
                if !row.styles.isEmpty { bucket["styled on device, outside the style space"] = (bucket["styled on device, outside the style space"] ?? 0) + weight; continue }
                if !row.releaseDiscogsIDs.isEmpty, r2Asked < 40 {
                    r2Asked += 1
                    var styles: [String] = []
                    for id in row.releaseDiscogsIDs.prefix(2) {
                        r2Requests += 1
                        if let (data, _) = try? await MetadataRepository.fetchReleaseFromR2(String(id)),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            styles += (json["styles"] as? [String] ?? []) + (json["genres"] as? [String] ?? [])
                        }
                    }
                    let known = ListeningLog.foldTags(styles).filter { vectors[$0] != nil }
                    if !known.isEmpty { r2Found += 1; bucket["R2 release documents have styles"] = (bucket["R2 release documents have styles"] ?? 0) + weight; continue }
                    bucket["Discogs entry, no styles in R2 for its first releases"] = (bucket["Discogs entry, no styles in R2 for its first releases"] ?? 0) + weight
                    continue
                }
                bucket["Discogs entry without releases (or past the R2 sample)"] = (bucket["Discogs entry without releases (or past the R2 sample)"] ?? 0) + weight
                continue
            }
            radioAsked.append(artist)
            bucket["no Discogs entry on device"] = (bucket["no Discogs entry on device"] ?? 0) + weight
        }
        // Of those without an entry: does the shared catalogue's radio give genres?
        var radioGenres = 0.0, radioRequests = 0
        let named = try await ListenerRetrieval.liveRadio.rowsByName(Array(radioAsked.prefix(150)))
        radioRequests += 1
        let catalogued = try await ListenerRetrieval.liveRadio.names(Array(Set(named.values)).sorted { $0.uuidString < $1.uuidString })
        radioRequests += 2
        let withDiscogs = named.filter { catalogued[$0.value]?.discogs != nil }.keys
        let catalogueLine = (String(format: "  of 'no Discogs entry': the shared catalogue knows their Discogs id for %.1f%% of all weight (styles would still need their Discogs entry or release documents)",
                          100 * withDiscogs.reduce(0) { $0 + (byArtist[$1] ?? 0) } / max(totalWeight, 1e-9)))
        _ = catalogueLine
        for artist in radioAsked.prefix(150) {
            guard let row = named[artist] else { continue }
            radioRequests += 1
            let found = (try? await ListenerRetrieval.liveRadio.appearances(row, Date())) ?? []
            if found.contains(where: { !ListeningLog.foldTags($0.episode.genres).filter { vectors[$0] != nil }.isEmpty }) { radioGenres += byArtist[artist] ?? 0 }
        }
        out.append("")
        out.append(String(format: "== the unstyled share: %.0f%% of the weight, %d units, %d artists", 100 * unstyled.reduce(0) { $0 + $1.longTerm } / max(totalWeight, 1e-9), unstyled.count, byArtist.count))
        for (name, weight) in bucket.sorted(by: { $0.value > $1.value }) {
            out.append(String(format: "  %@: %.1f%% of all weight", name, 100 * weight / max(totalWeight, 1e-9)))
        }
        out.append(String(format: "  of 'no Discogs entry': a unique catalogue row with radio genres the space knows: %.1f%% of all weight (%d requests)", 100 * radioGenres / max(totalWeight, 1e-9), radioRequests))
        out.append(catalogueLine)
        out.append("  R2: \(r2Asked) artists sampled, \(r2Found) with styles, \(r2Requests) documents asked")
        var byLevel: [String] = []
        for (level, units) in Dictionary(grouping: unstyled, by: \.level.rawValue).sorted(by: { $0.key < $1.key }) {
            let weight: Double = units.reduce(0) { $0 + $1.longTerm }
            byLevel.append(String(format: "%@ %.1f%%", level, 100 * weight / max(totalWeight, 1e-9)))
        }
        out.append("  by level: " + byLevel.joined(separator: ", "))

        var lines: [String] = ["== summary"]
        lines.append(contentsOf: summary)
        lines.append("")
        lines.append(contentsOf: out)
        lines.append(contentsOf: ["", "######## examples"])
        lines.append(contentsOf: examples)
        let report: String = lines.joined(separator: "\n")
        try report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("listener-retrieval-replay.txt"), atomically: true, encoding: .utf8)
    }
}
