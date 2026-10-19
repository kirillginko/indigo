//
//  ListenerRetrievalReplay.swift
//  IndigoTests
//
//  Listener Profile v2, Phase 3: does drawing candidates from every taste
//  cluster, radio and records like the listener's reach what they went on to
//  find -- without drowning it in noise?
//
//  At several cut-offs, built only from what the device and the catalogue
//  held before each:
//
//  - **Dated knowledge.** A Discogs entry counts only if it was fetched
//    before the cut-off and its artist was not first opened after it; a
//    record only if such an entry, or a page visited before the cut-off,
//    lists it; the style space is learned from those records alone; radio
//    only from episodes aired before. (Records carry no date; one cached by
//    a later visit leaked the answer in the first replay.)
//  - **Pools.** A: For You's walk today (it reads today's device; a
//    caveat). B: one step from each cluster's strongest units in today's
//    identity graph, for reference. Bd: the same step, from dated entries
//    and records only. E: Bd plus radio scored by the episode (one
//    tracklist offers three artists at most, and counts once) and records
//    like yours.
//  - **Finds** are counted twice: as artists, and as listening sessions
//    (positive actions with no gap over 45 minutes) -- an evening spent
//    playing through one tracklist is one discovery, not sixteen.
//
//  The same rankers run on every pool -- today's taste vector first, so a
//  change is retrieval's -- then v2 relevance and v2 spread across clusters.
//
//  Reads the shared catalogue (read-only). Opt-in:
//  `INDIGO_RETRIEVAL_REPLAY=1`. Report (private, artist names):
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
        var examples: [String] = []
        var summary: [String] = []
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%.0f%%", 100 * Double(a) / Double(b)) }
        func key(_ name: String) -> String { RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(name)) }

        let allRecords = try context.fetch(FetchDescriptor<DiscogsReleaseRecord>()).map(RecordProfile.init(record:))
        let allRows = try context.fetch(FetchDescriptor<DiscogsArtist>())
        let visits = try context.fetch(FetchDescriptor<DigVisit>())
        let everything = PersonalInputs.read(context: context, asOf: .distantFuture)
        let last = (everything.crate.map(\.addedAt) + everything.met.map(\.lastAt)).max() ?? Date()
        let whole = ListenerProfile.read(context: context)

        for days in [21, 14, 7] {
            let cutoff = last.addingTimeInterval(-Double(days) * 86_400)

            // What the device held before the cut-off.
            let openedLater = Set(visits.filter { $0.kind == .artist && $0.firstVisitedAt >= cutoff }.map { key($0.title) })
            let datedRows = allRows.filter { $0.fetchedAt < cutoff && !openedLater.contains($0.nameKey) }
            let rowByKey = Dictionary(datedRows.map { ($0.nameKey, $0) }, uniquingKeysWith: { a, _ in a })
            let rowByID = Dictionary(datedRows.filter { $0.discogsID > 0 }.map { ($0.discogsID, $0) }, uniquingKeysWith: { a, _ in a })
            var onDevice = Set<Int>()
            for visit in visits where visit.firstVisitedAt < cutoff && visit.kind == .release { if let id = visit.discogsID { onDevice.insert(id) } }
            for row in datedRows { onDevice.formUnion(row.releaseDiscogsIDs) }
            let datedPool = allRecords.filter { onDevice.contains($0.id) }
            let similarity = RecordSimilarity(pool: datedPool)
            let vectors = similarity.vectors
            var styleByKey: [String: [String]] = [:]
            for row in datedRows where !row.styles.isEmpty { styleByKey[row.nameKey] = ListeningLog.foldTags(row.styles).filter { vectors[$0] != nil } }
            var recordStyles: [String: [String]] = [:]
            for record in datedPool { for k in record.artistKeys { recordStyles[k, default: []] += record.styles.filter { vectors[$0] != nil } } }
            recordStyles = recordStyles.mapValues { Array(NSOrderedSet(array: $0).array as! [String]) }

            // The listener before it, on dated styles only.
            var pastRead = ListenerProfile.read(context: context, before: cutoff)
            pastRead.artistStyles = pastRead.artistStyles.filter { rowByKey[$0.key] != nil }
            let past = ListenerProfile.build(evidence: pastRead.evidence, styles: pastRead.styles, artistStyles: pastRead.artistStyles,
                                             vectors: vectors, asOf: cutoff)
            let knownIDs = Set(pastRead.evidence.compactMap { pastRead.sameArtist[$0.artist] })
            var known = Set(pastRead.evidence.map(\.artist))
            known.formUnion(whole.sameArtist.filter { knownIDs.contains($0.value) }.keys)

            // After it: artists, and the sessions they were found in.
            let future = whole.evidence.filter { $0.at >= cutoff && $0.signal.weight > 0 }.sorted { ($0.at, $0.unit) < ($1.at, $1.unit) }
            let later = Set(future.map(\.artist)).subtracting(known)
            var sessionOf: [String: Int] = [:]
            var session = 0
            var previous: Date?
            for item in future {
                if let previous, item.at.timeIntervalSince(previous) > 45 * 60 { session += 1 }
                previous = item.at
                if later.contains(item.artist), sessionOf[item.artist] == nil { sessionOf[item.artist] = session }
            }
            let laterSessions = Set(sessionOf.values).count
            var futureTaste: [String: Double] = [:]
            for item in future {
                let styles = (whole.styles[item.unit] ?? whole.artistStyles[item.artist] ?? item.tags).filter { vectors[$0] != nil }
                for style in styles { futureTaste[style, default: 0] += item.signal.weight * item.strength / Double(styles.count) }
            }
            let futureVector = MusicalCompass.embed(futureTaste, vectors: vectors)

            out.append("")
            out.append("######## cut-off \(days) days before the last activity (\(cutoff.formatted(date: .abbreviated, time: .omitted)))")
            out.append("dated knowledge: \(datedRows.count) of \(allRows.count) Discogs entries, \(datedPool.count) of \(allRecords.count) records; style space \(vectors.count) styles")
            out.append("history before: \(pastRead.evidence.count) pieces of evidence, \(past.clusters.count) clusters (" + past.clusters.map { "\($0.label.prefix(2).joined(separator: "/")) \(Int((100 * max($0.longTermShare, $0.recentShare)).rounded()))%" }.joined(separator: ", ") + ")")
            out.append("after: \(future.count) positive actions; \(later.count) artists new to the listener, found in \(laterSessions) listening sessions")

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

            // Seeds; B from today's graph; Bd from dated entries.
            let seeds = ListenerRetrieval.seeds(past, vectors: vectors)
            let perCluster: [String] = Dictionary(grouping: seeds, by: \.cluster).sorted { $0.key < $1.key }.map { "c\($0.key): \($0.value.count)" }
            out.append("seeds: \(seeds.count) across \(Set(seeds.map(\.cluster)).count) clusters (\(perCluster.joined(separator: ", "))); For You's starting points: \(ExploreRanker.startingPoints(run.personal).count)")
            t = ContinuousClock.now
            let graphDirect = ListenerRetrieval.direct(seeds, graph: IdentityGraph(context: context))
            let bTime = ms(ContinuousClock.now - t)
            t = ContinuousClock.now
            var entries: [String: ListenerRetrieval.Entry] = [:]
            for seed in seeds {
                guard let row = rowByKey[seed.artist] else { continue }
                entries[seed.artist] = .init(key: row.nameKey, name: row.name, collaborators: row.collaboratorNames, members: row.memberNames,
                                             groups: row.groupNames, labelNeighbours: row.labelNeighbourNames,
                                             styleNeighbours: row.styleNeighbourNames, aliases: row.aliasNames)
            }
            let datedDirect = ListenerRetrieval.direct(seeds, entries: entries, records: datedPool)
            let similar = ListenerRetrieval.similar(past, pool: datedPool, vectors: vectors, known: known, seeds: seeds)
            let bdTime = ms(ContinuousClock.now - t)

            // E: radio by the episode.
            let radio = await ListenerRetrieval.radio(seeds: seeds, discogsIDs: pastRead.discogsIDs, profile: past, vectors: vectors,
                                                      knownKeys: known, before: cutoff, source: ListenerRetrieval.liveRadio, perEpisode: 3)
            let seedNames = Dictionary(seeds.map { ($0.artist, $0.name) }, uniquingKeysWith: { a, _ in a })
            let radioSightings = ListenerRetrieval.sightings(first: radio.first, second: radio.second, radio: radio.radio, seedNames: seedNames)
            out.append("seeds with a dated entry: \(entries.count) of \(seeds.count); records like yours: \(similar.count) offered")
            out.append(String(format: "cost: A walk %.0f ms; B graph %.0f ms; Bd entries + records %.0f ms (all on device); radio %.0f ms, %d requests (%d failed), %d seeds on radio, %d bridges, %d episodes",
                              aTime, bTime, bdTime, radio.report.milliseconds, radio.report.requests, radio.report.failures,
                              radio.report.seedsOnRadio, radio.report.bridges, radio.report.episodes))

            // Styles before ranking, all dated: the candidate's own entry (by
            // name, else by the Discogs id the catalogue gives), its records,
            // else the genres of the episodes it was heard on.
            var styleSources: [String: Int] = [:]
            func styled(_ c: inout ListenerRetrieval.Candidate) {
                let keys = [c.nameKey] + c.aliases.sorted()
                let id = c.identity.hasPrefix("discogs:") ? Int(c.identity.dropFirst(8)) : nil
                if let own = keys.lazy.compactMap({ styleByKey[$0] }).first(where: { !$0.isEmpty }) {
                    c.styles = own; c.styleSource = "entry by name"
                } else if let id, let row = rowByID[id], !row.styles.isEmpty,
                          case let own = ListeningLog.foldTags(row.styles).filter({ vectors[$0] != nil }), !own.isEmpty {
                    c.styles = own; c.styleSource = "entry by Discogs id"
                } else if let records = keys.lazy.compactMap({ recordStyles[$0] }).first(where: { !$0.isEmpty }) {
                    c.styles = Array(records.prefix(6)); c.styleSource = "records"
                } else {
                    var genres: [String: Double] = [:]
                    let rows = radio.radio.names.filter { "discogs:\($0.value.discogs ?? -1)" == c.identity || "catalogue:\($0.key.uuidString.lowercased())" == c.identity }.keys
                    for row in rows.sorted(by: { $0.uuidString < $1.uuidString }) {
                        for (g, w) in (radio.first[row]?.genres ?? [:]).sorted(by: { $0.key < $1.key }) { genres[g, default: 0] += w }
                        for (g, w) in (radio.second[row]?.genres ?? [:]).sorted(by: { $0.key < $1.key }) { genres[g, default: 0] += w }
                    }
                    if !genres.isEmpty {
                        c.styles = genres.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(4).map(\.key)
                        c.styleSource = "episode genres"
                    }
                }
            }
            var lastMerge = (0, 0)
            func pool(_ sightings: [ListenerRetrieval.Sighting]) -> (candidates: [ListenerRetrieval.Candidate], collisions: Int) {
                let merged = ListenerRetrieval.merge(sightings)
                lastMerge = (merged.surfaceKeys, merged.candidates.count)
                var kept = merged.candidates.filter { c in !c.aliases.contains(where: known.contains) && !known.contains(c.nameKey) }
                for i in kept.indices { styled(&kept[i]) }
                return (kept, merged.nameCollisions)
            }
            func isFind(_ c: ListenerRetrieval.Candidate) -> Bool { later.contains(c.nameKey) || c.aliases.contains(where: later.contains) }
            func sessions(_ hits: [ListenerRetrieval.Candidate]) -> Int {
                Set(hits.compactMap { c in ([c.nameKey] + c.aliases.sorted()).lazy.compactMap { sessionOf[$0] }.first }).count
            }
            let pools: [(String, [ListenerRetrieval.Sighting])] = [
                ("A For You walk", aSightings),
                ("B graph (today's)", graphDirect),
                ("Bd dated entries", datedDirect),
                ("E Bd + episode radio + records", datedDirect + radioSightings + similar),
            ]
            out.append("")
            out.append("pool                               size  later in pool: artists (recall) / sessions   dup.rate  collisions  styled  by best route")
            var pooled: [String: [ListenerRetrieval.Candidate]] = [:]
            for (name, sightings) in pools {
                let p = pool(sightings)
                pooled[name] = p.candidates
                let hits = p.candidates.filter(isFind)
                let byRoute = Dictionary(grouping: p.candidates, by: { $0.best.provenance.rawValue }).mapValues(\.count)
                    .sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                out.append(String(format: "%-34@ %5d  %3d of %3d (%@) / %d of %d       %@        %2d      %@    %@",
                                  name as NSString, p.candidates.count, hits.count, later.count, pct(hits.count, later.count) as NSString,
                                  sessions(hits), laterSessions,
                                  pct(max(0, lastMerge.0 - lastMerge.1), lastMerge.0) as NSString, p.collisions,
                                  pct(p.candidates.filter { !$0.styles.isEmpty }.count, p.candidates.count) as NSString, byRoute as NSString))
                if name.hasPrefix("E") {
                    out.append("    styles from: " + Dictionary(grouping: p.candidates, by: \.styleSource).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                    out.append("    later finds by best route: " + Dictionary(grouping: hits, by: { $0.best.provenance.rawValue }).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                    let radioHits = hits.filter { [.radioAdjacent, .radioSecondHop].contains($0.best.provenance) }
                    out.append("    radio finds: \(radioHits.count) artists through \(Set(radioHits.compactMap(\.best.evidence)).count) episodes, in \(sessions(radioHits)) sessions")
                    examples.append("== cut-off \(days)d: later finds E reached, and why")
                    for c in hits.sorted(by: { $0.name < $1.name }) {
                        examples.append("  \(c.name) [\(c.styles.prefix(3).joined(separator: ", ")) · \(c.styleSource)] session \(([c.nameKey] + c.aliases.sorted()).lazy.compactMap { sessionOf[$0] }.first ?? -1) — " + c.routes.prefix(3).map { "\($0.provenance.rawValue): \($0.why)" }.joined(separator: " | "))
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
            func evaluate(_ label: String, _ ranked: [ListenerRetrieval.Candidate]) -> (line: String, finds: Int, sessions: Int, fit: Double) {
                let top = Array(ranked.prefix(20))
                let hits = top.filter(isFind)
                let fits = top.compactMap { c -> Double? in c.styles.isEmpty ? nil : MusicalCompass.dot(ListenerProfile.vector(c.styles, vectors), futureVector) }
                let fit = fits.isEmpty ? 0 : fits.reduce(0, +) / Double(fits.count)
                let leading = Set(top.compactMap(\.styles.first)).count
                let clusters = Set(top.compactMap { past.relevance(styles: $0.styles, vectors: vectors)?.cluster }).count
                let perSeed = Dictionary(grouping: top, by: \.best.seed).mapValues(\.count).values.max() ?? 0
                let routes = Dictionary(grouping: top, by: { $0.best.provenance.rawValue }).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                let line = String(format: "    %-30@ finds %d (%d sessions)  fit %.3f (%2d styled)  styles %2d  clusters %d  max/seed %2d  [%@]%@",
                                  label as NSString, hits.count, sessions(hits), fit, fits.count, leading, clusters, perSeed, routes as NSString,
                                  hits.isEmpty ? "" : " ← " + hits.map(\.name).joined(separator: ", "))
                return (line, hits.count, sessions(hits), fit)
            }
            out.append("")
            out.append("top 20 by ranker")
            var bestLine: [String: String] = [:]
            for (name, _) in pools {
                let candidates = pooled[name] ?? []
                let ev = evidence(candidates)
                let r1 = candidates.sorted { a, b in
                    let x = v1.affinity(for: a.styles), y = v1.affinity(for: b.styles)
                    if x != y { return x > y }
                    if ev[a.identity] != ev[b.identity] { return (ev[a.identity] ?? 0) > (ev[b.identity] ?? 0) }
                    return a.identity < b.identity
                }
                let v2: (ListenerRetrieval.Candidate) -> Double = { c in
                    (past.relevance(styles: c.styles, vectors: vectors)?.score ?? 0) * (0.5 + (ev[c.identity] ?? 0))
                }
                let r2 = candidates.sorted { v2($0) != v2($1) ? v2($0) > v2($1) : $0.identity < $1.identity }
                let r3 = past.spread(r2, limit: 20, styles: \.styles, vectors: vectors)
                out.append("  \(name):")
                var results: [(String, (line: String, finds: Int, sessions: Int, fit: Double))] = []
                if name.hasPrefix("A") {
                    results.append(("For You order", evaluate("For You's own order", candidates.sorted { (forYouOrder[$0.nameKey] ?? .max, $0.identity) < (forYouOrder[$1.nameKey] ?? .max, $1.identity) })))
                }
                results.append(("R1", evaluate("R1 today's taste vector", r1)))
                results.append(("R2", evaluate("R2 v2 relevance x evidence", r2)))
                results.append(("R3", evaluate("R3 v2, slots by cluster", r3)))
                for (_, r) in results { out.append(r.line) }
                let best = results.max { ($0.1.sessions, $0.1.finds, $0.1.fit) < ($1.1.sessions, $1.1.finds, $1.1.fit) }!
                bestLine[name] = String(format: "%@ %d/%d %.2f", best.0, best.1.finds, best.1.sessions, best.1.fit)
                if name.hasPrefix("E") {
                    examples.append("== cut-off \(days)d: E, R3's top 20")
                    for c in r3 { examples.append("  \(c.name) [\(c.styles.prefix(3).joined(separator: ", ")) · \(c.styleSource)] — \(c.best.provenance.label): \(c.best.why)") }
                }
            }

            // What each route brings: related, or noise.
            let e = pooled["E Bd + episode radio + records"] ?? []
            out.append("")
            out.append("routes in E: related = fits a taste cluster at ≥ 0.5; noise = styled and < 0.3; unknown = no style")
            for prov in [ListenerRetrieval.Provenance.radioAdjacent, .radioSecondHop, .direct, .sharedContext, .musicalSimilarity] {
                let group = e.filter { $0.best.provenance == prov }
                let fit = group.map { past.relevance(styles: $0.styles, vectors: vectors)?.score }
                let related = fit.filter { ($0 ?? -1) >= 0.5 }.count, noise = fit.filter { $0 != nil && $0! < 0.3 }.count
                let unknown = fit.filter { $0 == nil }.count
                let hits = group.filter(isFind)
                out.append("  \(prov.rawValue): \(group.count); later finds \(hits.count) in \(sessions(hits)) sessions (\(pct(hits.count, group.count))); related \(pct(related, group.count)), noise \(pct(noise, group.count)), unknown \(pct(unknown, group.count))")
            }
            let second = e.filter { $0.best.provenance == .radioSecondHop }
                .sorted { $0.best.score != $1.best.score ? $0.best.score > $1.best.score : $0.identity < $1.identity }
            examples.append("== cut-off \(days)d: strongest second-hop candidates")
            for item in second.prefix(12) {
                let fit = past.relevance(styles: item.styles, vectors: vectors)
                examples.append(String(format: "  %@ [%@] fit %@ — %@", item.name, item.styles.prefix(3).joined(separator: ", "),
                                       fit.map { String(format: "%.2f c%d", $0.score, $0.cluster) } ?? "–", item.best.why))
            }

            func recall(_ name: String) -> String {
                let hits = (pooled[name] ?? []).filter(isFind)
                return "\(pct(hits.count, later.count))/\(pct(sessions(hits), laterSessions))"
            }
            summary.append("\(days)d | later \(later.count) artists in \(laterSessions) sessions | pool recall artists/sessions: A \(recall("A For You walk")) B \(recall("B graph (today's)")) Bd \(recall("Bd dated entries")) E \(recall("E Bd + episode radio + records")) (E size \(e.count))")
            summary.append("      best top 20 (finds/sessions fit): A \(bestLine["A For You walk"] ?? "") · B \(bestLine["B graph (today's)"] ?? "") · Bd \(bestLine["Bd dated entries"] ?? "") · E \(bestLine["E Bd + episode radio + records"] ?? "")")

            if days == 21 {
                // Determinism of the episode scoring: reordered input.
                let rows = seeds.compactMap { s in radio.rows[s.artist].map { (row: $0, weight: 0.5 + 0.5 * s.weight, seed: s.artist, cluster: s.cluster) } }
                let centroids = Dictionary(uniqueKeysWithValues: past.clusters.map { ($0.id, $0.centroid) })
                let a = ListenerRetrieval.hop(from: rows, radio: radio.radio, centroids: centroids, vectors: vectors, exclude: [], perEpisode: 3)
                let b = ListenerRetrieval.hop(from: rows.reversed(), radio: radio.radio, centroids: centroids, vectors: vectors, exclude: [], perEpisode: 3)
                out.append("")
                out.append("determinism: same episode-scored radio from reordered seeds \(a == b)")
            }
        }

        var lines: [String] = ["== summary"]
        lines.append(contentsOf: summary)
        lines.append(contentsOf: out)
        lines.append(contentsOf: ["", "######## examples"])
        lines.append(contentsOf: examples)
        let report: String = lines.joined(separator: "\n")
        try report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("listener-retrieval-replay.txt"), atomically: true, encoding: .utf8)
    }
}
