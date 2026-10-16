//
//  ListenerRankingReplay.swift
//  IndigoTests
//
//  Listener Profile v2, Phase 3: cluster seeding from dated knowledge (Bd)
//  against For You (A), now that unstyled candidates are ranked by how they
//  were reached instead of being scored zero.
//
//  Knowledge is dated as in `ListenerRetrievalReplay`: Discogs entries
//  fetched before the cut-off and not first opened after it, the records
//  they or earlier pages list, and a style space learned from those. On the
//  device only -- no network. Later finds are counted as artists and as
//  listening sessions (no gap over 45 minutes).
//
//  Rankers, the same on both pools:
//    R1  today's taste vector (styled candidates only can score);
//    R2  v2 relevance x evidence, the unknown scored zero (the last replay);
//    R4  evidence first, fit only where a style exists (the unknown takes
//        the pool's median fit);
//    R5  R4 with slots by cluster, an unstyled candidate placed by its seed.
//  Plus For You's own order on A.
//
//  Opt-in: `INDIGO_RANKING_REPLAY=1`. Report (private, artist names):
//  `listener-ranking-replay.txt` in the host's temporary directory.
//

import XCTest
import SwiftData
@testable import Indigo

final class ListenerRankingReplay: XCTestCase {
    func testDatedSeedingAgainstForYou() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_RANKING_REPLAY"] == "1", "Set INDIGO_RANKING_REPLAY=1.")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Ranking-\(UUID().uuidString)")
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
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%.0f%%", 100 * Double(a) / Double(b)) }
        func key(_ name: String) -> String { RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(name)) }

        let allRecords = try context.fetch(FetchDescriptor<DiscogsReleaseRecord>()).map(RecordProfile.init(record:))
        let allRows = try context.fetch(FetchDescriptor<DiscogsArtist>())
        let visits = try context.fetch(FetchDescriptor<DigVisit>())
        let everything = PersonalInputs.read(context: context, asOf: .distantFuture)
        let last = (everything.crate.map(\.addedAt) + everything.met.map(\.lastAt)).max() ?? Date()
        let whole = ListenerProfile.read(context: context)
        var totals: [String: (finds: Int, sessions: Int)] = [:]

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
            var styleByKey: [String: [String]] = [:]
            for row in datedRows where !row.styles.isEmpty { styleByKey[row.nameKey] = ListeningLog.foldTags(row.styles).filter { vectors[$0] != nil } }
            var recordStyles: [String: [String]] = [:]
            for record in datedPool { for k in record.artistKeys { recordStyles[k, default: []] += record.styles.filter { vectors[$0] != nil } } }

            var pastRead = ListenerProfile.read(context: context, before: cutoff)
            pastRead.artistStyles = pastRead.artistStyles.filter { rowByKey[$0.key] != nil }
            let past = ListenerProfile.build(evidence: pastRead.evidence, styles: pastRead.styles, artistStyles: pastRead.artistStyles,
                                             vectors: vectors, asOf: cutoff)
            let knownIDs = Set(pastRead.evidence.compactMap { pastRead.sameArtist[$0.artist] })
            var known = Set(pastRead.evidence.map(\.artist))
            known.formUnion(whole.sameArtist.filter { knownIDs.contains($0.value) }.keys)

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
            out.append("######## cut-off \(days) days (\(cutoff.formatted(date: .abbreviated, time: .omitted))): \(later.count) later artists in \(laterSessions) sessions; \(past.clusters.count) clusters")

            // A: For You's walk.
            var personal = PersonalInputs.read(context: context, asOf: cutoff)
            personal.crate = personal.crate.filter { $0.addedAt < cutoff }
            personal.met = personal.met.filter { $0.lastAt < cutoff }
            personal.haunts = personal.haunts.filter { $0.lastVisitedAt < cutoff }
            personal.plays = personal.plays.filter { $0.at < cutoff }
            personal.artistPlays = [:]
            let run = await DigWorker(modelContainer: container).exploreRun(asOf: cutoff, period: ExplorePeriod.containing(cutoff), generation: 0,
                                                                            scenes: false, rebuild: false, now: cutoff, personal: personal)
            let v1 = ExploreRanker.taste(personal: run.personal, knowledge: run.knowledge, asOf: cutoff)
            let walk = ExploreRanker.suggestions(personal: run.personal, knowledge: run.knowledge, taste: v1, limit: 400,
                                                 alsoKnown: run.alsoKnown).filter { $0.node.kind == .artist }
            let aSightings = walk.map {
                ListenerRetrieval.Sighting(name: $0.node.title, discogsID: $0.node.discogsID, catalogueRow: nil,
                                           route: .init(provenance: .forYou, score: $0.score, seed: RecordingKey.normalizeArtist($0.via),
                                                        cluster: -1, why: "\($0.reason) · via \($0.via)"))
            }
            let forYouOrder = Dictionary(walk.enumerated().map { (RecordingKey.normalizeArtist($0.element.node.title), $0.offset) },
                                         uniquingKeysWith: { a, _ in a })

            // Bd: cluster seeds through dated entries and records.
            let seeds = ListenerRetrieval.seeds(past, vectors: vectors)
            var entries: [String: ListenerRetrieval.Entry] = [:]
            for seed in seeds {
                guard let row = rowByKey[seed.artist] else { continue }
                entries[seed.artist] = .init(key: row.nameKey, name: row.name, collaborators: row.collaboratorNames, members: row.memberNames,
                                             groups: row.groupNames, labelNeighbours: row.labelNeighbourNames,
                                             styleNeighbours: row.styleNeighbourNames, aliases: row.aliasNames)
            }
            let bd = ListenerRetrieval.direct(seeds, entries: entries, records: datedPool)

            func pool(_ sightings: [ListenerRetrieval.Sighting]) -> [ListenerRetrieval.Candidate] {
                var kept = ListenerRetrieval.merge(sightings).candidates.filter { c in !c.aliases.contains(where: known.contains) && !known.contains(c.nameKey) }
                for i in kept.indices {
                    let keys = [kept[i].nameKey] + kept[i].aliases.sorted()
                    if let own = keys.lazy.compactMap({ styleByKey[$0] }).first(where: { !$0.isEmpty }) { kept[i].styles = own; kept[i].styleSource = "entry" }
                    else if let r = keys.lazy.compactMap({ recordStyles[$0] }).first(where: { !$0.isEmpty }) { kept[i].styles = Array(Array(NSOrderedSet(array: r).array as! [String]).prefix(6)); kept[i].styleSource = "records" }
                }
                return kept
            }
            func isFind(_ c: ListenerRetrieval.Candidate) -> Bool { later.contains(c.nameKey) || c.aliases.contains(where: later.contains) }
            func sessions(_ hits: [ListenerRetrieval.Candidate]) -> Int {
                Set(hits.compactMap { c in ([c.nameKey] + c.aliases.sorted()).lazy.compactMap { sessionOf[$0] }.first }).count
            }
            func evaluate(_ label: String, _ ranked: [ListenerRetrieval.Candidate]) -> (line: String, finds: Int, sessions: Int) {
                let top = Array(ranked.prefix(20))
                let hits = top.filter(isFind)
                let fits = top.compactMap { c -> Double? in c.styles.isEmpty ? nil : MusicalCompass.dot(ListenerProfile.vector(c.styles, vectors), futureVector) }
                let clusters = Set(top.compactMap { ListenerRetrieval.cluster(of: $0, profile: past, vectors: vectors) }).count
                let perSeed = Dictionary(grouping: top, by: \.best.seed).mapValues(\.count).values.max() ?? 0
                let styled = top.filter { !$0.styles.isEmpty }.count
                let routes = Dictionary(grouping: top, by: { $0.best.provenance.rawValue }).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                let line = String(format: "    %-34@ finds %d (%d sessions)  fit %.3f of %2d styled  clusters %d  max/seed %2d  [%@]%@",
                                  label as NSString, hits.count, sessions(hits), fits.isEmpty ? 0 : fits.reduce(0, +) / Double(fits.count), styled,
                                  clusters, perSeed, routes as NSString, hits.isEmpty ? "" : " ← " + hits.map(\.name).joined(separator: ", "))
                return (line, hits.count, sessions(hits))
            }

            var row: [String] = []
            for (name, sightings) in [("A For You walk", aSightings), ("Bd dated cluster seeds", bd)] {
                let candidates = pool(sightings)
                let ev = ListenerRetrieval.evidence(candidates)
                let r1 = candidates.sorted { a, b in
                    let x = v1.affinity(for: a.styles), y = v1.affinity(for: b.styles)
                    if x != y { return x > y }
                    if ev[a.identity] != ev[b.identity] { return (ev[a.identity] ?? 0) > (ev[b.identity] ?? 0) }
                    return a.identity < b.identity
                }
                let v2: (ListenerRetrieval.Candidate) -> Double = { c in (past.relevance(styles: c.styles, vectors: vectors)?.score ?? 0) * (0.5 + (ev[c.identity] ?? 0)) }
                let r2 = candidates.sorted { v2($0) != v2($1) ? v2($0) > v2($1) : $0.identity < $1.identity }
                let r4 = ListenerRetrieval.rank(candidates, profile: past, vectors: vectors)
                let r5 = past.spread(r4, limit: 20) { ListenerRetrieval.cluster(of: $0, profile: past, vectors: vectors) }
                let hits = candidates.filter(isFind)
                out.append("  \(name): \(candidates.count) candidates, \(pct(candidates.filter { !$0.styles.isEmpty }.count, candidates.count)) styled; later in pool \(hits.count) artists / \(sessions(hits)) of \(laterSessions) sessions")
                var rankers: [(String, [ListenerRetrieval.Candidate])] = []
                if name.hasPrefix("A") {
                    rankers.append(("For You's own order", candidates.sorted { (forYouOrder[$0.nameKey] ?? .max, $0.identity) < (forYouOrder[$1.nameKey] ?? .max, $1.identity) }))
                }
                rankers += [("R1 today's taste vector", r1), ("R2 relevance, unknown = 0", r2),
                            ("R4 evidence first", r4), ("R5 evidence first, by cluster", r5)]
                for (label, ranked) in rankers {
                    let r = evaluate(label, ranked)
                    out.append(r.line)
                    let tag = "\(name.prefix(2)) \(label.prefix(2))"
                    totals[tag, default: (0, 0)].finds += r.finds
                    totals[tag, default: (0, 0)].sessions += r.sessions
                    row.append("\(tag) \(r.finds)/\(r.sessions)")
                }
                if name.hasPrefix("Bd") {
                    examples.append("== cut-off \(days)d: Bd, R5's top 20")
                    for c in r5.prefix(20) {
                        examples.append("  \(isFind(c) ? "★ " : "")\(c.name) [\(c.styles.prefix(3).joined(separator: ", "))\(c.styles.isEmpty ? "no style" : "")] — \(c.best.provenance.label): \(c.best.why)" + (Set(c.routes.map(\.seed)).count > 1 ? " (+\(Set(c.routes.map(\.seed)).count - 1) more seeds)" : ""))
                    }
                }
            }
            summary.append("\(days)d (\(later.count) artists, \(laterSessions) sessions): " + row.joined(separator: " · "))
        }
        summary.append("totals (finds/sessions across cut-offs): " + totals.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.finds)/\($0.value.sessions)" }.joined(separator: " · "))

        var lines: [String] = ["== summary"]
        lines.append(contentsOf: summary)
        lines.append(contentsOf: out)
        lines.append(contentsOf: ["", "######## examples"])
        lines.append(contentsOf: examples)
        let report: String = lines.joined(separator: "\n")
        try report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("listener-ranking-replay.txt"), atomically: true, encoding: .utf8)
    }
}
