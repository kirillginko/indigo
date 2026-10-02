//
//  IdentityBackfill.swift
//  Indigo
//
//  Rewrites the listening log and the dig history so that what recording an
//  encounter was with is in its node, and only there.
//
//  Until now an event or a visit also kept a local `Recording.id`, which is the
//  one thing in them that means nothing on another device. The node's key is
//  the recording's identity -- `RecordingIdentity`, the same everywhere -- but
//  for the recordings that share a match key, the key alone named all of them:
//  a visit to one "Unreleased" was filed under the key every "Unreleased" has,
//  and only its recording id said which. This reads the id once, writes the
//  identity into the node, and from then on the id is evidence and not data.
//
//  Never deletes history. A row whose recording this device no longer has keeps
//  the key it had, which is still a valid identity, and is counted. Rows are
//  only ever rewritten to the identity of the recording their id pointed at,
//  and merged only when that lands two visits on one node.
//
//  Safe to run twice, and to stop part-way: a row already in line is left
//  alone, and progress is saved before anything is looked up.
//

import Foundation
import SwiftData

nonisolated enum IdentityBackfill {
    nonisolated struct Report: Equatable {
        /// Events and visits whose node was rewritten to the identity their
        /// recording id pointed at.
        var eventsRewritten = 0
        var visitsRewritten = 0
        /// Steps whose ends were rewritten with them.
        var stepsRewritten = 0
        /// Visits and steps folded into another because a rewrite put them on
        /// the same node.
        var merged = 0
        /// Rows whose recording id points at nothing on this device. Kept, with
        /// the key they had.
        var unresolved = 0
        /// Steps left alone because their node was rewritten to more than one
        /// thing and nothing says which end they meant.
        var ambiguousSteps = 0
        /// Rewritten rows that do not name the recording their id pointed at.
        var mismatches = 0
    }

    static let versionKey = "identityBackfillVersion"
    static let version = 1

    @discardableResult
    static func run(in context: ModelContext) throws -> Report {
        var report = Report()
        let store = RecordingStore(context: context)

        // Identity has to be unique before anything is written against it.
        let repair = store.repairIdentities()
        if repair.cleared > 0 || repair.assigned > 0 { try context.save() }

        var targets: [String: Set<String>] = [:]   // old node id -> new node ids

        // Events
        let events = try context.fetch(FetchDescriptor<ListeningEvent>(
            predicate: #Predicate { $0.legacyRecordingID != nil }))
        var rewrittenEvents: [(ListeningEvent, RecordingIdentity)] = []
        for event in events {
            guard let id = event.legacyRecordingID, let recording = try store.recording(id: id) else {
                report.unresolved += 1
                continue
            }
            let node = MusicNode.recording(recording)
            targets[event.nodeID, default: []].insert(node.id)
            if event.nodeID != node.id {
                event.nodeID = node.id
                event.nodeKindRaw = node.kind.rawValue
                event.nodeKey = node.key
                report.eventsRewritten += 1
            }
            rewrittenEvents.append((event, RecordingIdentity(recording)))
        }
        try context.save()

        // Visits
        let visits = try context.fetch(FetchDescriptor<DigVisit>(
            predicate: #Predicate { $0.legacyRecordingID != nil }))
        var rewrittenVisits: [(DigVisit, RecordingIdentity)] = []
        for visit in visits {
            guard let id = visit.legacyRecordingID, let recording = try store.recording(id: id) else {
                report.unresolved += 1
                continue
            }
            let node = MusicNode.recording(recording)
            targets[visit.nodeID, default: []].insert(node.id)
            if visit.nodeID != node.id {
                let newID = node.id
                var descriptor = FetchDescriptor<DigVisit>(predicate: #Predicate { $0.nodeID == newID })
                descriptor.fetchLimit = 1
                if let existing = try context.fetch(descriptor).first, existing !== visit {
                    existing.visits += visit.visits
                    existing.firstVisitedAt = min(existing.firstVisitedAt, visit.firstVisitedAt)
                    existing.lastVisitedAt = max(existing.lastVisitedAt, visit.lastVisitedAt)
                    context.delete(visit)
                    report.merged += 1
                    report.visitsRewritten += 1
                    continue
                }
                visit.nodeID = node.id
                visit.kindRaw = node.kind.rawValue
                report.visitsRewritten += 1
            }
            rewrittenVisits.append((visit, RecordingIdentity(recording)))
        }
        try context.save()

        // Steps. A step names its ends by node id, and an end that was rewritten
        // is rewritten here, when the old id meant one thing.
        let moves = targets.compactMapValues { $0.count == 1 ? $0.first : nil }
            .filter { $0.key != $0.value }
        let ambiguous = Set(targets.filter { $0.value.count > 1 }.keys)
        if !moves.isEmpty || !ambiguous.isEmpty {
            for step in try context.fetch(FetchDescriptor<DigStep>()) {
                if ambiguous.contains(step.fromNodeID) || ambiguous.contains(step.toNodeID) {
                    report.ambiguousSteps += 1
                }
                let from = moves[step.fromNodeID] ?? step.fromNodeID
                let to = moves[step.toNodeID] ?? step.toNodeID
                guard from != step.fromNodeID || to != step.toNodeID else { continue }
                let identity = "\(from)→\(to)"
                var descriptor = FetchDescriptor<DigStep>(predicate: #Predicate { $0.identity == identity })
                descriptor.fetchLimit = 1
                if let existing = try context.fetch(descriptor).first, existing !== step {
                    existing.count += step.count
                    existing.lastAt = max(existing.lastAt, step.lastAt)
                    context.delete(step)
                    report.merged += 1
                } else {
                    step.fromNodeID = from
                    step.toNodeID = to
                    step.identity = identity
                }
                report.stepsRewritten += 1
            }
            try context.save()
        }

        // Verify against what the id pointed at, not against the rewrite.
        for (event, identity) in rewrittenEvents {
            if RecordingIdentity(node: event.node) != identity { report.mismatches += 1 }
        }
        for (visit, identity) in rewrittenVisits where !visit.isDeleted {
            if RecordingIdentity(node: visit.node) != identity { report.mismatches += 1 }
        }
        return report
    }

    /// Once per install, and marked done only when nothing disagreed.
    @discardableResult
    static func runOnce(in context: ModelContext, defaults: UserDefaults = .standard) -> Report? {
        guard defaults.integer(forKey: versionKey) < version else { return nil }
        guard let report = try? run(in: context) else { return nil }
        if report.mismatches == 0 { defaults.set(version, forKey: versionKey) }
        return report
    }
}
