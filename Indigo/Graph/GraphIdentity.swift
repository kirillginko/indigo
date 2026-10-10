//
//  GraphIdentity.swift
//  Indigo
//
//  The graph keyed by who artists are, worked out in memory beside the graph
//  keyed by how their names fold. Shadow only, for now: nothing here is stored
//  or shown, and nothing that is stored or shown reads it.
//
//  A key and the evidence for it are two things. `discogs:1874027` is a stable
//  name for an entry; that a particular node — a radio credit, an old
//  name-keyed row — *is* that entry is a claim, and claims can be wrong. So
//  every canonical artist keeps the reference it came from, the evidence class
//  that placed it, and the provenance behind that, and a mistaken placement can
//  be undone without losing what was originally referenced.
//
//  The aim is not to merge as much as possible. It is that every merge is
//  defensible, every namesake separable, and every uncertain identity
//  recoverable:
//
//  - Only direct credit evidence, verified spelling evidence, or an
//    authoritative external id puts a node under an identity key. A record DIG
//    happens to have filed under the name does not, and neither does an id
//    whose entry merely shares the name — namesakes share names.
//  - Namesakes become separate identity nodes, each by its own evidence. A
//    reference that carries none stays on its name, unresolved, however many
//    verified artists share that name.
//  - Aliases are other entries, so they are other identities; the edges that
//    link them are untouched.
//
//  Deterministic and idempotent: the same node always canonicalizes the same
//  way, whatever else is in the batch and in whatever order, and a canonical
//  node canonicalizes to itself.
//

import Foundation

/// A stable graph key in one of three namespaces.
///
/// Verified artists are `discogs:1874027` or `mbid:…`. An unresolved artist is
/// its folded name, exactly as the graph has always keyed it — so the radio,
/// Bandcamp and SoundCloud artists nothing identifies keep the ids history
/// already holds. Folding strips punctuation, so no folded name contains a
/// colon, and the namespaces cannot collide.
nonisolated struct GraphIdentityKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    nonisolated enum Namespace: String, Hashable, Sendable {
        case discogs, mbid, name
    }

    let namespace: Namespace
    let value: String

    static func discogs(_ id: Int) -> GraphIdentityKey { GraphIdentityKey(namespace: .discogs, value: String(id)) }
    static func musicBrainz(_ mbid: String) -> GraphIdentityKey { GraphIdentityKey(namespace: .mbid, value: mbid.lowercased()) }
    static func name(_ legacyKey: String) -> GraphIdentityKey { GraphIdentityKey(namespace: .name, value: legacyKey) }

    /// The key a node holds within its kind: "discogs:1874027", or the folded
    /// name for an unresolved artist.
    var nodeKey: String { namespace == .name ? value : "\(namespace.rawValue):\(value)" }
    /// The node's id: "artist:discogs:1874027".
    var nodeID: String { MusicNode.canonicalID(kindRaw: MusicNodeKind.artist.rawValue, key: nodeKey) }
    var isVerified: Bool { namespace != .name }
    var description: String { nodeID }

    /// The identity key a canonical node already holds, or nil for a folded
    /// name, which is a legacy key until something places it.
    init?(nodeKey: String) {
        guard let colon = nodeKey.firstIndex(of: ":"),
              let namespace = Namespace(rawValue: String(nodeKey[..<colon])), namespace != .name else { return nil }
        self.init(namespace: namespace, value: String(nodeKey[nodeKey.index(after: colon)...]))
    }

    private init(namespace: Namespace, value: String) {
        self.namespace = namespace
        self.value = value
    }

    static func < (lhs: GraphIdentityKey, rhs: GraphIdentityKey) -> Bool { lhs.nodeID < rhs.nodeID }
}

/// How strongly a node's identity key is supported, strongest first. Ordinal:
/// it says which evidence is better, not by how much, and is not a weight.
nonisolated enum EvidenceClass: Int, Comparable, Sendable, CaseIterable {
    /// A release's own credit names this spelling with this entry.
    case directCredit
    /// A complete check found exactly one entry answering to this spelling.
    case verifiedSpelling
    /// MusicBrainz links the reference's MBID to this entry.
    case externalID
    /// The node carries an id whose entry is filed under its name — consistent,
    /// not proof.
    case consistentRecord
    /// DIG's own record filed under the name.
    case filedRecord
    /// An id nothing supports.
    case inferred
    /// Nothing but the name.
    case nameOnly

    /// Whether this is enough to put a node under an identity key.
    var placesIdentity: Bool { self <= .externalID }

    static func < (lhs: EvidenceClass, rhs: EvidenceClass) -> Bool { lhs.rawValue < rhs.rawValue }

    init(_ identity: ArtistNodeIdentity) {
        switch identity.provenance {
        case .credit: self = .directCredit
        case .resolver:
            switch identity.basis {
            case .nameVariation?, .canonicalName?: self = .verifiedSpelling
            case .musicBrainzLink?: self = .externalID
            // An MBID a node carries mostly came from looking the name up in
            // MusicBrainz — as good as a record filed under the name, no better.
            case .musicBrainzID?: self = .consistentRecord
            default: self = .inferred
            }
        case .consistentRecord: self = .consistentRecord
        case .filedRecord: self = .filedRecord
        case .inferred: self = .inferred
        case .nameOnly: self = .nameOnly
        }
    }
}

/// One artist node, placed: its key, and everything that placed it there.
nonisolated struct CanonicalArtist: Hashable, Sendable {
    let key: GraphIdentityKey
    /// The node as it was referenced, kept so a placement can be undone.
    let reference: MusicNode
    let evidence: EvidenceClass
    /// Where the node's identity resolution pointed, whether or not it was
    /// strong enough to place it.
    let resolvedIdentity: ArtistIdentity
}

/// Canonicalizes graph nodes, edges and references in memory.
nonisolated final class GraphCanonicalizer: @unchecked Sendable {
    private let identify: (MusicNode) -> ArtistNodeIdentity
    private var placed: [MusicNode: CanonicalArtist] = [:]

    /// - Parameter identify: who an artist node is. In the app this is
    ///   `ArtistNodeIdentifier.identify`; nothing else decides identity.
    init(identify: @escaping (MusicNode) -> ArtistNodeIdentity) {
        self.identify = identify
    }

    /// Where an artist node belongs. Nil for anything else, and for a node
    /// that is already canonical (see `canonical(_:)`).
    func placement(of node: MusicNode) -> CanonicalArtist? {
        guard node.kind == .artist, GraphIdentityKey(nodeKey: node.key) == nil else { return nil }
        if let held = placed[node] { return held }
        let found = identify(node)
        let evidence = EvidenceClass(found)
        let key: GraphIdentityKey
        if evidence.placesIdentity, let id = found.identity.discogsID {
            key = .discogs(id)
        } else if evidence.placesIdentity, let mbid = node.mbid ?? Self.mbid(of: found.identity) {
            key = .musicBrainz(mbid)
        } else {
            key = .name(node.key)
        }
        let placement = CanonicalArtist(key: key, reference: node, evidence: evidence, resolvedIdentity: found.identity)
        placed[node] = placement
        return placement
    }

    /// The node under its identity key. Non-artist nodes, and nodes already
    /// canonical, come back unchanged.
    func canonical(_ node: MusicNode) -> MusicNode {
        guard let placement = placement(of: node) else { return node }
        var canonical = MusicNode(kind: .artist, key: placement.key.nodeKey, title: node.title)
        canonical.subtitle = node.subtitle
        canonical.mbid = placement.key.namespace == .mbid ? placement.key.value : node.mbid
        canonical.discogsID = placement.key.namespace == .discogs ? Int(placement.key.value) : nil
        canonical.providerID = node.providerID
        canonical.handle = node.handle
        canonical.artworkURL = node.artworkURL
        return canonical
    }

    func canonical(_ edge: MusicEdge) -> MusicEdge {
        MusicEdge(
            from: canonical(edge.from), to: canonical(edge.to), kind: edge.kind, source: edge.source,
            reason: edge.reason, confidence: edge.confidence, occurrences: edge.occurrences
        )
    }

    /// Edges under identity keys, the same fact twice folded into one the way
    /// the graph already folds it (`EdgeSet`). An edge whose ends become one
    /// node is a node beside itself, and is dropped.
    func canonical(_ edges: [MusicEdge]) -> [MusicEdge] {
        var set = EdgeSet()
        for edge in edges.sorted(by: MusicEdge.precedes) {
            let canonical = canonical(edge)
            guard canonical.from.id != canonical.to.id else { continue }
            set.insert(canonical)
        }
        return set.all.sorted(by: MusicEdge.precedes)
    }

    /// The listener's history with every node it names canonicalized. Their
    /// rows are not touched; this is a copy, read the way the graph is.
    func canonical(_ personal: PersonalInputs) -> PersonalInputs {
        var copy = personal
        copy.crate = personal.crate.map { kept in
            var kept = kept
            kept.node = kept.node.map(canonical)
            return kept
        }
        copy.met = personal.met.map { met in
            var met = met
            met.node = canonical(met.node)
            return met
        }
        copy.haunts = personal.haunts.map { haunt in
            var haunt = haunt
            haunt.node = canonical(haunt.node)
            return haunt
        }
        return copy
    }

    /// The folded names an identity node was reached under, or the node's own
    /// key for one nothing placed.
    ///
    /// Not identity: a link for the questions a name can answer and an id
    /// cannot. "Does the listener already know this artist?" must count a crate
    /// row saying "Dean Blunt" against the verified Dean Blunt, or he is offered
    /// back to them; two candidates sharing a name and one owner must not both
    /// be offered. Neither question moves the unresolved reference anywhere.
    func legacyKeys(of node: MusicNode) -> Set<String> {
        guard node.kind == .artist else { return [node.key] }
        guard let key = GraphIdentityKey(nodeKey: node.key) else { return [node.key] }
        return Set(placed.values.filter { $0.key == key }.map(\.reference.key))
    }

    /// The verified identities each folded name has been placed under. One is
    /// a name with an owner; more than one is a name verified namesakes share.
    var ownersByLegacyKey: [String: Set<GraphIdentityKey>] {
        var owners: [String: Set<GraphIdentityKey>] = [:]
        for placement in placed.values where placement.key.isVerified {
            owners[placement.reference.key, default: []].insert(placement.key)
        }
        return owners
    }

    /// Every placement made so far, in a fixed order.
    var placements: [CanonicalArtist] {
        placed.values.sorted { $0.reference.id == $1.reference.id
            ? MusicNode.isPreferred($0.reference, over: $1.reference) : $0.reference.id < $1.reference.id }
    }

    private static func mbid(of identity: ArtistIdentity) -> String? {
        guard identity.rawValue.hasPrefix("mbid:") else { return nil }
        return String(identity.rawValue.dropFirst("mbid:".count))
    }
}
