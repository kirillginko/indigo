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
nonisolated struct EdgeSet: Sendable {
    private(set) var edges: [String: MusicEdge] = [:]

    init() {}

    mutating func insert(_ edge: MusicEdge) {
        guard let existing = edges[edge.id] else {
            edges[edge.id] = edge
            return
        }
        // Same fact seen again: it is better evidenced, not more certain.
        if existing.reason == edge.reason {
            edges[edge.id] = MusicEdge(
                from: existing.from, to: existing.to, kind: existing.kind,
                source: existing.source, reason: existing.reason,
                confidence: max(existing.confidence, edge.confidence),
                occurrences: existing.occurrences + edge.occurrences
            )
        } else if edge.weight > existing.weight {
            edges[edge.id] = edge
        }
    }

    mutating func insert(contentsOf others: some Sequence<MusicEdge>) {
        for edge in others { insert(edge) }
    }

    var all: [MusicEdge] {
        edges.values.sorted {
            $0.weight == $1.weight ? $0.to.title < $1.to.title : $0.weight > $1.weight
        }
    }

    /// Everything reached, each destination carrying every reason it was
    /// reached by — which is what a RELATED row actually is.
    var byDestination: [(node: MusicNode, edges: [MusicEdge], confidence: Double)] {
        Dictionary(grouping: edges.values, by: \.to.id)
            .compactMap { _, group -> (MusicNode, [MusicEdge], Double)? in
                guard let node = group.first?.to else { return nil }
                let ordered = group.sorted { $0.weight > $1.weight }
                return (node, ordered, ConfidenceMath.combined(ordered.map(\.weight)))
            }
            .sorted {
                $0.2 == $1.2 ? $0.0.title < $1.0.title : $0.2 > $1.2
            }
            .map { (node: $0.0, edges: $0.1, confidence: $0.2) }
    }

    var isEmpty: Bool { edges.isEmpty }
}
