//
//  ExploreIdentityShadowMeasurement.swift
//  IndigoTests
//
//  What verified artist identity would change in For You, measured on a copy
//  of this Mac's own stores, without changing anything the app does.
//
//  Opt-in: runs only when `audit/explore-identity/RUN` exists in the app's
//  Application Support. It copies the Production stores into a temporary
//  directory first, so the stores the app uses are only read, and writes its
//  report to `audit/explore-identity/report.txt`.
//
//  The copy holds no identity evidence yet (the live stores are V7), so the
//  measurement first gathers the cheap evidence: release credits from the
//  public R2 documents, written into the copy. Spelling checks and entry reads
//  cost Discogs requests and are not made; what they would add is reported as
//  candidates, never counted as merges.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ExploreIdentityShadowMeasurement: XCTestCase {
    private var support: URL { StoreLayout.standard.directory }
    private var folder: URL { support.appendingPathComponent("audit/explore-identity", isDirectory: true) }

    func testShadowIdentityOnThisMacsStores() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder.appendingPathComponent("RUN").path),
                          "Create audit/explore-identity/RUN to measure.")
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExploreIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for name in ["UserData.store", "Local.store"] {
            for suffix in ["", "-wal", "-shm"] {
                let from = support.appendingPathComponent(name + suffix)
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name + suffix))
            }
        }
        let container = try Persistence.makeSplitContainer(
            userData: copy.appendingPathComponent("UserData.store"),
            local: copy.appendingPathComponent("Local.store"))
        let context = ModelContext(container)
        var out: [String] = []

        // Today's answer.
        let asOf = ExplorePeriod.asOf(ExplorePeriod.containing(Date()))
        let personal = PersonalInputs.read(context: context, asOf: asOf)
        let adapter = LocalKnowledgeAdapter(context: context)
        let before = adapter.snapshot(for: personal, scenes: false)
        let offersBefore = ExploreRanker.offers(personal: personal, knowledge: before, asOf: asOf)
        let sets = ExploreRanker.edgeSets(before)
        let origins = ExploreRanker.startingPoints(personal)
        let artistNodes = Set((before.shared.nodes + before.deviceLocal.nodes).filter { $0.kind == .artist })
        out.append("starting points: \(origins.count) (\(origins.filter { $0.kind == .artist }.count) artists)")
        out.append("snapshot: \(before.shared.nodes.count) shared nodes, \(artistNodes.count) artist nodes, \(sets.values.reduce(0) { $0 + $1.all.count }) edges")

        // Evidence: kept credits for every release the snapshot names and every
        // release on a starting artist's own shelf, from R2.
        let enricher = DiscogsEnricher(context: context, client: DiscogsClient())
        func filed(_ node: MusicNode) -> DiscogsArtist? {
            guard let record = enricher.cachedArtist(named: node.title), record.discogsID > 0,
                  ArtistSpelling.filingKey(record.name) == ArtistSpelling.key(node.title) else { return nil }
            return record
        }
        var releaseIDs = Set((before.shared.nodes + before.deviceLocal.nodes).compactMap { $0.kind == .release ? $0.discogsID : nil })
        for origin in origins where origin.kind == .artist {
            releaseIDs.formUnion(filed(origin)?.releaseDiscogsIDs.filter { $0 > 0 } ?? [])
        }
        let wanted = Array(releaseIDs.sorted().prefix(800))
        let fetched = await Self.storedReleases(wanted)
        let credits = ReleaseCreditStore(context: context)
        var written = 0, missing = 0, failed = 0
        for id in wanted {
            switch fetched[id] {
            case .document(let detail)?: if credits.replace(releaseID: id, from: detail, source: ReleaseCreditStore.source(storedRelease: id)) { written += 1 }
            case .missing?: missing += 1
            default: failed += 1
            }
        }
        try context.save()
        out.append("evidence: \(wanted.count) releases asked of R2 — \(written) documents with credits, \(missing) missing, \(failed) failed")

        // 1. Which artist nodes would be one destination: each node identified
        // by what it stands for, through the one identifier the graph uses.
        let store = DigStore(context: context)
        let identifier = ArtistNodeIdentifier(store: store)
        var byIdentity: [String: Set<String>] = [:]
        var described: [String: [String]] = [:]
        var provenance: [ArtistNodeIdentity.Provenance: Int] = [:]
        var inferred: [String] = []
        var conflicts: [String] = []
        for node in artistNodes {
            let found = identifier.identify(node)
            provenance[found.provenance, default: 0] += 1
            if found.provenance == .inferred {
                inferred.append("\"\(node.title)\" key=\(node.key) carried discogs:\(found.carriedDiscogsID ?? 0)")
            }
            if let carried = found.carriedDiscogsID, let verified = found.identity.discogsID, found.isVerified, carried != verified {
                conflicts.append("\"\(node.title)\" carried discogs:\(carried), verified \(found.identity.rawValue) (\(found.provenance.rawValue))")
            }
            guard found.isVerified else { continue }
            byIdentity[found.identity.rawValue, default: []].insert(node.key)
            described[found.identity.rawValue, default: []].append(
                "\"\(node.title)\" key=\(node.key) carried=\(found.carriedDiscogsID.map(String.init) ?? "-") \(found.provenance.rawValue)")
        }
        let merges = byIdentity.filter { $0.value.count > 1 }
        let order: [ArtistNodeIdentity.Provenance] = [.credit, .resolver, .filedRecord, .inferred, .nameOnly]
        out.append("artist nodes by provenance: " + order.map { "\($0.rawValue) \(provenance[$0] ?? 0)" }.joined(separator: ", "))
        out.append("inferred ids (kept, not trusted): \(inferred.count)")
        inferred.sorted().prefix(15).forEach { out.append("  \($0)") }
        out.append("carried ids overruled by verified evidence: \(conflicts.count)")
        conflicts.sorted().prefix(15).forEach { out.append("  \($0)") }
        out.append("merges (one identity, several node keys): \(merges.count)")
        for (identity, keys) in merges.sorted(by: { $0.key < $1.key }).prefix(25) {
            out.append("  \(identity): \(keys.sorted().joined(separator: " | "))")
            for line in (described[identity] ?? []).sorted() { out.append("    \(line)") }
        }
        // Spacing/punctuation lookalikes among the nodes: what a spelling check
        // might settle. Reported, never merged.
        var lookalikes: [String: Set<String>] = [:]
        for node in artistNodes { lookalikes[ArtistSpelling.compact(node.title), default: []].insert(node.key) }
        let candidates = lookalikes.filter { $0.value.count > 1 }
        out.append("lookalike groups needing a spelling check (not merged): \(candidates.count)")
        for (_, keys) in candidates.sorted(by: { $0.key < $1.key }).prefix(15) { out.append("  \(keys.sorted().joined(separator: " | "))") }

        // 2. Relationships the credits would exclude, and paths that would change.
        var excluded: [String] = []
        var gainedIDs: [String] = []
        var redirected: [String] = []
        var shadowSets: [MusicNode: EdgeSet] = [:]
        var weakEdges = 0, strongEdges = 0
        for (origin, set) in sets {
            let subject = origin.kind == .artist ? (origin.discogsID ?? filed(origin)?.discogsID) : nil
            let keys: Set<String> = [RecordingKey.normalizeArtist(origin.title)]
            // The origin's own releases' credits, by credited spelling.
            var creditIDs: [String: ReleaseCredit] = [:]
            if origin.kind == .artist {
                for id in filed(origin)?.releaseDiscogsIDs ?? [] {
                    for credit in credits.credits(releaseID: id) ?? [] where credit.discogsID != nil {
                        creditIDs[RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(credit.creditedName))] = credit
                    }
                }
            }
            var kept = EdgeSet()
            for edge in set.all {
                var edge = edge
                if origin.kind == .artist, edge.to.kind == .release, let releaseID = edge.to.discogsID {
                    let decided = ReleaseAttribution.decide(subjectID: subject, subjectKeys: keys, credits: credits.credits(releaseID: releaseID))
                    if !decided.isShown {
                        excluded.append("\(origin.title) → \(edge.to.title) [\(decided.evidence)]")
                        continue
                    }
                }
                if edge.to.kind == .artist, edge.to.discogsID == nil,
                   edge.kind == .producer || edge.kind == .personnel,
                   let credit = creditIDs[RecordingKey.normalizeArtist(edge.to.title)], let id = credit.discogsID {
                    let target = MusicNode.artist(credit.name, discogsID: id)
                    if target.key != edge.to.key { redirected.append("\(origin.title): \(edge.to.title) → \(credit.name) (discogs:\(id))") }
                    else { gainedIDs.append("\(origin.title): \(edge.to.title) gains discogs:\(id)") }
                    edge = MusicEdge(from: edge.from, to: target, kind: edge.kind, source: edge.source,
                                     reason: edge.reason, confidence: edge.confidence, occurrences: edge.occurrences)
                }
                switch edge.source {
                case .discogs, .musicBrainz: strongEdges += 1
                default: weakEdges += 1
                }
                kept.insert(edge)
            }
            shadowSets[origin] = kept
        }
        out.append("relationships excluded as another artist's: \(excluded.count)")
        excluded.prefix(25).forEach { out.append("  \($0)") }
        out.append("credit paths gaining a Discogs id: \(gainedIDs.count); redirected to another destination: \(redirected.count)")
        redirected.prefix(25).forEach { out.append("  \($0)") }
        gainedIDs.prefix(10).forEach { out.append("  \($0)") }
        out.append("edge sources: \(strongEdges) catalogue (Discogs/MusicBrainz), \(weakEdges) radio/library/Bandcamp/scene/other")

        // 3. What For You would offer with credit ids on its edges (a preview of
        // Step 3; the canonical graph is measured on its own below).
        var walked: [MusicNode: LocalKnowledgeAdapter.Walked] = [:]
        for origin in origins {
            let edges = shadowSets[origin]?.all ?? []
            walked[origin] = LocalKnowledgeAdapter.Walked(
                shared: edges.filter { $0.source != .library }, deviceLocal: edges.filter { $0.source == .library })
        }
        let after = LocalKnowledgeAdapter.assemble(
            origins: origins, walked: walked, shows: before.shared.shows, artistTags: before.shared.artistTags,
            scenes: nil, libraryCounts: [:])
        let offersAfter = ExploreRanker.offers(personal: personal, knowledge: after, asOf: asOf)
        func ids(_ offers: ExploreOffers) -> [String] { (offers.next + offers.artists + offers.shows).map { $0.node.title } }
        let was = ids(offersBefore), now = ids(offersAfter)
        out.append("For You offers: before \(was.count), after \(now.count)")
        out.append("  disappeared: \(was.filter { !now.contains($0) })")
        out.append("  appeared: \(now.filter { !was.contains($0) })")
        out.append("  same order: \(was == now)")

        // 4. The identity-keyed graph (Step 2): on today's edges, and on the
        // edges as Step 3 would give them (credit ids on credit links).
        func canonicalReport(_ title: String, _ sets: [MusicNode: EdgeSet]) {
        out.append("")
        out.append("== canonical graph (shadow): \(title) ==")
        let graph = GraphCanonicalizer(identify: identifier.identify)
        let artistNodes = Set(sets.values.flatMap { $0.all.flatMap { [$0.from, $0.to] } }.filter { $0.kind == .artist }).union(artistNodes)
        let personalNodes = personal.crate.compactMap(\.node) + personal.met.map(\.node) + personal.haunts.map(\.node)
        for node in artistNodes.sorted(by: { $0.id < $1.id }) + personalNodes.filter({ $0.kind == .artist }) {
            _ = graph.placement(of: node)
        }
        let placements = graph.placements
        var byClass: [EvidenceClass: Int] = [:]
        for placement in placements { byClass[placement.evidence, default: 0] += 1 }
        let placedKeys = Set(placements.map(\.key))
        out.append("placements: \(placements.count) references -> \(placedKeys.filter(\.isVerified).count) verified identity nodes, \(placedKeys.filter { !$0.isVerified }.count) unresolved name nodes")
        out.append("  by evidence: " + EvidenceClass.allCases.map { "\($0) \(byClass[$0] ?? 0)" }.joined(separator: ", "))
        var legaciesByKey: [GraphIdentityKey: Set<String>] = [:]
        var keysByLegacy: [String: Set<GraphIdentityKey>] = [:]
        for placement in placements {
            legaciesByKey[placement.key, default: []].insert(placement.reference.key)
            keysByLegacy[placement.reference.key, default: []].insert(placement.key)
        }
        let canonicalMerges = legaciesByKey.filter { $0.key.isVerified && $0.value.count > 1 }
        let owners = graph.ownersByLegacyKey
        let namesakeSplits = owners.filter { $0.value.count > 1 }
        let overlaps = keysByLegacy.filter { legacy, keys in keys.contains { !$0.isVerified } && (owners[legacy]?.count ?? 0) == 1 }
        out.append("merges: \(canonicalMerges.count)")
        for (key, legacies) in canonicalMerges.sorted(by: { $0.key < $1.key }) { out.append("  \(key): \(legacies.sorted().joined(separator: " | "))") }
        out.append("namesake splits (one name, several verified entries): \(namesakeSplits.count)")
        for (legacy, keys) in namesakeSplits.sorted(by: { $0.key < $1.key }) { out.append("  \(legacy): \(keys.sorted().map(\.description).joined(separator: ", "))") }
        out.append("names reached both verified and unresolved (linked by name, not merged): \(overlaps.count)")
        out.append("  e.g. " + overlaps.keys.sorted().prefix(8).joined(separator: ", "))
        let ambiguous = personalNodes.filter { node in
            node.kind == .artist && GraphIdentityKey(nodeKey: graph.canonical(node).key) == nil
                && (keysByLegacy[node.key]?.contains { $0.isVerified } ?? false)
        }
        out.append("history references kept on their name though a verified identity shares it: \(ambiguous.count)")
        ambiguous.prefix(10).forEach { out.append("  \($0.title)") }

        var edgesIn = 0, edgesOut = 0, selfLoops = 0, retargeted = 0
        var canonicalSets: [MusicNode: [MusicEdge]] = [:]
        for (origin, set) in sets.sorted(by: { $0.key.id < $1.key.id }) {
            let all = set.all
            edgesIn += all.count
            for edge in all {
                let canonical = graph.canonical(edge)
                if canonical.from.id == canonical.to.id { selfLoops += 1 }
                if edge.to.kind == .artist, GraphIdentityKey(nodeKey: canonical.to.key) != nil { retargeted += 1 }
            }
            let folded = graph.canonical(all)
            edgesOut += folded.count
            let canonicalOrigin = graph.canonical(origin)
            canonicalSets[canonicalOrigin, default: []] += folded
        }
        out.append("edges: \(edgesIn) -> \(edgesOut); duplicates folded \(edgesIn - edgesOut - selfLoops), self-loops dropped \(selfLoops)")
        out.append("edge destinations moved onto an identity key: \(retargeted)")

        let canonicalPersonal = graph.canonical(personal)
        let canonicalOrigins = ExploreRanker.startingPoints(canonicalPersonal)
        var canonicalWalked: [MusicNode: LocalKnowledgeAdapter.Walked] = [:]
        for origin in canonicalOrigins {
            let edges = graph.canonical(canonicalSets[origin] ?? [])
            canonicalWalked[origin] = LocalKnowledgeAdapter.Walked(
                shared: edges.filter { $0.source != .library }, deviceLocal: edges.filter { $0.source == .library })
        }
        let canonicalKnowledge = LocalKnowledgeAdapter.assemble(
            origins: canonicalOrigins, walked: canonicalWalked, shows: before.shared.shows,
            artistTags: before.shared.artistTags, scenes: nil, libraryCounts: [:])
        // Read the way a visible switch must: an artist the listener knows by
        // name is known under every identity that name was placed under. Given
        // to the ranker as encounters of weight nothing — excluded from what is
        // offered, never a starting point — so its own rules do the rest.
        let knownNames = Set((canonicalPersonal.crate.compactMap(\.node) + canonicalPersonal.met.map(\.node)
            + canonicalPersonal.haunts.map(\.node)).filter { $0.kind == .artist }.map(\.key))
        let nameOwners = graph.ownersByLegacyKey
        var linkedPersonal = canonicalPersonal
        let linked: [GraphIdentityKey] = knownNames.sorted().flatMap { name in (nameOwners[name] ?? []).sorted() }
        linkedPersonal.met += linked.map { key in
            PersonalInputs.Met(node: MusicNode(kind: .artist, key: key.nodeKey, title: key.value),
                               weight: 0, lastAt: .distantPast)
        }
        let canonicalOffers = ExploreRanker.offers(personal: linkedPersonal, knowledge: canonicalKnowledge, asOf: asOf)
        func ranked(_ offers: ExploreOffers, through map: (MusicNode) -> MusicNode) -> [String] {
            (offers.next + offers.artists + offers.shows).map { map($0.node).id }
        }
        let baseline = ranked(offersBefore, through: graph.canonical)
        let shadow = ranked(canonicalOffers, through: { $0 })
        out.append("identities known by name, not offered back: \(linked.count)")
        out.append("starting points: \(origins.count) -> \(canonicalOrigins.count)")
        out.append("For You candidates: before \(baseline.count), shadow \(shadow.count)")
        out.append("  lost: \(baseline.filter { !shadow.contains($0) })")
        out.append("  gained: \(shadow.filter { !baseline.contains($0) })")
        let topBefore = Array(baseline.prefix(6)), topShadow = Array(shadow.prefix(6))
        out.append("  top 6 identical: \(topBefore == topShadow)")
        if topBefore != topShadow {
            out.append("    before: \(topBefore)")
            out.append("    shadow: \(topShadow)")
        }

        }
        canonicalReport("today's edges", sets)
        canonicalReport("with credit ids (Step 3 preview)", shadowSets)

        let text = out.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(text)
    }

    /// R2 documents, eight at a time, each answered as a document, missing, or
    /// unavailable. The app's own reader refuses in a test process; this is
    /// the same read.
    nonisolated private static func storedReleases(_ ids: [Int]) async -> [Int: DigStore.StoredReleaseRead] {
        await withTaskGroup(of: (Int, DigStore.StoredReleaseRead).self) { group in
            var found: [Int: DigStore.StoredReleaseRead] = [:]
            var pending = ids.makeIterator()
            func next() -> Bool {
                guard let id = pending.next() else { return false }
                group.addTask { (id, await read(id)) }
                return true
            }
            for _ in 0..<8 { _ = next() }
            for await (id, outcome) in group {
                found[id] = outcome
                _ = next()
            }
            return found
        }
    }

    nonisolated private static func read(_ id: Int) async -> DigStore.StoredReleaseRead {
        guard let url = MetadataRepository.storedObjectURL(forPath: MetadataRepository.releasePath(id: String(id))) else { return .unavailable }
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10)),
              let http = response as? HTTPURLResponse else { return .unavailable }
        if http.statusCode == 404 { return .missing }
        guard http.statusCode == 200, let detail = try? JSONDecoder().decode(DiscogsReleaseDetail.self, from: data) else { return .unavailable }
        return .document(detail)
    }
}
