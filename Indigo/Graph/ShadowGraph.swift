//
//  ShadowGraph.swift
//  Indigo
//
//  The graph as it would be walked under identity keys. Shadow only: built
//  from the graph that exists, read by the shadow audit and the journey tests,
//  and by nothing the listener sees.
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

@MainActor
final class ShadowGraph {
    let graph: GraphStore
    let store: DigStore
    let canonicalizer: GraphCanonicalizer
    private let scope: CreditEdgeScope

    init(context: ModelContext, store: DigStore? = nil) {
        let store = store ?? DigStore(context: context)
        self.store = store
        graph = GraphStore(context: context)
        canonicalizer = GraphCanonicalizer(identify: ArtistNodeIdentifier(store: store).identify)
        scope = CreditEdgeScope(context: context, graph: graph)
    }

    nonisolated deinit {}

    /// Where a reference lands in the identity-keyed graph.
    func node(_ reference: MusicNode) -> MusicNode { canonicalizer.canonical(reference) }

    /// One step out from a node, under identity keys.
    func neighbors(of node: MusicNode) -> [MusicEdge] {
        let canonical = canonicalizer.canonical(node)
        let entry = GraphIdentityKey(nodeKey: canonical.key).flatMap { $0.namespace == .discogs ? Int($0.value) : nil }
        var set = EdgeSet()
        for reference in references(of: canonical, reached: node) {
            for edge in canonicalizer.canonical(edges(from: reference, entry: entry)) where edge.to.id != canonical.id {
                set.insert(MusicEdge(from: canonical, to: edge.to, kind: edge.kind, source: edge.source,
                                     reason: edge.reason, confidence: edge.confidence, occurrences: edge.occurrences))
            }
        }
        return set.all.sorted(by: MusicEdge.precedes)
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
        var names: [String] = store.identityStore.creditedSpellings(of: id)
        // The entry's name: from its own record when DIG has read it, otherwise
        // the name its credits file it under (the canonical node's title).
        let entryName = store.identityStore.facts(id)?.canonicalName ?? canonical.title
        let record = DiscogsEnricher(context: store.context, client: DiscogsClient()).cachedArtist(named: entryName)
        if record?.discogsID == id, record?.isFiledUnderItsOwnName() == true { names.append(entryName) }
        var seen = Set<String>()
        return names.map { MusicNode.artist($0) }
            .filter { seen.insert($0.key).inserted }
            .sorted { $0.id < $1.id }
    }

    /// A reference's edges with every id the evidence supports. `entry` is the
    /// identity being walked, when it is one: its own alias list gives alias
    /// edges their ids, and a release its namesake's credits claim is not its.
    private func edges(from reference: MusicNode, entry: Int?) -> [MusicEdge] {
        var edges = graph.neighbors(of: reference).all
        edges = CreditEdgeIdentity.attach(edges, entries: CreditEdgeIdentity.entries(in: scope.credits(behind: reference)))
        guard reference.kind == .artist, let id = entry else { return edges }
        if let facts = store.identityStore.facts(id) {
            edges = AliasEdgeIdentity.attach(edges, entries: AliasEdgeIdentity.entries(of: facts))
        }
        return edges.filter { edge in
            guard edge.to.kind == .release, let releaseID = edge.to.discogsID else { return true }
            return ReleaseAttribution.decide(
                subjectID: id, subjectKeys: [reference.key],
                credits: ReleaseCreditStore(context: store.context).credits(releaseID: releaseID)
            ).isShown
        }
    }
}
