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
    /// Names this row, as `nodeID` names the node it counts. Two devices that
    /// each opened the same node make two rows with one `nodeID` and two ids,
    /// and which row survives their merge is decided by the ids -- so a row
    /// keeps the id it was born with, and a merge never makes a new one. Nil
    /// only until `UserDataIDs.assign` has run on a row from before it existed.
    var id: UUID?
    /// Not unique: two devices' rows for one node are two rows until
    /// `UserDataDedupe` folds them, and a constraint would have refused the
    /// second. It names the node; `id` names the row.
    var nodeID: String = ""
    var kindRaw: String = MusicNodeKind.artist.rawValue
    var title: String = ""
    var subtitle: String?
    /// A row that arrives with none of these is an empty history: no visits, and
    /// an interval that is empty -- `firstVisitedAt` in the far future and
    /// `lastVisitedAt` in the far past -- so it changes neither end of a merge.
    var visits: Int = 0
    var firstVisitedAt: Date = Date.distantFuture
    var lastVisitedAt: Date = Date.distantPast

    // Enough to reopen it. A visit nobody can act on is a statistic.
    var mbid: String?
    var discogsID: Int?
    var providerID: String?
    var handle: String?

    /// A row as it was; see `CrateItem.init(restoring:)`.
    init(restoring value: VisitValue) {
        id = value.id
        nodeID = value.nodeID
        value.apply(to: self)
    }

    init(node: MusicNode) {
        id = UUID()
        nodeID = node.id
        kindRaw = node.kind.rawValue
        title = node.title
        subtitle = node.subtitle
        visits = 0
        firstVisitedAt = Date()
        lastVisitedAt = Date()
        mbid = node.mbid
        discogsID = node.discogsID
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
            mbid: mbid, discogsID: discogsID,
            providerID: providerID, handle: handle
        )
    }
}

/// One step actually taken: this, then that. Paths are what a dig *is* — the
/// resulting list of tracks is only the residue.
@Model
nonisolated final class DigStep {
    /// See `DigVisit.id`.
    var id: UUID?
    /// Not unique, for the same reason as `DigVisit.nodeID`.
    var identity: String = ""
    var fromNodeID: String = ""
    var toNodeID: String = ""
    var count: Int = 0
    var lastAt: Date = Date.distantPast

    /// A row as it was; see `CrateItem.init(restoring:)`.
    init(restoring value: StepValue) {
        id = value.id
        identity = value.identity
        fromNodeID = value.fromNodeID
        toNodeID = value.toNodeID
        value.apply(to: self)
    }

    init(from: String, to: String) {
        id = UUID()
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
    /// A graph somebody else has already paid for, when there is one.
    ///
    /// `suggestions()` walks out of four nodes, and building a `GraphStore`'s
    /// caches reads six whole tables. On the worker that cost is already
    /// borne once per generation — see `DigWorker.refresh(_:)` — so sharing it
    /// is the difference between a walk and a rebuild.
    private let shared: GraphStore?
    /// False while the listener's store could not be opened; nothing is
    /// recorded or forgotten, because it would not outlive the session.
    private let writable: Bool

    init(context: ModelContext, graph: GraphStore? = nil, writable: Bool = Persistence.userDataWritable) {
        self.context = context
        self.shared = graph
        self.writable = writable
    }

    // MARK: Writing

    /// Records that a node was opened, and the step that got there.
    ///
    /// `from` is nil when the listener arrived from outside a dig — off the
    /// Crate, out of a search. That is a visit but not a step, and counting it
    /// as one would invent a path nobody walked.
    func record(_ node: MusicNode, from origin: MusicNode? = nil) {
        guard writable else { return }
        // Two devices that opened this node made two rows. Folded into one
        // before the count moves, so it moves on the row that stays.
        let dedupe = UserDataDedupe(context: context)
        dedupe.visit(nodeID: node.id)
        if let origin, origin.id != node.id { dedupe.step(identity: "\(origin.id)→\(node.id)") }
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
        guard writable else { return }
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

    /// The row a merge would keep, whether or not one has run.
    func visit(nodeID: String) -> DigVisit? {
        UserDataDedupe.survivor(ofVisits: UserDataDedupe(context: context).rows(forNodeID: nodeID))
    }

    private func step(from: String, to: String) -> DigStep? {
        UserDataDedupe.survivor(
            ofSteps: UserDataDedupe(context: context).rows(forStepIdentity: "\(from)→\(to)"))
    }

    /// "YOU OFTEN DIG THROUGH" — the things this listener keeps going back to.
    ///
    /// Ranked by returns rather than by visits: opening something once is
    /// curiosity, and opening it a fourth time is how they listen. A node seen
    /// exactly once tells you nothing and would crowd out the ones that do.
    ///
    /// The store does the filtering and the ordering. These, `recent` and
    /// `usualNextStep` all used to read their table whole and sort it in
    /// Swift, on the main actor, on every revision — 3.6s of main thread in
    /// one 45-second sample of somebody switching pages.
    func haunts(kinds: Set<MusicNodeKind> = [.label, .artist, .broadcast], limit: Int = 6) -> [DigVisit] {
        let descriptor = FetchDescriptor<DigVisit>(
            predicate: #Predicate { $0.visits > 1 },
            sortBy: [
                SortDescriptor(\.visits, order: .reverse),
                SortDescriptor(\.lastVisitedAt, order: .reverse)
            ]
        )
        return Self.onePerNode((try? context.fetch(descriptor)) ?? [])
            .filter { kinds.contains($0.kind) }
            .prefix(limit)
            .map { $0 }
    }

    /// A list is drawn one row to a node. Until a merge has run, two devices'
    /// rows for the same node are two rows here, and the first -- the most
    /// returned to, or the most recent -- speaks for both.
    private static func onePerNode(_ visits: [DigVisit]) -> [DigVisit] {
        var seen = Set<String>()
        return visits.filter { seen.insert($0.nodeID).inserted }
    }

    /// Where the listener was last, so a dig can be picked back up.
    func recent(limit: Int = 5) -> [DigVisit] {
        // A row that arrived with no visits is not somewhere the listener was.
        var descriptor = FetchDescriptor<DigVisit>(
            predicate: #Predicate { $0.visits > 0 },
            sortBy: [SortDescriptor(\.lastVisitedAt, order: .reverse)]
        )
        // Room for the nodes that appear twice.
        descriptor.fetchLimit = limit * 2
        return Array(Self.onePerNode((try? context.fetch(descriptor)) ?? []).prefix(limit))
    }

    /// "TRY" — where this listener has not been.
    ///
    /// Built by walking out of the places they keep returning to and removing
    /// everything they have already opened. That last part is the whole
    /// point: a suggestion they have seen four times is not a suggestion, and
    /// leaving it in is how a recommendation list turns into a mirror.
    func suggestions(limit: Int = 6) -> [Suggestion] {
        let seen = Set(visits().map(\.nodeID))
        let origins = haunts(kinds: [.artist, .label, .broadcast, .scene], limit: 6)
        guard !origins.isEmpty else { return [] }

        let graph = shared ?? GraphStore(context: context)
        var best: [String: Suggestion] = [:]
        for origin in origins {
            let originNode = origin.node
            // How much this listener trusts the place it came from, flattened
            // so one much-visited label cannot drown out everything else.
            let pull = min(1, 0.5 + Double(origin.visits) / 12)
            // Another name for the same person is not somewhere new. Alias
            // edges carry the highest confidence in the graph, so left in they
            // took the top of TRY every time — "AFX, via Aphex Twin".
            let neighbours = graph.neighbors(of: originNode)
            let family = originNode.kind == .artist ? neighbours.aliasKeys : []
            for connection in neighbours.byDestination
            where !seen.contains(connection.node.id) && connection.node.destination != nil
                && !(connection.node.kind == .artist && family.contains(connection.node.key)) {
                let edges = connection.edges.filter { !$0.kind.isAlias }
                guard !edges.isEmpty else { continue }
                let score = ConfidenceMath.combined(edges.map(\.weight)) * pull
                let candidate = Suggestion(
                    node: connection.node,
                    reasons: edges.map(\.relationship),
                    via: originNode,
                    score: score
                )
                if let existing = best[connection.node.id], existing.score >= score { continue }
                best[connection.node.id] = candidate
            }
        }
        let ranked = best.values
            .sorted { $0.score == $1.score ? $0.node.title < $1.node.title : $0.score > $1.score }
        return Self.varied(ranked, limit: limit)
    }

    /// The strongest suggestions, spread across where they came from.
    ///
    /// Ranked purely by score, the most-visited place took the whole list: an
    /// artist's own records are 0.9-confidence edges, so somebody with 63
    /// visits to Aphex Twin was offered six Aphex Twin records and nothing
    /// else. Each place now gets at most two, one of each kind — a record and
    /// an artist, say. A short list is left short: topping it back up in score
    /// order refilled it from the same place.
    static func varied(_ ranked: [Suggestion], limit: Int, perOrigin: Int = 2) -> [Suggestion] {
        var chosen: [Suggestion] = []
        var fromOrigin: [String: Int] = [:]
        var kindsFromOrigin: Set<String> = []
        for suggestion in ranked where chosen.count < limit {
            let origin = suggestion.via.id
            let kind = "\(origin)|\(suggestion.node.kind.rawValue)"
            guard fromOrigin[origin, default: 0] < perOrigin, !kindsFromOrigin.contains(kind) else { continue }
            chosen.append(suggestion)
            fromOrigin[origin, default: 0] += 1
            kindsFromOrigin.insert(kind)
        }
        return chosen
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
        let best = ((try? context.fetch(
            FetchDescriptor<DigStep>(predicate: #Predicate { $0.fromNodeID == origin })
        )) ?? [])
            .max { $0.count == $1.count ? $0.lastAt < $1.lastAt : $0.count < $1.count }
        return best.flatMap { visit(nodeID: $0.toNodeID) }
    }
}
