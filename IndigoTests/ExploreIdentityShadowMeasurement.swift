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

    /// DIG's graph as the listener sees it — DEEP and RELATED — on today's
    /// code (the name-keyed walk) and on the identity graph, for the listener's
    /// own artists and the ones these tests name.
    private func visibleComparison(_ label: String, context: ModelContext, origins starting: [MusicNode]) -> [String] {
        var out = ["", "== visible Explore (\(label)) =="]
        let store = DigStore(context: context)
        let named = ["Prefuse 73", "Prefuse73", "Scott Herren", "Piano Overlord", "Hype Williams", "Dean Blunt",
                     "Joanne Robertson", "Attilio Novellino", "Ciro Vitiello"]
        var names = starting.filter { $0.kind == .artist }.map(\.title)
        let filedKeys = Set(((try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? []).map(\.nameKey))
        names += named.filter { filedKeys.contains(RecordingKey.normalizeArtist($0)) }
        var seen = Set<String>()
        names = names.filter { seen.insert(RecordingKey.normalizeArtist($0)).inserted }

        var totals = (before: 0, after: 0, merged: 0, split: 0, lost: 0, byEntry: 0, duplicateTitles: 0, reordered: 0)
        var details: [String] = []
        var unexplainedSwaps = 0
        for name in names {
            let page = store.artistPage(ArtistReference(name: name))
            let today = GraphStore(context: context)
            let identity = IdentityGraph(context: context)
            let origin = MusicNode.artist(page.name, discogsID: page.discogsID)
            // DEEP: every destination one step out.
            let beforeRows = today.neighbors(of: .artist(page.name)).byDestination.map(\.node)
            let walked = identity.neighbourhood(of: origin)
            let afterRows = walked.edges.byDestination.map(\.node)
            let afterKeys = Dictionary(uniqueKeysWithValues: afterRows.map { ($0.id, walked.knownIDs(of: $0)) })
            var merged: [String] = [], split: [String] = [], lost: [String] = []
            for row in afterRows where (afterKeys[row.id] ?? []).count > 1 {
                let covered = beforeRows.filter { (afterKeys[row.id] ?? []).contains($0.id) }
                if covered.count > 1 { merged.append("\(row.title) [\(row.id)] ← \(covered.map(\.title).sorted())") }
            }
            for row in beforeRows {
                let holders = afterRows.filter { (afterKeys[$0.id] ?? [$0.id]).contains(row.id) }
                if holders.isEmpty { lost.append("\(row.title) [\(row.id)]") }
                if holders.count > 1 { split.append("\(row.title) → \(holders.map(\.id).sorted())") }
            }
            var titles: [String: Int] = [:]
            for row in afterRows where row.kind == .artist { titles[row.title, default: 0] += 1 }
            let duplicates = titles.filter { $0.value > 1 }.keys.sorted()
            let byEntry = afterRows.filter { $0.kind == .artist && GraphIdentityKey(nodeKey: $0.key) != nil }.count

            // RELATED: today's list and the page's, in the order they are shown,
            // matched by node — a merged row stands for every name behind it.
            let relatedBefore = today.relatedArtists(to: .artist(page.name)).map(\.node)
            let relatedAfter = DigEngine(context: context).relatedArtists(to: page.name, discogsID: page.discogsID)
            let family = today.aliasKeys(of: .artist(page.name))
            let afterNodes = walked.edges.byDestination.map(\.node).filter { node in
                node.kind == .artist && (walked.keys[node.id] ?? [node.key]).isDisjoint(with: family)
            }
            var rank: [String: Int] = [:]
            for (index, node) in afterNodes.enumerated() {
                for id in walked.knownIDs(of: node) where rank[id] == nil { rank[id] = index }
            }
            // Each swap explained, or not: a row whose title or confidence the
            // identity changed moves; anything else moving is unexpected.
            let beforeByID = Dictionary(today.relatedArtists(to: .artist(page.name)).map { ($0.node.id, $0) }, uniquingKeysWith: { a, _ in a })
            let afterByIndex = walked.edges.byDestination.filter { node in
                node.node.kind == .artist && (walked.keys[node.node.id] ?? [node.node.key]).isDisjoint(with: family)
            }
            func changed(_ before: MusicNode) -> Bool {
                guard let index = rank[before.id], let old = beforeByID[before.id] else { return true }
                let new = afterByIndex[index]
                return new.node.title != old.node.title || abs(new.confidence - old.confidence) > 1e-9
            }
            let commonNodes = relatedBefore.filter { rank[$0.id] != nil }
            let common = commonNodes.map { rank[$0.id]! }
            var reordered = 0, unexplained: [String] = []
            for i in common.indices {
                for j in common.indices where j > i && common[i] > common[j] {
                    reordered += 1
                    if !changed(commonNodes[i]) && !changed(commonNodes[j]) {
                        unexplained.append("\(commonNodes[i].title) / \(commonNodes[j].title)")
                    }
                }
            }
            unexplainedSwaps += unexplained.count
            unexplained.prefix(5).forEach { details.append("    unexplained swap: \($0)") }
            XCTAssertEqual(afterNodes.count, relatedAfter.count, "The audit reads RELATED as the page does")

            totals.before += beforeRows.count; totals.after += afterRows.count
            totals.merged += merged.count; totals.split += split.count; totals.lost += lost.count
            totals.byEntry += byEntry; totals.duplicateTitles += duplicates.count; totals.reordered += reordered
            details.append("  \(name) → page \(page.name) [\(page.discogsID.map { "discogs:\($0)" } ?? "name")]: DEEP \(beforeRows.count) → \(afterRows.count) rows, \(byEntry) by entry; RELATED \(relatedBefore.count) → \(relatedAfter.count), \(reordered) pairs swapped")
            merged.forEach { details.append("    merged: \($0)") }
            split.forEach { details.append("    split: \($0)") }
            lost.prefix(10).forEach { details.append("    lost: \($0)") }
            duplicates.forEach { details.append("    same title twice: \($0)") }
            for row in relatedAfter where row.discogsID != nil && named.contains(row.name) {
                details.append("    RELATED \(row.name) opens discogs:\(row.discogsID!) — \(row.reasons.map(\.kind.rawValue).sorted())")
            }
        }
        out.append("pages: \(names.count); DEEP rows \(totals.before) → \(totals.after); by entry \(totals.byEntry); merged \(totals.merged); split \(totals.split); lost \(totals.lost); same title twice \(totals.duplicateTitles); RELATED pairs swapped \(totals.reordered), of them not explained by a re-titled or merged row \(unexplainedSwaps)")
        out.append("names waiting for a uniqueness check: \(IdentityChecks.shared.take(1000))")
        return out + details
    }

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

        out += visibleComparison("the store's own evidence, as on this device today", context: context, origins: origins)

        // Evidence: kept credits for every release the snapshot names and every
        // release on a starting artist's own shelf, from R2.
        let enricher = DiscogsEnricher(context: context, client: DiscogsClient())
        func filed(_ node: MusicNode) -> DiscogsArtist? {
            guard let record = enricher.cachedArtist(named: node.title), record.discogsID > 0,
                  ArtistSpelling.filingKey(record.name) == ArtistSpelling.key(node.title) else { return nil }
            return record
        }
        var releaseIDs = Set((before.shared.nodes + before.deviceLocal.nodes).compactMap { $0.kind == .release ? $0.discogsID : nil })
        // Exactly the releases the production scope reads for each origin.
        let fetchScope = CreditEdgeScope(context: context, graph: GraphStore(context: context))
        for origin in origins where origin.kind == .artist {
            releaseIDs.formUnion(fetchScope.releases(of: origin))
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

        // 2. Release edges ReleaseAttribution gives to somebody else.
        var excluded: [String] = []
        for (origin, set) in sets where origin.kind == .artist {
            let subject = origin.discogsID ?? filed(origin)?.discogsID
            for edge in set.all where edge.to.kind == .release {
                guard let releaseID = edge.to.discogsID else { continue }
                let decided = ReleaseAttribution.decide(subjectID: subject, subjectKeys: [origin.key],
                                                        credits: credits.credits(releaseID: releaseID))
                if !decided.isShown { excluded.append("\(origin.title) → \(edge.to.title) [\(decided.evidence)]") }
            }
        }
        out.append("relationships another artist's credits would exclude: \(excluded.count)")
        excluded.prefix(15).forEach { out.append("  \($0)") }

        // 3. Credit ids on credit edges (Step 3), from the production scope.
        let scope = CreditEdgeScope(context: context, graph: GraphStore(context: context))
        var creditSets: [MusicNode: EdgeSet] = [:]
        var corrected: [String] = []
        var gained = 0, creditEdges = 0, ambiguousSpellings = 0
        for (origin, set) in sets.sorted(by: { $0.key.id < $1.key.id }) {
            let entries = CreditEdgeIdentity.entries(in: scope.credits(behind: origin))
            let attached = CreditEdgeIdentity.attach(set.all, entries: entries)
            var kept = EdgeSet()
            for (before, after) in zip(set.all, attached) {
                if before.kind.isCreditBacked, before.to.kind == .artist { creditEdges += 1 }
                if before.to.discogsID == nil, let id = after.to.discogsID {
                    gained += 1
                    let entry = entries[before.to.key]?.name ?? ""
                    if RecordingKey.normalizeArtist(entry) != before.to.key {
                        corrected.append("\(origin.title): \(before.to.title) → \(entry) (discogs:\(id), \(before.kind))")
                    }
                } else if before.kind.isCreditBacked, before.to.kind == .artist, before.to.discogsID == nil {
                    // A spelling credits in scope name with two entries.
                    let credited = scope.credits(behind: origin).filter {
                        RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator($0.creditedName)) == before.to.key
                    }
                    if Set(credited.compactMap(\.discogsID)).count > 1 { ambiguousSpellings += 1 }
                }
                kept.insert(after)
            }
            creditSets[origin] = kept
        }
        out.append("credit edges to artists: \(creditEdges); gaining a Discogs id: \(gained); reaching a differently named entry: \(corrected.count); left on their name, spelling names several entries: \(ambiguousSpellings)")
        corrected.prefix(25).forEach { out.append("  \($0)") }

        // 4. The identity-keyed graph, on today's edges and on the credit edges.
        func canonicalReport(_ title: String, _ sets: [MusicNode: EdgeSet]) -> [String] {
            out.append("")
            out.append("== canonical graph (shadow): \(title) ==")
            let graph = GraphCanonicalizer(identify: identifier.identify)
            let nodes = Set(sets.values.flatMap { $0.all.flatMap { [$0.from, $0.to] } }.filter { $0.kind == .artist }).union(artistNodes)
            let personalNodes = personal.crate.compactMap(\.node) + personal.met.map(\.node) + personal.haunts.map(\.node)
            for node in nodes.sorted(by: { $0.id < $1.id }) + personalNodes.filter({ $0.kind == .artist }) {
                _ = graph.placement(of: node)
            }
            let placements = graph.placements
            var byClass: [EvidenceClass: Int] = [:]
            for placement in placements { byClass[placement.evidence, default: 0] += 1 }
            let keys = Set(placements.map(\.key))
            out.append("nodes: \(keys.filter(\.isVerified).count) verified identities, \(keys.filter { !$0.isVerified }.count) unresolved names (from \(placements.count) references)")
            out.append("  evidence: " + EvidenceClass.allCases.map { "\($0) \(byClass[$0] ?? 0)" }.joined(separator: ", "))
            var legacies: [GraphIdentityKey: Set<String>] = [:]
            var keysByLegacy: [String: Set<GraphIdentityKey>] = [:]
            for placement in placements {
                legacies[placement.key, default: []].insert(placement.reference.key)
                keysByLegacy[placement.reference.key, default: []].insert(placement.key)
            }
            let owners = graph.ownersByLegacyKey
            let merges = legacies.filter { $0.key.isVerified && $0.value.count > 1 }
            let collisions = owners.filter { $0.value.count > 1 }
            out.append("merges (one identity, several names): \(merges.count)")
            merges.sorted { $0.key < $1.key }.forEach { out.append("  \($0.key): \($0.value.sorted().joined(separator: " | "))") }
            out.append("namesake collisions (one name, several verified identities): \(collisions.count)")
            collisions.sorted { $0.key < $1.key }.forEach { out.append("  \($0.key): \($0.value.sorted().map(\.description).joined(separator: ", "))") }
            let overlaps = keysByLegacy.filter { legacy, keys in keys.contains { !$0.isVerified } && owners[legacy]?.count == 1 }
            out.append("names reached both verified and unresolved (linked, not merged): \(overlaps.count)")

            var edgesIn = 0, edgesOut = 0, loops = 0
            var canonicalSets: [MusicNode: [MusicEdge]] = [:]
            for (origin, set) in sets.sorted(by: { $0.key.id < $1.key.id }) {
                edgesIn += set.all.count
                for edge in set.all { let c = graph.canonical(edge); if c.from.id == c.to.id { loops += 1 } }
                let folded = graph.canonical(set.all)
                edgesOut += folded.count
                canonicalSets[graph.canonical(origin), default: []] += folded
            }
            out.append("edges: \(edgesIn) -> \(edgesOut); duplicates folded \(edgesIn - edgesOut - loops), self-loops \(loops)")

            let canonicalPersonal = graph.canonical(personal)
            let canonicalOrigins = ExploreRanker.startingPoints(canonicalPersonal)
            var walked: [MusicNode: LocalKnowledgeAdapter.Walked] = [:]
            for origin in canonicalOrigins {
                let edges = graph.canonical(canonicalSets[origin] ?? [])
                walked[origin] = LocalKnowledgeAdapter.Walked(
                    shared: edges.filter { $0.source != .library }, deviceLocal: edges.filter { $0.source == .library })
            }
            let knowledge = LocalKnowledgeAdapter.assemble(
                origins: canonicalOrigins, walked: walked, shows: before.shared.shows,
                artistTags: before.shared.artistTags, scenes: nil, libraryCounts: [:])
            let history = canonicalPersonal.crate.compactMap(\.node) + canonicalPersonal.met.map(\.node) + canonicalPersonal.haunts.map(\.node)
            let alsoKnown = KnownArtistPolicy.alsoKnown(history: history, owners: owners, namesOf: graph.legacyKeys(of:))
            let withPolicy = ExploreRanker.offers(personal: canonicalPersonal, knowledge: knowledge, asOf: asOf, alsoKnown: alsoKnown)
            let withoutPolicy = ExploreRanker.offers(personal: canonicalPersonal, knowledge: knowledge, asOf: asOf)
            func ranked(_ offers: ExploreOffers) -> [String] { (offers.next + offers.artists + offers.shows).map(\.node.id) }
            let baseline = (offersBefore.next + offersBefore.artists + offersBefore.shows).map { graph.canonical($0.node).id }
            let shadow = ranked(withPolicy), unguarded = ranked(withoutPolicy)
            out.append("known-artist policy: \(alsoKnown.count) ids known beyond the history; it keeps out \(unguarded.filter { !shadow.contains($0) })")
            out.append("For You: before \(baseline.count), shadow \(shadow.count)")
            out.append("  lost: \(baseline.filter { !shadow.contains($0) })")
            out.append("  gained: \(shadow.filter { !baseline.contains($0) })")
            out.append("  top 6 identical: \(Array(baseline.prefix(6)) == Array(shadow.prefix(6)))")
            let moved = zip(baseline, shadow).enumerated().filter { $0.element.0 != $0.element.1 }.map { "#\($0.offset + 1) \($0.element.0) → \($0.element.1)" }
            out.append("  positions that differ: \(moved.count)")
            moved.prefix(12).forEach { out.append("    \($0)") }
            func listing(_ offers: ExploreOffers) -> [String] {
                (offers.next + offers.artists + offers.shows).enumerated().map { index, suggestion in
                    "#\(index + 1) \(String(format: "%.4f", suggestion.score)) \(suggestion.node.title) [\(suggestion.node.id)] via \(suggestion.via) \(suggestion.kind)"
                }
            }
            out.append("  before, in full:")
            listing(offersBefore).forEach { out.append("    \($0)") }
            out.append("  shadow, in full:")
            listing(withPolicy).forEach { out.append("    \($0)") }
            return shadow
        }
        _ = canonicalReport("today's edges", sets)
        _ = canonicalReport("credit ids on credit edges (Step 3)", creditSets)

        // 5. The final shadow: walked through IdentityGraph exactly as a visible
        // switch would walk it, compared with today's answer.
        out.append("")
        out.append("== final shadow (IdentityGraph) vs today ==")
        let shadowGraph = IdentityGraph(context: context)
        let finalPersonal = shadowGraph.canonicalizer.canonical(personal)
        let finalOrigins = ExploreRanker.startingPoints(finalPersonal)
        var finalWalked: [MusicNode: [MusicEdge]] = [:]
        for origin in finalOrigins { finalWalked[origin] = shadowGraph.neighbors(of: origin) }
        for node in Set(finalWalked.values.flatMap { $0.map(\.to) }).sorted(by: { $0.id < $1.id }) where node.kind == .artist {
            _ = shadowGraph.canonicalizer.placement(of: node)
        }
        let finalPlacements = shadowGraph.canonicalizer.placements
        let finalOwners = shadowGraph.canonicalizer.ownersByLegacyKey
        var finalLegacies: [GraphIdentityKey: Set<String>] = [:]
        for placement in finalPlacements where placement.key.isVerified {
            finalLegacies[placement.key, default: []].insert(placement.reference.key)
        }
        let reached = Set(finalWalked.values.flatMap { $0.map(\.to) }.filter { $0.kind == .artist })
        out.append("artist nodes reached from the starting points: \(reached.filter { GraphIdentityKey(nodeKey: $0.key) != nil }.count) verified, \(reached.filter { GraphIdentityKey(nodeKey: $0.key) == nil }.count) unresolved")
        out.append("merges: \(finalLegacies.filter { $0.value.count > 1 }.count)")
        finalLegacies.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }.forEach { out.append("  \($0.key): \($0.value.sorted().joined(separator: " | "))") }
        out.append("namesake collisions: \(finalOwners.filter { $0.value.count > 1 }.count)")
        let todayDestinations = Set(sets.values.flatMap { $0.all.map(\.to.id) })
        let changed = reached.filter { GraphIdentityKey(nodeKey: $0.key) != nil }.count
        out.append("destinations now an identity: \(changed) (of \(todayDestinations.count) destinations today)")

        func assemble(_ walked: [MusicNode: [MusicEdge]]) -> KnowledgeSnapshot {
            var split: [MusicNode: LocalKnowledgeAdapter.Walked] = [:]
            for (origin, edges) in walked {
                split[origin] = LocalKnowledgeAdapter.Walked(
                    shared: edges.filter { $0.source != .library }, deviceLocal: edges.filter { $0.source == .library })
            }
            return LocalKnowledgeAdapter.assemble(origins: finalOrigins, walked: split, shows: before.shared.shows,
                                                  artistTags: before.shared.artistTags, scenes: nil, libraryCounts: [:])
        }
        let history = finalPersonal.crate.compactMap(\.node) + finalPersonal.met.map(\.node) + finalPersonal.haunts.map(\.node)
        let known = KnownArtistPolicy.alsoKnown(history: history, owners: finalOwners, namesOf: shadowGraph.canonicalizer.legacyKeys(of:))
        let finalOffers = ExploreRanker.offers(personal: finalPersonal, knowledge: assemble(finalWalked), asOf: asOf, alsoKnown: known)
        let finalUnguarded = ExploreRanker.offers(personal: finalPersonal, knowledge: assemble(finalWalked), asOf: asOf)
        func ids(_ offers: ExploreOffers) -> [String] { (offers.next + offers.artists + offers.shows).map(\.node.id) }
        let todays = (offersBefore.next + offersBefore.artists + offersBefore.shows).map { shadowGraph.canonicalizer.canonical($0.node).id }
        let finals = ids(finalOffers)
        out.append("known artists excluded under identity keys: \(ids(finalUnguarded).filter { !finals.contains($0) })")
        out.append("For You: today \(todays.count), final \(finals.count); top 6 identical: \(Array(todays.prefix(6)) == Array(finals.prefix(6)))")
        out.append("  lost: \(todays.filter { !finals.contains($0) })")
        out.append("  gained: \(finals.filter { !todays.contains($0) })")
        func listing(_ offers: ExploreOffers) -> [String] {
            (offers.next + offers.artists + offers.shows).enumerated().map { index, suggestion in
                "#\(index + 1) \(String(format: "%.4f", suggestion.score)) \(suggestion.node.title) [\(suggestion.node.id)]"
            }
        }
        let todayList = listing(offersBefore), finalList = listing(finalOffers)
        out.append("  side by side (today | final):")
        for index in 0..<max(todayList.count, finalList.count) {
            let left = index < todayList.count ? todayList[index] : "", right = index < finalList.count ? finalList[index] : ""
            out.append("    \(left)  |  \(right)")
        }

        // For decision only, not a proposal of scoring policy: routes to a name
        // with exactly one verified owner folded into that owner.
        var folded: [MusicNode: [MusicEdge]] = [:]
        for (origin, edges) in finalWalked {
            folded[origin] = edges.map { edge in
                guard edge.to.kind == .artist, GraphIdentityKey(nodeKey: edge.to.key) == nil,
                      let only = finalOwners[edge.to.key], only.count == 1, let owner = only.first else { return edge }
                let target = MusicNode(kind: .artist, key: owner.nodeKey, title: edge.to.title)
                return MusicEdge(from: edge.from, to: target, kind: edge.kind, source: edge.source,
                                 reason: edge.reason, confidence: edge.confidence, occurrences: edge.occurrences)
            }
        }
        let foldedOffers = ExploreRanker.offers(personal: finalPersonal, knowledge: assemble(folded), asOf: asOf, alsoKnown: known)
        out.append("  [decision only] with single-owner name routes folded: top 6 identical \(Array(todays.prefix(6)) == Array(ids(foldedOffers).prefix(6))); scores:")
        listing(foldedOffers).forEach { out.append("    \($0)") }

        out += visibleComparison("with R2 credits", context: context, origins: origins)

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
