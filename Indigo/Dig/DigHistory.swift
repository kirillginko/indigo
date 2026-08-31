//
//  DigHistory.swift
//  Indigo
//
//  What this listener actually digs through.
//
//  The spec is firm that DIG should learn from the person's own history
//  first, before any aggregate. That is also the honest order: a path someone
//  has walked four times is better evidence about them than anything a
//  catalogue or a crowd could offer, and it needs nobody's data but theirs.
//
//  Everything here is local and stays local. Nothing is uploaded, nothing is
//  identified, and the whole of it can be thrown away without losing anything
//  the app can't rebuild.
//

import Foundation
import SwiftData

/// A node the listener opened, and how often.
@Model
nonisolated final class DigVisit {
    @Attribute(.unique) var nodeID: String
    var kindRaw: String
    var title: String
    var subtitle: String?
    var visits: Int
    var firstVisitedAt: Date
    var lastVisitedAt: Date

    // Enough to reopen it. A visit nobody can act on is a statistic.
    var mbid: String?
    var discogsID: Int?
    var recordingID: UUID?
    var providerID: String?
    var handle: String?

    init(node: MusicNode) {
        nodeID = node.id
        kindRaw = node.kind.rawValue
        title = node.title
        subtitle = node.subtitle
        visits = 0
        firstVisitedAt = Date()
        lastVisitedAt = Date()
        mbid = node.mbid
        discogsID = node.discogsID
        recordingID = node.recordingID
        providerID = node.providerID
        handle = node.handle
    }

    var kind: MusicNodeKind { MusicNodeKind(rawValue: kindRaw) ?? .artist }

    /// The node again, so a remembered visit can be walked from.
    var node: MusicNode {
        MusicNode(
            kind: kind,
            key: String(nodeID.drop { $0 != ":" }.dropFirst()),
            title: title, subtitle: subtitle,
            mbid: mbid, discogsID: discogsID, recordingID: recordingID,
            providerID: providerID, handle: handle
        )
    }
}

/// One step actually taken: this, then that. Paths are what a dig *is* — the
/// resulting list of tracks is only the residue.
@Model
nonisolated final class DigStep {
    @Attribute(.unique) var identity: String
    var fromNodeID: String
    var toNodeID: String
    var count: Int
    var lastAt: Date

    init(from: String, to: String) {
        identity = "\(from)→\(to)"
        fromNodeID = from
        toNodeID = to
        count = 0
        lastAt = Date()
    }
}

// MARK: - Reading it back

nonisolated struct DigHistory {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Writing

    /// Records that a node was opened, and the step that got there.
    ///
    /// `from` is nil when the listener arrived from outside a dig — off the
    /// Crate, out of a search. That is a visit but not a step, and counting it
    /// as one would invent a path nobody walked.
    func record(_ node: MusicNode, from origin: MusicNode? = nil) {
        let visit = visit(for: node) ?? {
            let fresh = DigVisit(node: node)
            context.insert(fresh)
            return fresh
        }()
        visit.visits += 1
        visit.lastVisitedAt = Date()
        visit.title = node.title
        // Identifiers accumulate: a node met by name first and by MBID later
        // should end up knowing both.
        visit.mbid = visit.mbid ?? node.mbid
        visit.discogsID = visit.discogsID ?? node.discogsID
        visit.recordingID = visit.recordingID ?? node.recordingID

        if let origin, origin.id != node.id {
            let step = step(from: origin.id, to: node.id) ?? {
                let fresh = DigStep(from: origin.id, to: node.id)
                context.insert(fresh)
                return fresh
            }()
            step.count += 1
            step.lastAt = Date()
        }
        try? context.save()
    }

    func forget() {
        for visit in visits() { context.delete(visit) }
        for step in steps() { context.delete(step) }
        try? context.save()
    }

    // MARK: Reading

    func visits() -> [DigVisit] {
        (try? context.fetch(FetchDescriptor<DigVisit>())) ?? []
    }

    func steps() -> [DigStep] {
        (try? context.fetch(FetchDescriptor<DigStep>())) ?? []
    }

    func visit(for node: MusicNode) -> DigVisit? { visit(nodeID: node.id) }

    func visit(nodeID: String) -> DigVisit? {
        var descriptor = FetchDescriptor<DigVisit>(predicate: #Predicate { $0.nodeID == nodeID })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func step(from: String, to: String) -> DigStep? {
        let identity = "\(from)→\(to)"
        var descriptor = FetchDescriptor<DigStep>(predicate: #Predicate { $0.identity == identity })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// "YOU OFTEN DIG THROUGH" — the things this listener keeps going back to.
    ///
    /// Ranked by returns rather than by visits: opening something once is
    /// curiosity, and opening it a fourth time is how they listen. A node seen
    /// exactly once tells you nothing and would crowd out the ones that do.
    func haunts(kinds: Set<MusicNodeKind> = [.label, .artist, .broadcast], limit: Int = 6) -> [DigVisit] {
        visits()
            .filter { kinds.contains($0.kind) && $0.visits > 1 }
            .sorted {
                $0.visits == $1.visits
                    ? $0.lastVisitedAt > $1.lastVisitedAt
                    : $0.visits > $1.visits
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Where the listener was last, so a dig can be picked back up.
    func recent(limit: Int = 5) -> [DigVisit] {
        visits()
            .sorted { $0.lastVisitedAt > $1.lastVisitedAt }
            .prefix(limit)
            .map { $0 }
    }

    /// "TRY" — where this listener has not been.
    ///
    /// Built by walking out of the places they keep returning to and removing
    /// everything they have already opened. That last part is the whole
    /// point: a suggestion they have seen four times is not a suggestion, and
    /// leaving it in is how a recommendation list turns into a mirror.
    func suggestions(limit: Int = 6) -> [Suggestion] {
        let seen = Set(visits().map(\.nodeID))
        let origins = haunts(kinds: [.artist, .label, .broadcast, .scene], limit: 4)
        guard !origins.isEmpty else { return [] }

        let graph = GraphStore(context: context)
        var best: [String: Suggestion] = [:]
        for origin in origins {
            let originNode = origin.node
            // How much this listener trusts the place it came from, flattened
            // so one much-visited label cannot drown out everything else.
            let pull = min(1, 0.5 + Double(origin.visits) / 12)
            for connection in graph.neighbors(of: originNode).byDestination
            where !seen.contains(connection.node.id) && connection.node.destination != nil {
                let score = connection.confidence * pull
                let candidate = Suggestion(
                    node: connection.node,
                    reasons: connection.edges.map(\.relationship),
                    via: originNode,
                    score: score
                )
                if let existing = best[connection.node.id], existing.score >= score { continue }
                best[connection.node.id] = candidate
            }
        }
        return best.values
            .sorted { $0.score == $1.score ? $0.node.title < $1.node.title : $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    /// Somewhere worth going, and the place in the listener's own history
    /// that argues for it.
    nonisolated struct Suggestion: Identifiable, Sendable {
        let node: MusicNode
        let reasons: [Relationship]
        /// The much-visited node this was reached from — "via Ilian Tape".
        let via: MusicNode
        let score: Double

        var id: String { node.id }
        var why: WhyThis? { WhyThis(reasons: reasons) }
        var band: RelationshipConfidence { RelationshipConfidence.band(score) }
    }

    /// The step most often taken out of a node — what they usually do next
    /// from here.
    func usualNextStep(from node: MusicNode) -> DigVisit? {
        let origin = node.id
        let best = steps()
            .filter { $0.fromNodeID == origin }
            .max { $0.count == $1.count ? $0.lastAt < $1.lastAt : $0.count < $1.count }
        return best.flatMap { visit(nodeID: $0.toNodeID) }
    }
}
