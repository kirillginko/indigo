//
//  IdentityGraph.swift
//  Indigo
//
//  The graph as it is walked under identity keys: what DIG's DEEP, RELATED and
//  connections read. The stored graph underneath is unchanged — name-keyed
//  edges, each a fact about a name (`StoredEdge`) — and so is everything the
//  listener's history holds. This is read over it, per generation.
//
//  An identity node's neighbourhood is the neighbourhoods of everything placed
//  under it — "Prefuse73" from a tracklist and "Prefuse 73" from a credit are
//  one artist with one neighbourhood — with each edge given the entries its
//  credits named (`CreditEdgeIdentity`), each alias edge the entry the subject's
//  own Discogs entry lists (`AliasEdgeIdentity`), and the lot canonicalized.
//
//  It also walks the name the entry is filed under, which is where the
//  catalogue lives — but only when the record DIG holds under that name is that
//  same entry, and with `ReleaseAttribution` removing any release a namesake's
//  credits claim. Walking "Hype Williams" for the duo must not hand it the
//  director's records.
//
//  A name nothing places stays its own node. Beside the one verified entry
//  that answers to it in a neighbourhood, and with nothing saying it is
//  somebody else's, it is not listed twice: the entry's row stands, scored on
//  its own routes alone, because one owner in what this device has seen is not
//  proof that nobody else answers to the name. The name is noted for a
//  uniqueness check (`IdentityChecks`); once a complete one names the entry,
//  the canonicalizer places it there and its routes count. If the check finds
//  the name shared, both rows come back. Nothing is rewritten either way.
//

import Foundation
import SwiftData

/// Alias, group and member edges with the entries the subject's own Discogs
/// entry lists for them.
nonisolated enum AliasEdgeIdentity {
    nonisolated struct Entry: Hashable, Sendable {
        let id: Int
        let name: String
        let kind: RelationshipKind
    }

    /// The links an entry lists, by folded name; a name listed twice with two
    /// entries has no answer.
    static func entries(of facts: DiscogsIdentityFacts) -> [String: Entry] {
        var byKey: [String: [Entry]] = [:]
        func add(_ links: [DiscogsIdentityFacts.Link], _ kind: RelationshipKind) {
            for link in links {
                let key = RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(link.name))
                guard !key.isEmpty else { continue }
                byKey[key, default: []].append(Entry(id: link.id, name: DiscogsClient.withoutDisambiguator(link.name), kind: kind))
            }
        }
        add(facts.aliases, .sameAlias)
        add(facts.groups, .aliasOrProject)
        add(facts.members, .aliasOrProject)
        return byKey.compactMapValues { found in Set(found.map(\.id)).count == 1 ? found.min { $0.kind.rawValue < $1.kind.rawValue } : nil }
    }

    static func attach(_ edges: [MusicEdge], entries: [String: Entry]) -> [MusicEdge] {
        edges.map { edge in
            guard edge.kind == .sameAlias || edge.kind == .aliasOrProject, edge.to.kind == .artist,
                  edge.to.discogsID == nil, let entry = entries[edge.to.key], entry.kind == edge.kind else { return edge }
            var target = edge.to
            target.discogsID = entry.id
            return MusicEdge(from: edge.from, to: target, kind: edge.kind, source: edge.source,
                             reason: edge.reason, confidence: edge.confidence, occurrences: edge.occurrences)
        }
    }
}

/// One step out of a node, under identity keys.
nonisolated struct IdentityNeighbourhood: Sendable {
    /// The node walked from, canonical.
    let origin: MusicNode
    let edges: EdgeSet
    /// Every folded name behind each destination, by its id: the keys the
    /// listener's own rows and the page's other blocks know it by.
    let keys: [String: Set<String>]
    /// What the walk's identities rested on (`IdentityGraph.evidenceDigest`).
    var dependencies = IdentityDependencies()

    /// The ids a destination is known by: its own, and one per name behind it.
    func knownIDs(of node: MusicNode) -> Set<String> {
        guard node.kind == .artist else { return [node.id] }
        return Set((keys[node.id] ?? []).map { MusicNode(kind: .artist, key: $0, title: $0).id }).union([node.id])
    }
}

/// The evidence one walk's identities rested on: the folded names it placed,
/// the entries it placed them under or read, and the releases whose credits it
/// read. A walk is worth keeping exactly as long as these say the same.
nonisolated struct IdentityDependencies: Hashable, Sendable {
    var names: Set<String> = []
    var entries: Set<Int> = []
    var releases: Set<Int> = []

    mutating func formUnion(_ other: IdentityDependencies) {
        names.formUnion(other.names)
        entries.formUnion(other.entries)
        releases.formUnion(other.releases)
    }
}

nonisolated final class IdentityGraph {
    let graph: GraphStore
    let context: ModelContext
    let canonicalizer: GraphCanonicalizer
    private let identityStore: ArtistIdentityStore
    private let identifier: ArtistNodeIdentifier
    private let scope: CreditEdgeScope
    /// Where walks have spent their time, by phase, since this graph was made
    /// or `takePhases()` last asked. For You's build report reads it.
    private var phases: [String: Duration] = [:]

    private func measure<T>(_ phase: String, _ work: () -> T) -> T {
        let started = ContinuousClock.now
        let value = work()
        phases[phase, default: .zero] += ContinuousClock.now - started
        return value
    }

    /// The time spent per phase, in milliseconds, and a fresh start.
    func takePhases() -> [String: Double] {
        defer { phases = [:] }
        return phases.mapValues { Double($0.components.seconds) * 1_000 + Double($0.components.attoseconds) / 1e15 }
    }

    init(context: ModelContext, graph: GraphStore? = nil) {
        self.context = context
        let graph = graph ?? GraphStore(context: context)
        self.graph = graph
        // The evidence read once for the generation: a walk asks about every
        // artist one step out, and a fetch per question was most of its cost.
        let identityStore = ArtistIdentityStore(
            context: context,
            fold: IdentityEvidenceFold(context: context, filed: { graph.assembledDiscogsArtist(named: $0) }))
        self.identityStore = identityStore
        let identifier = ArtistNodeIdentifier(context: context, identityStore: identityStore)
        self.identifier = identifier
        canonicalizer = GraphCanonicalizer(identify: identifier.identify)
        scope = CreditEdgeScope(context: context, graph: graph, identityStore: identityStore)
    }

    deinit {}

    /// Where a reference lands in the identity-keyed graph.
    func node(_ reference: MusicNode) -> MusicNode { canonicalizer.canonical(reference) }

    /// One step out from a node, under identity keys, sorted.
    func neighbors(of node: MusicNode) -> [MusicEdge] {
        neighbourhood(of: node).edges.all.sorted(by: MusicEdge.precedes)
    }

    /// One step out from a node, under identity keys, with the names behind
    /// each destination.
    ///
    /// Worked out on every call, as `GraphStore.neighbors` is: the stored
    /// edges under it are filled in while a page loads — label and style peers
    /// land after the profile — and a neighbourhood kept from the first ask
    /// left DEEP with nothing but what the page already showed. Who each node
    /// is (the canonicalizer's placements) is kept for the generation; that
    /// only changes with a write, and every write starts another.
    func neighbourhood(of node: MusicNode) -> IdentityNeighbourhood {
        let canonical = canonicalizer.canonical(node)
        let entry = GraphIdentityKey(nodeKey: canonical.key).flatMap { $0.namespace == .discogs ? Int($0.value) : nil }
        // Itself, under every id it could arrive as: a page DIG opened as an
        // entry is not its own neighbour, whichever spelling a credit used.
        var own: Set<String> = [canonical.id, node.id]
        if node.kind == .artist, let id = node.discogsID ?? entry { own.insert(GraphIdentityKey.discogs(id).nodeID) }

        var set = EdgeSet()
        var keys: [String: Set<String>] = [:]
        var dependencies = IdentityDependencies()
        if node.kind == .artist { dependencies.names.insert(node.key) }
        dependencies.entries.formUnion([node.discogsID, entry].compactMap { $0 })
        for reference in measure("walk.references", { references(of: canonical, reached: node) }) {
            if reference.kind == .artist { dependencies.names.insert(reference.key) }
            for raw in edges(from: reference, entry: entry, reading: &dependencies).sorted(by: MusicEdge.precedes) {
                let edge = measure("walk.canonical") { canonicalizer.canonical(raw) }
                if raw.to.kind == .artist {
                    dependencies.names.insert(raw.to.key)
                    dependencies.entries.formUnion([raw.to.discogsID, edge.to.discogsID].compactMap { $0 })
                }
                guard !own.contains(edge.to.id) else { continue }
                set.insert(MusicEdge(from: canonical, to: edge.to, kind: edge.kind, source: edge.source,
                                     reason: edge.reason, confidence: edge.confidence, occurrences: edge.occurrences))
                if edge.to.kind == .artist { keys[edge.to.id, default: []].insert(raw.to.key) }
            }
        }
        // The catalogue pilot's bundle for this entry, when the pilot is on
        // and the page read it (`CataloguePilot`): routes from the documents
        // the catalogue already holds, each to an entry by its Discogs id.
        // Added to the walk, never stored; off, nothing here runs.
        if node.kind == .artist, let id = entry ?? node.discogsID, let bundle = CataloguePilot.shared.bundle(for: id) {
            let present = Set(set.all.map(\.to.id))
            // The artist's own other names are not people they worked with: a
            // credit to an alias the entry lists is the alias edge's to tell.
            let ownNames = Set([id] + (identityStore.facts(id)?.aliases.map(\.id) ?? []))
            for raw in measure("walk.pilot", { BundleEdges.edges(from: canonical, bundle: bundle, ownIdentities: ownNames, sqlTargets: present) }) {
                // Placed by the id the document's credit names -- the evidence
                // a kept credit is (`provenance: .credit`) -- rather than asked
                // of this device, which holds none of these documents' credits.
                // A namesake under another id stays another node.
                // No entry, or one of Discogs' stand-ins for nobody in particular,
                // is no route: never a name-only row from a bundle.
                if raw.to.kind == .artist {
                    guard let target = raw.to.discogsID, target > 0,
                          !CataloguePilot.standIns.contains(target) else { continue }
                }
                var edge = raw
                if raw.to.kind == .artist, let target = raw.to.discogsID {
                    var placed = MusicNode(kind: .artist, key: GraphIdentityKey.discogs(target).nodeKey, title: raw.to.title)
                    placed.discogsID = target
                    edge = MusicEdge(from: canonical, to: placed, kind: raw.kind, source: raw.source,
                                     reason: raw.reason, confidence: raw.confidence, occurrences: raw.occurrences)
                }
                guard !own.contains(edge.to.id) else { continue }
                if raw.to.kind == .artist {
                    dependencies.names.insert(raw.to.key)
                    dependencies.entries.formUnion([raw.to.discogsID, edge.to.discogsID].compactMap { $0 })
                }
                set.insert(MusicEdge(from: canonical, to: edge.to, kind: edge.kind, source: edge.source,
                                     reason: edge.reason, confidence: edge.confidence * CataloguePilot.confidenceShare,
                                     occurrences: edge.occurrences))
                if edge.to.kind == .artist { keys[edge.to.id, default: []].insert(raw.to.key) }
            }
        }
        for identity in set.all.map(\.to) where identity.kind == .artist {
            guard let id = identity.discogsID, GraphIdentityKey(nodeKey: identity.key) != nil else { continue }
            keys[identity.id, default: []].formUnion(measure("walk.names") { names(of: id, title: identity.title) }.map(RecordingKey.normalizeArtist))
        }
        var found = measure("walk.collapse") { collapsing([IdentityNeighbourhood(origin: canonical, edges: set, keys: keys)])[0] }
        found.dependencies = dependencies
        return found
    }

    /// A release's kept credits, from the fold.
    private func credits(_ releaseID: Int) -> [ReleaseCredit]? {
        identityStore.fold.map { $0.credits[releaseID] } ?? ReleaseCreditStore(context: context).credits(releaseID: releaseID)
    }

    /// A digest of the evidence a walk rested on, by content: every name's
    /// verdict, DIG's record under it and what else ties it to an entry; every
    /// entry's facts and settled spellings; every release's credits. Missing
    /// evidence is written as such, so a removal changes it as a correction
    /// does; evidence about anything else does not touch it.
    func evidenceDigest(of dependencies: IdentityDependencies) -> String {
        var lines: [String] = []
        for name in dependencies.names.sorted() {
            let verdict = identityStore.verdict(for: name).map { String(describing: $0) } ?? "none"
            let filed = identityStore.filedRecord(named: name).map { "\($0.discogsID) \($0.name)" } ?? "none"
            lines.append("name \(name) | \(verdict) | \(filed) | \(identifier.support(for: name).joined(separator: ","))")
        }
        for id in dependencies.entries.sorted() {
            guard let facts = identityStore.facts(id) else { lines.append("entry \(id) | none"); continue }
            let links = (facts.aliases.map { "a\($0.id)" } + facts.groups.map { "g\($0.id)" } + facts.members.map { "m\($0.id)" })
            lines.append("entry \(id) | \(facts.name) | \(facts.nameVariations.sorted().joined(separator: ",")) | "
                         + "\(links.sorted().joined(separator: ",")) | \(identityStore.creditedSpellings(of: id).joined(separator: ","))")
        }
        for id in dependencies.releases.sorted() {
            lines.append("release \(id) | " + (credits(id).map { list in
                list.map { "\($0.category.rawValue) \($0.order) \($0.creditedName)/\($0.filingName) \($0.discogsID.map(String.init) ?? "-") \($0.role) \($0.tracks)" }
                    .joined(separator: "; ")
            } ?? "none"))
        }
        return CanonicalDigest.of(lines)
    }

    /// The names an identity node is walked under, from stored evidence alone,
    /// so the answer never depends on what was asked before:
    ///
    /// - each spelling a complete check settled on the entry — everything
    ///   filed under such a name is this artist, because nobody else answers
    ///   to it;
    /// - the name the entry is filed under, when DIG's record there is that
    ///   same entry.
    ///
    /// Not a spelling a credit used. A credit proves that credit is the
    /// artist, not that everyone else called "Blunt" is: credited spellings
    /// arrive as edges from the releases that credit them, never walked as
    /// names. A node that is not an identity is walked as itself.
    private func references(of canonical: MusicNode, reached node: MusicNode) -> [MusicNode] {
        guard canonical.kind == .artist, let key = GraphIdentityKey(nodeKey: canonical.key),
              key.namespace == .discogs, let id = Int(key.value) else {
            return [canonical.kind == .artist && GraphIdentityKey(nodeKey: canonical.key) == nil ? node : canonical]
        }
        var seen = Set<String>()
        return names(of: id, title: canonical.title).map { MusicNode.artist($0) }
            .filter { seen.insert($0.key).inserted }
            .sorted { $0.id < $1.id }
    }

    /// Spellings settled on an entry, and its own name when DIG's record under
    /// that name is the entry.
    private func names(of id: Int, title: String) -> [String] {
        var names = identityStore.creditedSpellings(of: id)
        // The entry's name: from its own record when DIG has read it, otherwise
        // the name its credits file it under (the canonical node's title).
        let entryName = identityStore.facts(id)?.canonicalName ?? title
        let record = identityStore.filedRecord(named: entryName)
        if record?.discogsID == id, record?.isFiledUnderItsOwnName() == true { names.append(entryName) }
        return names
    }

    /// A reference's edges with every id the evidence supports. `entry` is the
    /// identity being walked, when it is one: its own alias list gives alias
    /// edges their ids, and a release its namesake's credits claim is not its.
    private func edges(from reference: MusicNode, entry: Int?, reading dependencies: inout IdentityDependencies) -> [MusicEdge] {
        var edges = measure("walk.graph") { graph.neighbors(of: reference).all }
        // The releases behind its credit edges, worked out once, and their
        // credits from the fold rather than a fetch apiece.
        let behind: [Int]
        switch reference.kind {
        case .release: behind = [reference.discogsID].compactMap { $0 }
        case .artist: behind = measure("walk.scope") { scope.releases(of: reference) }
        default: behind = []
        }
        dependencies.releases.formUnion(behind)
        edges = measure("walk.credits") {
            CreditEdgeIdentity.attach(edges, entries: CreditEdgeIdentity.entries(in: behind.flatMap { credits($0) ?? [] }))
        }
        guard reference.kind == .artist, let id = entry else { return edges }
        if let facts = identityStore.facts(id) {
            edges = AliasEdgeIdentity.attach(edges, entries: AliasEdgeIdentity.entries(of: facts))
        }
        dependencies.releases.formUnion(edges.compactMap { $0.to.kind == .release ? $0.to.discogsID : nil })
        return measure("walk.attribution") { edges.filter { edge in
            guard edge.to.kind == .release, let releaseID = edge.to.discogsID else { return true }
            return ReleaseAttribution.decide(
                subjectID: id, subjectKeys: [reference.key], credits: credits(releaseID)
            ).isShown
        } }
    }

    /// A name row beside the one verified entry that name belongs to here is
    /// shown as that entry's row alone, scored on the entry's own routes: two
    /// rows called "Jochem Paap" are a duplicate to anybody reading them, but
    /// the name's routes are not his until a complete check says nobody else
    /// answers to it.
    ///
    /// Both rows stay when anything says the name is somebody else's: two
    /// verified owners here (namesakes), DIG's page for the name being another
    /// entry, or a completed check that found the name shared or unowned.
    ///
    /// "Here" is every neighbourhood passed: a page passes its own, For You
    /// passes all of its starting points', so one artist is one candidate
    /// across them.
    func collapsing(_ walks: [IdentityNeighbourhood]) -> [IdentityNeighbourhood] {
        var owners: [String: Set<String>] = [:]
        for walk in walks {
            for (id, names) in walk.keys where GraphIdentityKey(nodeKey: String(id.dropFirst("artist:".count))) != nil {
                for name in names { owners[name, default: []].insert(id) }
            }
        }
        // Nothing verified here, nothing to fold into.
        guard !owners.isEmpty else { return walks }
        var dropped: Set<String> = []
        // Every spelling a name row arrived under, as before: only those a
        // verified entry here answers to can be folded, so only they are read.
        var names: [String: Set<MusicNode>] = [:]
        for walk in walks {
            for edge in walk.edges.edges.values where edge.to.kind == .artist && owners[edge.to.key] != nil
                && GraphIdentityKey(nodeKey: edge.to.key) == nil {
                names[edge.to.id, default: []].insert(edge.to)
            }
        }
        for node in names.keys.sorted().flatMap({ (names[$0] ?? []).sorted { $0.title < $1.title } }) {
            guard let owner = owners[node.key], owner.count == 1, let identityID = owner.first,
                  identityStore.verdict(for: node.title) == nil else { continue }
            if let page = identityStore.artistResolution(ArtistReference(name: node.title)).identity.discogsID,
               GraphIdentityKey.discogs(page).nodeID != identityID { continue }
            dropped.insert(node.id)
            IdentityChecks.shared.note(node.title)
        }
        guard !dropped.isEmpty else { return walks }
        return walks.map { walk in
            var edges = EdgeSet()
            for edge in walk.edges.all where !dropped.contains(edge.to.id) { edges.insert(edge) }
            var kept = IdentityNeighbourhood(origin: walk.origin, edges: edges,
                                             keys: walk.keys.filter { !dropped.contains($0.key) })
            kept.dependencies = walk.dependencies
            return kept
        }
    }
}

/// Names the graph met that a uniqueness check would settle: each one shares a
/// page with exactly one verified entry, on a filed record alone. DIG takes a
/// few at a time, within its budget (`DigStore.settleGraphNames`).
nonisolated final class IdentityChecks: @unchecked Sendable {
    static let shared = IdentityChecks()
    private let lock = NSLock()
    private var waiting: [String] = []
    private var asked: Set<String> = []

    func note(_ name: String) {
        let key = ArtistSpelling.key(name)
        guard !key.isEmpty else { return }
        lock.withLock {
            guard !asked.contains(key), !waiting.contains(where: { ArtistSpelling.key($0) == key }) else { return }
            waiting.append(name)
        }
    }

    /// Back to a new session's state: nothing waiting, nothing asked. Tests
    /// share one process, and each starts as a session would.
    func reset() {
        lock.withLock {
            waiting.removeAll()
            asked.removeAll()
        }
    }

    /// Up to `limit` names, alphabetically — which are asked first should not
    /// depend on which page was walked first — each handed out once a session.
    func take(_ limit: Int) -> [String] {
        lock.withLock {
            let taken = Array(waiting.sorted().prefix(limit))
            waiting.removeAll { name in taken.contains(name) }
            asked.formUnion(taken.map(ArtistSpelling.key))
            return taken
        }
    }
}
