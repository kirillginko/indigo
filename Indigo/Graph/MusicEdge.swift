//
//  MusicEdge.swift
//  Indigo
//
//  A connection between two music objects, carrying why it exists.
//
//  The rule the whole of DIG rests on: an edge that cannot say what it is
//  made of is an edge Indigo will not draw. So the reason and the evidence
//  behind it are written where the evidence actually is — while the label
//  roster or the appearance log is in hand — and never reconstructed later
//  by a view guessing at what a number meant.
//

import Foundation

nonisolated struct MusicEdge: Identifiable, Hashable, Sendable {
    let from: MusicNode
    let to: MusicNode
    let kind: RelationshipKind
    let source: RelationshipSource
    /// The sentence shown under WHY THIS? — "Played in 11 of the same shows".
    let reason: String
    let confidence: Double
    /// How many separate times this evidence was seen. One shared show is a
    /// coincidence; eleven is a scene.
    let occurrences: Int

    init(
        from: MusicNode,
        to: MusicNode,
        kind: RelationshipKind,
        source: RelationshipSource,
        reason: String,
        confidence: Double,
        occurrences: Int = 1
    ) {
        self.from = from
        self.to = to
        self.kind = kind
        self.source = source
        self.reason = reason
        self.confidence = confidence
        self.occurrences = max(1, occurrences)
    }

    /// Identity is the pair and the kind, not the wording. Two runs that
    /// phrase the same fact differently are still one edge.
    var id: String { "\(from.id)→\(to.id)|\(kind.rawValue)" }

    /// Confidence after repetition is taken into account.
    var weight: Double { ConfidenceMath.reinforced(confidence, occurrences: occurrences) }

    var band: RelationshipConfidence { RelationshipConfidence.band(weight) }

    /// Whether this edge ranks ahead of another: heavier first, then by
    /// destination name as the lists have always read, and then by everything
    /// else the edge says, so that no two different edges ever tie.
    ///
    /// Only content. A tie used to fall back on arrival order, which followed
    /// dictionary iteration and so changed from one process to the next.
    static func precedes(_ left: MusicEdge, _ right: MusicEdge) -> Bool {
        if left.weight != right.weight { return left.weight > right.weight }
        return left.orderKey.lexicographicallyPrecedes(right.orderKey)
    }

    private var orderKey: [String] {
        [to.title, reason, kind.rawValue, source.rawValue, to.id, from.id,
         String(occurrences), String(confidence.bitPattern)]
    }

    /// The same fact stated from the other end. Every relationship Indigo
    /// draws is symmetric — sharing a label is not something one artist does
    /// to another — so the graph stores one direction and walks both.
    func reversed() -> MusicEdge {
        MusicEdge(from: to, to: from, kind: kind, source: source,
                  reason: reason, confidence: confidence, occurrences: occurrences)
    }

    /// Flattened for the existing RELATED list, which speaks in
    /// `Relationship` rather than in edges.
    var relationship: Relationship {
        Relationship(kind: kind, source: source, detail: reason, confidence: weight)
    }
}

/// Edges collected while walking, deduplicated and kept strongest-first.
///
/// Two sources often assert the same thing — MusicBrainz and Discogs both
/// know an artist's label — and a graph that lists it twice reads as two
/// reasons when it is one. Merging on identity keeps the better-evidenced
/// version rather than whichever arrived last.
///
/// And the answer does not depend on the order things arrived in. Walks insert
/// out of dictionaries, whose order Swift seeds per process, and the merge
/// used to keep whichever of two equally strong wordings came first -- and,
/// once a stronger wording had replaced one, dropped every later repeat of the
/// first instead of counting it. So each wording is merged on its own, by
/// rules that do not care about order (the strongest confidence, every
/// occurrence, the better-identified spelling of each end), and the edge is
/// the best wording by `MusicEdge.precedes`. The same edges in any order are
/// the same set.
nonisolated struct EdgeSet: Sendable {
    private(set) var edges: [String: MusicEdge] = [:]
    /// Every wording of each edge, merged, by edge id and then by reason.
    private var wordings: [String: [String: MusicEdge]] = [:]

    init() {}

    mutating func insert(_ edge: MusicEdge) {
        var stated = wordings[edge.id] ?? [:]
        // Same fact seen again: it is better evidenced, not more certain.
        stated[edge.reason] = stated[edge.reason].map { Self.merged($0, edge) } ?? edge
        wordings[edge.id] = stated
        edges[edge.id] = stated.values.min(by: MusicEdge.precedes)
    }

    /// One wording seen twice. Commutative and associative, so any order of
    /// arrival merges to the same edge.
    private static func merged(_ left: MusicEdge, _ right: MusicEdge) -> MusicEdge {
        MusicEdge(
            from: MusicNode.preferred(left.from, right.from),
            to: MusicNode.preferred(left.to, right.to),
            kind: left.kind,
            source: min(left.source.rawValue, right.source.rawValue) == left.source.rawValue
                ? left.source : right.source,
            reason: left.reason,
            confidence: max(left.confidence, right.confidence),
            occurrences: left.occurrences + right.occurrences
        )
    }

    mutating func insert(contentsOf others: some Sequence<MusicEdge>) {
        for edge in others { insert(edge) }
    }

    var all: [MusicEdge] {
        edges.values.sorted(by: MusicEdge.precedes)
    }

    /// Everything reached, each destination carrying every reason it was
    /// reached by — which is what a RELATED row actually is.
    var byDestination: [(node: MusicNode, edges: [MusicEdge], confidence: Double)] {
        // The node drawn is the best-identified spelling any edge carried,
        // not whichever edge the dictionary happened to yield first.
        Dictionary(grouping: edges.values, by: \.to.id)
            .compactMap { _, group -> (MusicNode, [MusicEdge], Double)? in
                guard let first = group.first?.to else { return nil }
                let node = group.dropFirst().reduce(first) { MusicNode.preferred($0, $1.to) }
                let ordered = group.sorted(by: MusicEdge.precedes)
                return (node, ordered, ConfidenceMath.combined(ordered.map(\.weight)))
            }
            .sorted {
                if $0.2 != $1.2 { return $0.2 > $1.2 }
                return $0.0.title == $1.0.title ? $0.0.id < $1.0.id : $0.0.title < $1.0.title
            }
            .map { (node: $0.0, edges: $0.1, confidence: $0.2) }
    }

    var isEmpty: Bool { edges.isEmpty }

    /// Every artist this node reaches by an alias edge — its other names,
    /// projects and members. Anything built for broadening out leaves these
    /// out: AFX is not a recommendation for somebody who keeps Aphex Twin.
    ///
    /// Read off the edges rather than asked of the alias resolver. The
    /// resolver closes over the whole artist table, and asking it from the
    /// landing page assembled six tables cold — 1.5s of the first open —
    /// to learn what the stored edges already said.
    var aliasKeys: Set<String> {
        Set(edges.values.filter { $0.kind.isAlias && $0.to.kind == .artist }.map(\.to.key))
    }
}
