//
//  MusicGraph.swift
//  Indigo
//
//  An accumulated, walkable graph.
//
//  `EdgeSet` answers one question — what is next to this — and is thrown away
//  after. A DEEP session is not one question: it is a path, and where it has
//  already been decides what is worth offering next. So the graph built
//  during a walk is kept, grown by whichever engine has evidence to add, and
//  walked from either end.
//
//  Every relationship Indigo draws is symmetric. Sharing a label is not
//  something one artist does to another, so a connection made in one
//  direction is immediately true in the other, and the store holds both so a
//  walk never has to know which way the fact was originally written down.
//

import Foundation

nonisolated struct MusicGraph: Sendable {
    private(set) var nodes: [String: MusicNode] = [:]
    /// Reasons, from node id to node id. Storing the reasons rather than
    /// finished edges is what lets a second engine add to a connection that
    /// already exists instead of arguing with it.
    private var reasons: [String: [String: [Relationship]]] = [:]

    init() {}

    // MARK: Building

    @discardableResult
    mutating func insert(_ node: MusicNode) -> MusicNode {
        // A node reached twice may be better described the second time — a
        // name arrives before its MBID does — so identifiers accumulate
        // rather than the later mention overwriting the earlier one.
        guard var existing = nodes[node.id] else {
            nodes[node.id] = node
            return node
        }
        existing.mbid = existing.mbid ?? node.mbid
        existing.discogsID = existing.discogsID ?? node.discogsID
        existing.recordingID = existing.recordingID ?? node.recordingID
        existing.providerID = existing.providerID ?? node.providerID
        existing.handle = existing.handle ?? node.handle
        existing.subtitle = existing.subtitle ?? node.subtitle
        existing.artworkURL = existing.artworkURL ?? node.artworkURL
        nodes[node.id] = existing
        return existing
    }

    /// Records that two things are connected, and why.
    ///
    /// The same reason asserted twice is one reason. Two catalogues often
    /// know the same fact, and a connection that lists it twice reads as two
    /// pieces of evidence when it is one — which would let a connection talk
    /// its way up the ranking by repeating itself.
    mutating func connect(from: MusicNode, to: MusicNode, reason: Relationship) {
        let source = insert(from)
        let destination = insert(to)
        guard source.id != destination.id else { return }
        add(reason, from: source.id, to: destination.id)
        // Every relationship Indigo draws is symmetric, so the fact is
        // written both ways and a walk never has to know which direction it
        // was originally discovered in.
        add(reason, from: destination.id, to: source.id)
    }

    private mutating func add(_ reason: Relationship, from: String, to: String) {
        var existing = reasons[from]?[to] ?? []
        guard !existing.contains(reason) else { return }
        existing.append(reason)
        reasons[from, default: [:]][to] = existing
    }

    /// Folds a walked edge in, its repetitions already priced into its weight.
    mutating func connect(_ edge: MusicEdge) {
        connect(from: edge.from, to: edge.to, reason: edge.relationship)
    }

    mutating func absorb(_ edges: some Sequence<MusicEdge>) {
        for edge in edges { connect(edge) }
    }

    /// Folds another engine's findings in. Radio evidence, catalogue evidence
    /// and the listener's own behaviour are gathered separately and have to
    /// end up in one graph for DEEP to rank across them.
    mutating func absorb(_ other: MusicGraph) {
        for node in other.nodes.values { insert(node) }
        for (from, destinations) in other.reasons {
            guard let source = other.nodes[from] else { continue }
            for (to, found) in destinations {
                guard let destination = other.nodes[to] else { continue }
                for reason in found { connect(from: source, to: destination, reason: reason) }
            }
        }
    }

    // MARK: Reading

    func node(_ id: String) -> MusicNode? { nodes[id] }

    /// Everything next to a node, best-explained first. Each entry carries
    /// every reason it was reached by, because "why this?" has to be
    /// answerable from what the walk actually found.
    func connections(from node: MusicNode) -> [Connection] {
        guard let destinations = reasons[node.id], let source = nodes[node.id] else { return [] }
        return destinations
            .compactMap { key, found -> Connection? in
                guard let destination = nodes[key] else { return nil }
                return Connection(
                    from: source, to: destination,
                    reasons: found.sorted { $0.confidence > $1.confidence }
                )
            }
            .sorted {
                $0.confidence == $1.confidence ? $0.to.title < $1.to.title : $0.confidence > $1.confidence
            }
    }

    func connections(from node: MusicNode, kind: MusicNodeKind) -> [Connection] {
        connections(from: node).filter { $0.to.kind == kind }
    }

    func connection(from source: MusicNode, to destination: MusicNode) -> Connection? {
        connections(from: source).first { $0.to.id == destination.id }
    }

    /// One connection, ready to render: where it goes, why, and how much of
    /// it to believe.
    nonisolated struct Connection: Identifiable, Sendable {
        let from: MusicNode
        let to: MusicNode
        /// Strongest first, deduplicated.
        let reasons: [Relationship]

        var id: String { "\(from.id)→\(to.id)" }

        /// Independent evidence combined — see `ConfidenceMath`.
        var confidence: Double { ConfidenceMath.combined(reasons.map(\.confidence)) }

        var confidenceBand: RelationshipConfidence { RelationshipConfidence.band(confidence) }

        /// The one reason a compact row shows.
        var primaryReason: Relationship? { reasons.first }

        var why: WhyThis? { WhyThis(reasons: reasons) }
    }

    var isEmpty: Bool { nodes.isEmpty }

    /// Distinct connections, counted once rather than once per direction.
    var connectionCount: Int {
        var seen = Set<String>()
        for (from, destinations) in reasons {
            for to in destinations.keys { seen.insert([from, to].sorted().joined(separator: "\u{2194}")) }
        }
        return seen.count
    }
}
