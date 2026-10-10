//
//  CreditEdgeIdentity.swift
//  Indigo
//
//  The Discogs entries behind the graph's credit edges. Shadow only: the
//  graph's own edges are unchanged; this gives a copy of them the ids the
//  release documents carried.
//
//  A producer, personnel, collaborator or same-release edge exists because a
//  release credited somebody, and the kept credits (`ReleaseCreditRecord`)
//  say which entry each credit named. Hype Williams' records credit "Blunt";
//  the credit names Dean Blunt's entry, and the edge should lead there rather
//  than to whoever is called "Blunt".
//
//  Scoped to the releases the edge came from: a release node's own credits, or
//  the releases that are the artist's — their own shelf, when the record DIG
//  holds is filed under their own name, and every release filed under their
//  name that `ReleaseAttribution` does not give to somebody else. Within that
//  scope a credited spelling must name exactly one entry, or the edge keeps
//  the name it had: two credits spelled alike naming two entries are
//  namesakes, and the edge cannot say which it meant.
//
//  Nothing comes from a name, and nothing from a cache row filed under
//  somebody else's. The credited spelling stays the node's reference; the
//  role stays in the edge's reason; the id is the credit's.
//

import Foundation
import SwiftData

/// The credit-backed kinds: edges that exist because a release credited them.
nonisolated extension RelationshipKind {
    var isCreditBacked: Bool {
        switch self {
        case .producer, .personnel, .collaborator, .sameRelease: true
        default: false
        }
    }
}

nonisolated enum CreditEdgeIdentity {
    /// Which entry each credited spelling names within some releases' credits,
    /// by folded spelling. A spelling naming two entries has no answer.
    static func entries(in credits: [ReleaseCredit]) -> [String: ReleaseCredit] {
        var byKey: [String: [ReleaseCredit]] = [:]
        for credit in credits where credit.discogsID != nil {
            let spellings = [
                RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(credit.creditedName)),
                RecordingKey.normalizeArtist(credit.name)
            ]
            for key in Set(spellings) where !key.isEmpty { byKey[key, default: []].append(credit) }
        }
        return byKey.compactMapValues { found in
            let ids = Set(found.compactMap(\.discogsID))
            guard ids.count == 1 else { return nil }
            // One entry; its credit in a fixed order, so the answer does not
            // depend on which release was read first.
            return found.min { ($0.filingName, $0.creditedName, $0.role, $0.tracks) < ($1.filingName, $1.creditedName, $1.role, $1.tracks) }
        }
    }

    /// The edges with the entries their credits named. Edges of other kinds,
    /// to non-artists, already carrying an id, or whose spelling no credit in
    /// scope names uniquely, come back unchanged.
    static func attach(_ edges: [MusicEdge], entries: [String: ReleaseCredit]) -> [MusicEdge] {
        edges.map { edge in
            guard edge.kind.isCreditBacked, edge.to.kind == .artist, edge.to.discogsID == nil,
                  let credit = entries[edge.to.key], let id = credit.discogsID else { return edge }
            var target = edge.to
            target.discogsID = id
            return MusicEdge(from: edge.from, to: target, kind: edge.kind, source: edge.source,
                             reason: edge.reason, confidence: edge.confidence, occurrences: edge.occurrences)
        }
    }
}

/// Reads the scope for a node out of the store.
@MainActor
struct CreditEdgeScope {
    let context: ModelContext
    let graph: GraphStore

    /// The credits behind a node's credit edges, or none.
    func credits(behind node: MusicNode) -> [ReleaseCredit] {
        let store = ReleaseCreditStore(context: context)
        switch node.kind {
        case .release:
            return node.discogsID.flatMap { store.credits(releaseID: $0) } ?? []
        case .artist:
            return releases(of: node).flatMap { store.credits(releaseID: $0) ?? [] }
        default:
            return []
        }
    }

    /// The releases that are this artist's.
    func releases(of node: MusicNode) -> [Int] {
        var ids: [Int] = []
        let enricher = DiscogsEnricher(context: context, client: DiscogsClient())
        let identityStore = ArtistIdentityStore(context: context)
        let filed = enricher.cachedArtist(named: node.title)
            .flatMap { $0.isFiledUnderItsOwnName(identityStore: identityStore) && RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator($0.name)) == node.key ? $0 : nil }
        ids += filed?.releaseDiscogsIDs.filter { $0 > 0 } ?? []
        let underName = graph.releases(creditedTo: node.key).map(\.discogsID)
        let attributions = DigEngine.attributions(
            of: underName, subjectID: node.discogsID ?? filed?.discogsID,
            subjectKeys: [node.key], context: context)
        ids += underName.filter { attributions[$0]?.isShown ?? true }
        var seen = Set<Int>()
        return ids.filter { seen.insert($0).inserted }
    }
}
