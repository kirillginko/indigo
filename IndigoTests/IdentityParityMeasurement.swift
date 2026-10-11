//
//  IdentityParityMeasurement.swift
//  IndigoTests
//
//  Phase 1 of SHARED-KNOWLEDGE.md: the backend's knowledge, ranked through
//  the same identity-aware path as the visible For You, beside it.
//
//  Opt-in: `TEST_RUNNER_INDIGO_MEASURE_PARITY=1`. Reads the live backend and
//  R2 (reads only) and works on copies of this Mac's stores — Development,
//  and Production when present — never the stores themselves. Writes
//  `identity-parity.txt` to the host's temporary directory.
//
//  Every variant starts from the same synced rows and the same evaluation
//  day. Knowledge and identity are varied separately, so a difference can be
//  put down to knowledge one side lacks, to identity evidence, or to which
//  candidates the ranking chose:
//
//  knowledge  visible (as shown) · local shared part · SQL · SQL + bundles ·
//             SQL + bundles + styles
//  identity   device — this device's evidence (`ArtistNodeIdentifier`)
//             backend — what the backend can justify: a MusicBrainz link for
//             a starting point, a credit's Discogs id for anyone a bundle
//             names. Never a catalogue row matched by name.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class IdentityParityMeasurement: XCTestCase {
    private var out: [String] = []

    func testIdentityParityOnThisMacsStores() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_MEASURE_PARITY"] == "1",
                          "Set INDIGO_MEASURE_PARITY=1 to measure Phase 1 against the live backend.")
        try XCTSkipUnless(SupabaseService.isConfigured, "The backend is not configured in this build.")
        let support = StoreLayout.standard.directory
        for (label, folder) in [("Development", support.appendingPathComponent("Development", isDirectory: true)),
                                ("Production (copy)", support)] {
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("UserData.store").path) else {
                out.append("== \(label): no stores"); continue
            }
            let (container, copy) = try Self.copy(folder)
            defer { try? FileManager.default.removeItem(at: copy) }
            await measure(label, container: container)
        }
        let text = out.joined(separator: "\n") + "\n"
        try text.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("identity-parity.txt"),
                       atomically: true, encoding: .utf8)
    }

    private static func copy(_ folder: URL) throws -> (ModelContainer, URL) {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        for name in ["UserData.store", "Local.store"] {
            for suffix in ["", "-wal", "-shm"] {
                let from = folder.appendingPathComponent(name + suffix)
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix))
            }
        }
        let container = try Persistence.makeSplitContainer(userData: copy.appendingPathComponent("UserData.store"),
                                                           local: copy.appendingPathComponent("Local.store"))
        return (container, copy)
    }

    // MARK: The measurement

    private func measure(_ label: String, container: ModelContainer) async {
        let context = ModelContext(container)
        let now = Date()
        let period = ExplorePeriod.containing(now)
        let asOf = ExplorePeriod.asOf(period)
        out += ["", "==================== \(label) ===================="]

        // The visible For You, as the app builds it.
        let worker = DigWorker(modelContainer: container)
        let visibleRun = await worker.exploreRun(asOf: asOf, period: period, generation: 0, scenes: true, rebuild: true, now: now)
        let rows = visibleRun.rows
        out.append("synced rows: \(rows.crate.count) crate, \(rows.met.count) met, \(rows.plays.count) plays in horizon, \(rows.haunts.count) haunts; digest \(cut(CanonicalDigest.of(rows)))")
        out.append("evaluation day \(period); starting points \(ExploreRanker.startingPoints(rows).count) (from the rows as kept)")
        out.append("visible stamp: FY\(visibleRun.stamp.format).\(period).\(cut(visibleRun.stamp.personal)).\(cut(visibleRun.stamp.shared)).\(cut(visibleRun.stamp.deviceLocal)).\(cut(visibleRun.stamp.identity ?? "-")).\(cut(visibleRun.stamp.known ?? "-"))")

        // The backend: asked from the rows as kept, for artists the rows
        // name — never for anything only this device's caches know.
        var cache = BackendKnowledgeCache()
        let origins = ExploreRanker.startingPoints(rows)
        let artists = BackendKnowledgeAdapter.artistsWanted(rows, deviceLocal: .empty)
        let cold = await BackendKnowledgeFetcher.refresh(&cache, nodes: origins, artists: artists, now: now)
        let warm = await BackendKnowledgeFetcher.refresh(&cache, nodes: origins, artists: artists, now: now)
        var bundles = BundleCache()
        let wanted = origins.filter { $0.kind == .artist }.flatMap { cache.nodes[$0.id]?.answer.cataloguedDiscogsIDs ?? [] }
        let bundleCold = await BundleFetcher.refresh(&bundles, discogsIDs: wanted, now: now)
        let bundleWarm = await BundleFetcher.refresh(&bundles, discogsIDs: wanted, now: now)
        out.append("")
        out.append("BACKEND FETCH")
        out.append("  cold: \(cold.calls) calls, \(cold.bytes) bytes, ms \(cold.milliseconds.map { Int($0) }), retries \(cold.retries), errors \(cold.errors), generation \(cold.generation)")
        out.append("  asked \(cold.nodesAsked) starting points, \(cold.artistsAsked) artists")
        out.append("  warm (same generation): \(warm.calls) calls, kept \(warm.nodesKept) points and \(warm.artistsKept) artists")
        out.append("  bundles cold: \(bundleCold.reads) reads, \(bundleCold.bytes) bytes, errors \(bundleCold.errors); warm: \(bundleWarm.reads) reads")

        // Knowledge, name-keyed as each source gives it.
        let local = Self.withoutLibrary(visibleRun.knowledge, rows: rows, context: context, visible: visibleRun)
        var backend: [(String, KnowledgeSnapshot, BackendCoverage, [BundleStatus])] = []
        for use in BackendKnowledgeAdapter.BundleUse.allCases {
            let (snapshot, coverage, statuses) = BackendKnowledgeAdapter.snapshot(
                personal: rows, deviceLocal: .empty, cache: cache, now: now, bundles: bundles, use: use)
            backend.append((use.rawValue, snapshot, coverage, statuses))
        }
        if let coverage = backend.first?.2 {
            let statuses = Dictionary(grouping: coverage.startingPoints.values, by: { $0 }).mapValues(\.count)
            out.append("  coverage: starting points \(statuses.sorted { $0.key < $1.key }); artists found \(coverage.artistsFound), unknown \(coverage.artistsUnknown), missing \(coverage.artistsMissing)")
        }
        if let statuses = backend.last?.3 {
            out.append("  bundles: " + Dictionary(grouping: statuses, by: \.status).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            for status in statuses where status.status != "complete" { out.append("    \(status.node) \(status.discogsID.map(String.init) ?? "-"): \(status.status) \(status.detail)") }
        }

        // Identity sources.
        let device = ArtistNodeIdentifier(context: context).identify
        let backendIdentity = Self.backendIdentity(cache)

        // The variants.
        let baseline = Ranked.visible(visibleRun, asOf: asOf, turn: period)
        var variants: [(String, Ranked)] = [("visible (as shown)", baseline)]
        variants.append(("local · device", Ranked.build(local, rows: rows, identify: device, asOf: asOf, turn: period, source: "local shared part, device identity")))
        for (name, snapshot, _, _) in backend {
            variants.append(("\(name) · backend", Ranked.build(snapshot, rows: rows, identify: backendIdentity, asOf: asOf, turn: period, source: "backend \(name), backend identity")))
        }
        let sqlBundles = backend.first { $0.0 == BackendKnowledgeAdapter.BundleUse.relationships.rawValue }!.1
        let crossDevice = Ranked.build(sqlBundles, rows: rows, identify: device, asOf: asOf, turn: period, source: "backend relationships, device identity")
        let crossBackend = Ranked.build(local, rows: rows, identify: backendIdentity, asOf: asOf, turn: period, source: "local shared part, backend identity")
        variants.append(("relationships · device", crossDevice))
        variants.append(("local · backend", crossBackend))
        variants.append(("relationships · backend, name routes counted", Ranked.build(
            sqlBundles, rows: rows, identify: backendIdentity, asOf: asOf, turn: period,
            source: "diagnosis only: as if SQL edges carried Discogs ids", reinforce: true)))

        out.append("")
        out.append("VARIANTS (all from the same rows and day; overlap against the visible For You)")
        for (name, ranked) in variants {
            out += ranked.describe(name, against: baseline)
        }

        // Where the visible top twenty and the backend's disagree, and why.
        let backendRanked = variants.first { $0.0.hasPrefix("relationships ·") && $0.0.hasSuffix("backend") }!.1
        out.append("")
        out.append("DISAGREEMENT: visible top 20 vs SQL + bundles (backend identity)")
        out += Self.attribute(baseline: baseline, backend: backendRanked, crossDevice: crossDevice, local: variants[1].1)
        out.append("")
        out.append("DISAGREEMENT: SQL + bundles top 20 not in the visible top 20")
        out += Self.attribute(baseline: backendRanked, backend: baseline, crossDevice: crossBackend, local: crossDevice, reversed: true)
    }

    // MARK: Identity sources

    /// What the backend can justify about who an artist node is.
    ///
    /// - A Discogs id a node carries came from a bundle credit (SQL edges to
    ///   artists carry none since 0074): the credit names that entry.
    /// - A starting point is the entry MusicBrainz links it to, when it links
    ///   exactly one. A catalogue row the backend matched by name is kept as
    ///   consistent, never placed — the same rule the device follows.
    static func backendIdentity(_ cache: BackendKnowledgeCache) -> (MusicNode) -> ArtistNodeIdentity {
        var linked: [String: [Int]] = [:]
        var rowOnly: [String: [Int]] = [:]
        for (id, kept) in cache.nodes where id.hasPrefix("artist:") {
            let key = String(id.dropFirst("artist:".count))
            for identity in kept.answer.identities ?? [] {
                guard let discogs = Int(identity.discogsID) else { continue }
                if identity.via == "musicbrainz" { linked[key, default: []].append(discogs) }
                else { rowOnly[key, default: []].append(discogs) }
            }
        }
        return { node in
            if let carried = node.discogsID {
                return ArtistNodeIdentity(identity: .discogs(carried), provenance: .credit, carriedDiscogsID: carried)
            }
            if let ids = linked[node.key].map(Set.init), ids.count == 1, let id = ids.first {
                return ArtistNodeIdentity(identity: .discogs(id), provenance: .resolver, carriedDiscogsID: nil, basis: .musicBrainzLink)
            }
            if let ids = rowOnly[node.key].map(Set.init), ids.count == 1, let id = ids.first {
                return ArtistNodeIdentity(identity: .discogs(id), provenance: .consistentRecord, carriedDiscogsID: nil)
            }
            return ArtistNodeIdentity(identity: .name(node.key), provenance: .nameOnly, carriedDiscogsID: nil)
        }
    }

    /// The visible knowledge's shared part, name-keyed again so either
    /// identity can be applied to it: each starting point walked as the app
    /// walks it today, before identity — the local engine's knowledge —
    /// without the library (decision 1).
    static func withoutLibrary(_ knowledge: KnowledgeSnapshot, rows: PersonalInputs, context: ModelContext, visible: ExploreRun) -> KnowledgeSnapshot {
        let adapter = LocalKnowledgeAdapter(context: context)
        let origins = ExploreRanker.startingPoints(rows)
        var walked: [MusicNode: LocalKnowledgeAdapter.Walked] = [:]
        for origin in origins { walked[origin] = .init(shared: adapter.neighbourhood(of: origin).shared, deviceLocal: []) }
        return LocalKnowledgeAdapter.assemble(
            origins: origins, walked: walked, shows: knowledge.shared.shows, artistTags: knowledge.shared.artistTags,
            scenes: knowledge.shared.scenes, libraryCounts: [:])
    }

    // MARK: Attribution

    /// For each of `baseline`'s top twenty missing from `backend`'s: whether
    /// the other side's knowledge cannot reach it at all (knowledge), reaches
    /// the same artist under another key (identity), or reaches it and ranked
    /// it lower (selection).
    static func attribute(baseline: Ranked, backend: Ranked, crossDevice: Ranked, local: Ranked, reversed: Bool = false) -> [String] {
        let theirTop = Set(backend.all.prefix(20).map(\.id))
        let theirTopKeys = backend.all.prefix(20).map { backend.keys($0) }
        var counts: [String: Int] = [:]
        var byKind: [String: [String: Int]] = [:]
        var lines: [String] = []
        for (rank, suggestion) in baseline.all.prefix(20).enumerated() where !theirTop.contains(suggestion.id) {
            let mine = baseline.keys(suggestion)
            let cause: String
            if theirTopKeys.contains(where: { !$0.isDisjoint(with: mine) }) {
                cause = "identity (in both top twenties, under another key)"
            } else if let place = backend.reach[suggestion.id] {
                cause = "selection (reached, ranked #\(place + 1))"
            } else if let place = backend.place(of: mine) {
                cause = "selection (reached under another key, ranked #\(place + 1))"
            } else if crossDevice.reach[suggestion.id] != nil || crossDevice.place(of: mine) != nil {
                cause = "identity (reached only under the other identity)"
            } else {
                cause = "knowledge (no route)"
            }
            let family = cause.components(separatedBy: " ").first ?? cause
            counts[family, default: 0] += 1
            byKind[family, default: [:]][suggestion.kind.rawValue, default: 0] += 1
            lines.append("  #\(rank + 1) \(suggestion.node.title) [\(suggestion.node.id)] \(suggestion.kind.rawValue) — \(cause)")
        }
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let kinds = byKind.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))" }
        return ["  by cause: \(summary.isEmpty ? "none" : summary)"] + kinds.map { "    \($0)" } + lines
    }

    private func cut(_ digest: String) -> String { String(digest.prefix(12)) }
}

// MARK: - One ranked variant

@MainActor
struct Ranked {
    let source: String
    let personal: PersonalInputs
    let knowledge: KnowledgeSnapshot
    let alsoKnown: Set<String>
    let next: [ExploreSuggestion]
    let artists: [ExploreSuggestion]
    let shows: [ExploreSuggestion]
    let all: [ExploreSuggestion]
    let direction: String
    /// Every candidate the knowledge offers at all, by id and by match key,
    /// with its place in the full ranking.
    let reach: [String: Int]
    /// Every key a candidate answers to (its entry, every name behind it),
    /// with the best place any candidate holding it reached.
    let reachByKey: [String: Int]
    /// The folded names behind each identity row: what placed it here.
    let names: [String: Set<String>]
    var counts: [String: Int] = [:]

    /// Every key a row could be known by on the other side: its entry, the
    /// names that placed it, its own name. For joining two variants in a
    /// report only — never identity.
    static func keys(_ node: MusicNode, names: [String: Set<String>]) -> Set<String> {
        guard node.kind == .artist else { return [node.id] }
        var keys: Set<String> = ["name:" + RecordingKey.normalizeArtist(node.title)]
        if GraphIdentityKey(nodeKey: node.key) == nil { keys.insert("name:" + node.key) }
        if let id = node.discogsID { keys.insert("discogs:\(id)") }
        for name in names[node.id] ?? [] { keys.insert("name:" + name) }
        return keys
    }

    func keys(_ suggestion: ExploreSuggestion) -> Set<String> { Ranked.keys(suggestion.node, names: names) }

    /// The best place this variant gives the artist any of these keys name.
    func place(of keys: Set<String>) -> Int? { keys.compactMap { reachByKey[$0] }.min() }

    static func rank(personal: PersonalInputs, knowledge: KnowledgeSnapshot, alsoKnown: Set<String>, asOf: Date, turn: Int,
                     source: String, names: [String: Set<String>] = [:]) -> Ranked {
        let taste = ExploreRanker.taste(personal: personal, knowledge: knowledge, asOf: asOf)
        let offers = ExploreRanker.recommendations(personal: personal, knowledge: knowledge, taste: taste, alsoKnown: alsoKnown)
        let everything = ExploreRanker.suggestions(personal: personal, knowledge: knowledge, taste: taste, limit: 2_000, alsoKnown: alsoKnown)
        let direction = ExploreRanker.direction(personal: personal, knowledge: knowledge, taste: taste, turn: turn)
        var reach: [String: Int] = [:]
        var byKey: [String: Int] = [:]
        for (index, suggestion) in everything.enumerated() {
            if reach[suggestion.id] == nil { reach[suggestion.id] = index }
            for key in Ranked.keys(suggestion.node, names: names) where byKey[key] == nil { byKey[key] = index }
        }
        return Ranked(source: source, personal: personal, knowledge: knowledge, alsoKnown: alsoKnown,
                      next: offers.next, artists: offers.artists, shows: offers.shows,
                      all: Array(everything.prefix(40)), direction: direction.map { "\($0.city) \($0.sound)" } ?? "-",
                      reach: reach, reachByKey: byKey, names: names)
    }

    static func visible(_ run: ExploreRun, asOf: Date, turn: Int) -> Ranked {
        var ranked = rank(personal: run.personal, knowledge: run.knowledge, alsoKnown: run.alsoKnown, asOf: asOf, turn: turn,
                          source: "this device's knowledge as shown (library included), device identity")
        ranked.counts = run.report.counts.filter { $0.key.hasPrefix("identity") }
        return ranked
    }

    /// Name-keyed knowledge put under an identity source: the same steps the
    /// visible For You takes — starting points and history read under
    /// identity, one artist one candidate, known artists kept out.
    /// `reinforce` is for diagnosis only, never a policy: a name row beside
    /// the one entry answering to it is re-pointed to that entry instead of
    /// folded — what the routes would be if the backend's SQL edges carried
    /// their artists' Discogs ids, as they did before 0074.
    static func build(_ raw: KnowledgeSnapshot, rows: PersonalInputs, identify: @escaping (MusicNode) -> ArtistNodeIdentity,
                      asOf: Date, turn: Int, source: String, reinforce: Bool = false) -> Ranked {
        let canonicalizer = GraphCanonicalizer(identify: identify)
        let personal = canonicalizer.canonical(rows)
        let sets = ExploreRanker.edgeSets(raw)
        var walked: [MusicNode: EdgeSet] = [:]
        var owners: [String: Set<String>] = [:]
        var aliases = 0
        for (rawOrigin, set) in sets.sorted(by: { $0.key.id < $1.key.id }) {
            let origin = canonicalizer.canonical(rawOrigin)
            var into = walked[origin] ?? EdgeSet()
            for edge in set.all {
                let canonical = canonicalizer.canonical(edge)
                guard canonical.to.id != origin.id else { continue }
                if canonical.to.kind == .artist, GraphIdentityKey(nodeKey: canonical.to.key) != nil {
                    owners[edge.to.key, default: []].insert(canonical.to.id)
                    if edge.kind.isAlias { aliases += 1 }
                }
                into.insert(MusicEdge(from: origin, to: canonical.to, kind: canonical.kind, source: canonical.source,
                                      reason: canonical.reason, confidence: canonical.confidence, occurrences: canonical.occurrences))
            }
            walked[origin] = into
        }
        // One artist, one candidate: a name row beside the one entry that
        // answers to it here is that entry's. No routes are moved.
        var dropped: Set<String> = []
        for set in walked.values {
            for node in set.all.map(\.to) where node.kind == .artist && GraphIdentityKey(nodeKey: node.key) == nil {
                if owners[node.key]?.count == 1 { dropped.insert(node.id) }
            }
        }
        var split: [MusicNode: LocalKnowledgeAdapter.Walked] = [:]
        var destinations = Set<String>()
        for (origin, set) in walked {
            var kept = set.all.filter { !dropped.contains($0.to.id) }
            if reinforce {
                var moved = EdgeSet()
                for edge in set.all {
                    guard dropped.contains(edge.to.id), let owner = owners[edge.to.key]?.first,
                          let key = GraphIdentityKey(nodeKey: String(owner.dropFirst("artist:".count))) else { moved.insert(edge); continue }
                    var to = MusicNode(kind: .artist, key: key.nodeKey, title: edge.to.title)
                    to.discogsID = Int(key.value)
                    moved.insert(MusicEdge(from: edge.from, to: to, kind: edge.kind, source: edge.source,
                                           reason: edge.reason, confidence: edge.confidence, occurrences: edge.occurrences))
                }
                kept = moved.all
            }
            split[origin] = .init(shared: kept, deviceLocal: [])
            for edge in kept where edge.to.kind == .artist { destinations.insert(edge.to.id) }
        }
        let origins = ExploreRanker.startingPoints(personal)
        var knowledge = LocalKnowledgeAdapter.assemble(
            origins: origins, walked: split, shows: raw.shared.shows, artistTags: raw.shared.artistTags,
            scenes: raw.shared.scenes, libraryCounts: [:])
        knowledge.deviceLocal = .empty

        // Who the listener knows: names they keep, linked to the one entry
        // that answers to each here.
        var linkOwners: [String: Set<GraphIdentityKey>] = [:]
        var namesOf: [String: Set<String>] = [:]
        for (name, ids) in owners {
            for id in ids {
                guard let key = GraphIdentityKey(nodeKey: String(id.dropFirst("artist:".count))) else { continue }
                linkOwners[name, default: []].insert(key)
                namesOf[id, default: []].insert(name)
            }
        }
        for node in (rows.crate.compactMap(\.node) + rows.met.map(\.node) + rows.haunts.map(\.node)) where node.kind == .artist {
            guard let placement = canonicalizer.placement(of: node), placement.key.isVerified else { continue }
            linkOwners[node.key, default: []].insert(placement.key)
            namesOf[placement.key.nodeID, default: []].insert(node.key)
        }
        let history = personal.crate.compactMap(\.node) + personal.met.map(\.node) + personal.haunts.map(\.node)
        let known = KnownArtistPolicy.alsoKnown(history: history, owners: linkOwners, namesOf: { namesOf[$0.id] ?? [$0.key] })
        var ranked = rank(personal: personal, knowledge: knowledge, alsoKnown: known, asOf: asOf, turn: turn, source: source,
                          names: namesOf)
        let verified = destinations.filter { $0.hasPrefix("artist:discogs:") || $0.hasPrefix("artist:mbid:") }.count
        ranked.counts = [
            "identityVerified": verified, "identityUnresolved": destinations.count - verified,
            "identityAliasEdges": aliases, "identityNamesakeCollisions": owners.filter { $0.value.count > 1 }.count,
            "identityKnown": known.count, "identityFolded": dropped.count,
        ]
        return ranked
    }

    // MARK: Reading it

    func describe(_ name: String, against baseline: Ranked) -> [String] {
        let top12 = Set(next.prefix(12).map(\.id)).intersection(baseline.next.prefix(12).map(\.id)).count
        let top20 = Set(all.prefix(20).map(\.id)).intersection(baseline.all.prefix(20).map(\.id)).count
        let theirKeys = baseline.all.prefix(20).map { baseline.keys($0) }
        let top20ByKey = all.prefix(20).filter { mine in theirKeys.contains { !$0.isDisjoint(with: keys(mine)) } }.count
        let reached = baseline.all.prefix(20).filter { reach[$0.id] != nil || place(of: baseline.keys($0)) != nil }.count
        let kinds = Set(knowledge.shared.neighbourhoods.flatMap(\.edges).map(\.kind.rawValue))
            .union(knowledge.shared.shows.isEmpty ? [] : [RelationshipKind.playedInShow.rawValue])
        let missing = Set(baseline.all.prefix(20).map(\.kind.rawValue)).subtracting(kinds).sorted()
        let top = Array(all.prefix(20))
        let topKinds = Dictionary(top.map { ($0.kind.rawValue, 1) }, uniquingKeysWith: +).sorted { $0.key < $1.key }
        let depth = CorroborationDepth.Summary(CorroborationDepth.of(top.map(\.id), personal: personal, knowledge: knowledge))
        let concrete = top.filter { Ranked.isConcrete($0.reason) }.count
        let diversity = Set(top.map(\.via)).count
        let showOverlap = Set(shows.map(\.id)).intersection(baseline.shows.map(\.id)).count
        let edges = knowledge.shared.neighbourhoods.map(\.edges.count).reduce(0, +)
        let code = "FYS\(knowledge.format).\(String(CanonicalDigest.of(personal).prefix(12))).\(String(CanonicalDigest.of(knowledge.shared).prefix(12))).\(String(CanonicalDigest.of(all.map(\.id)).prefix(12)))"
        var lines = ["", "  \(name) — \(source)"]
        lines.append("    code \(code); \(edges) edges, \(knowledge.shared.nodes.count) nodes, \(knowledge.shared.shows.count) shows")
        lines.append("    overlap top 12 \(top12)/12, top 20 \(top20)/20 (\(top20ByKey)/20 matching artists across keys); reaches \(reached)/20 of the visible top 20")
        lines.append("    candidates \(reach.count); top 20 by kind \(topKinds.map { "\($0.key) \($0.value)" }.joined(separator: ", ")); missing kinds \(missing)")
        lines.append("    depth \(depth.line)")
        lines.append("    explanations naming a record, label or show \(concrete)/\(top.count); starting points behind the top 20 \(diversity)")
        lines.append("    shows \(shows.count) (\(showOverlap) as visible); direction \(direction)")
        lines.append("    identity " + counts.sorted { $0.key < $1.key }.map { "\($0.key.replacingOccurrences(of: "identity", with: ""))=\($0.value)" }.joined(separator: " "))
        lines.append("    top 20: " + top.enumerated().map { "\($0.offset + 1). \($0.element.node.title) (\($0.element.kind.rawValue)×\($0.element.corroboration))" }.joined(separator: "; "))
        return lines
    }

    /// Whether a reason says what it rests on — a record, a label, a show —
    /// rather than a resemblance.
    static func isConcrete(_ reason: String) -> Bool {
        let generic = ["Also tagged", "Credited together", "Same era", "Same scene", "Same city", "Shared sound", "Also on"]
        if generic.contains(where: { reason.hasPrefix($0) }) && !reason.contains(" on ") { return false }
        return [" on ", "Releases on", "Played", "together", "Appears on", "Released"].contains { reason.contains($0) }
    }
}
