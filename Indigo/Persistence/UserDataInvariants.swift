//
//  UserDataInvariants.swift
//  Indigo
//
//  What must be true of every persisted row in the synced store, checked on the
//  rows themselves.
//
//  Three fields are stored beside the parts they are made of, because they are
//  what a predicate or a merge keys on: a listening event's `nodeID` beside its
//  kind and key, a visit's `kindRaw` beside its `nodeID`, a step's `identity`
//  beside its two ends. Redundant data is only safe if it cannot disagree with
//  itself, and once these fields are in a production CloudKit schema a row that
//  does cannot be repaired by changing the schema. So the rows are checked, not
//  just the code that writes them: on every migrated store, and before the
//  schema is initialised.
//

import Foundation
import SwiftData

nonisolated struct InvariantViolation: Equatable, CustomStringConvertible, Sendable {
    let entity: String
    let row: String
    let problem: String
    var description: String { "\(entity) \(row): \(problem)" }
}

nonisolated enum UserDataInvariants {
    // MARK: One row

    static func problems(in event: EventValue) -> [String] {
        var found: [String] = []
        if event.nodeID != MusicNode.canonicalID(kindRaw: event.nodeKindRaw, key: event.nodeKey) {
            found.append("nodeID \(event.nodeID) is not \(event.nodeKindRaw):\(event.nodeKey)")
        }
        if event.nodeKey.isEmpty { found.append("no node key") }
        if MusicNodeKind(rawValue: event.nodeKindRaw) == nil { found.append("unknown node kind \(event.nodeKindRaw)") }
        if ListeningAction(rawValue: event.actionRaw) == nil { found.append("unknown action \(event.actionRaw)") }
        if event.seconds < 0 || !(0...1).contains(event.completion) { found.append("seconds or completion out of range") }
        return found
    }

    static func problems(in visit: VisitValue) -> [String] {
        var found: [String] = []
        if MusicNode.kindRaw(ofID: visit.nodeID) != visit.kindRaw {
            found.append("kindRaw \(visit.kindRaw) is not the kind of \(visit.nodeID)")
        }
        if MusicNodeKind(rawValue: visit.kindRaw) == nil { found.append("unknown node kind \(visit.kindRaw)") }
        if visit.id == nil { found.append("no id") }
        if visit.visits < 0 { found.append("negative visits") }
        if visit.visits > 0, visit.firstVisitedAt > visit.lastVisitedAt { found.append("first visit after the last") }
        return found
    }

    static func problems(in step: StepValue) -> [String] {
        var found: [String] = []
        if step.identity != DigStep.canonicalIdentity(from: step.fromNodeID, to: step.toNodeID) {
            found.append("identity \(step.identity) is not \(step.fromNodeID)→\(step.toNodeID)")
        }
        if MusicNode.kindRaw(ofID: step.fromNodeID) == nil || MusicNode.kindRaw(ofID: step.toNodeID) == nil {
            found.append("an end is not a node id")
        }
        if step.id == nil { found.append("no id") }
        if step.count < 0 { found.append("negative count") }
        return found
    }

    static func problems(in item: CrateValue) -> [String] {
        var found: [String] = []
        if CrateItemKind(rawValue: item.kindRaw) == nil { found.append("unknown kind \(item.kindRaw)") }
        if item.kindRaw == CrateItemKind.recording.rawValue,
           item.matchKey.isEmpty, (item.unknownCode ?? "").isEmpty, item.title != nil {
            found.append("a named recording with no identity")
        }
        return found
    }

    // MARK: A store

    /// Every violation in the rows of `context`, and also that no id repeats.
    static func violations(in context: ModelContext) -> [InvariantViolation] {
        var all: [InvariantViolation] = []
        func add(_ entity: String, _ row: String, _ problems: [String]) {
            all += problems.map { InvariantViolation(entity: entity, row: row, problem: $0) }
        }

        let crate = ((try? context.fetch(FetchDescriptor<CrateItem>())) ?? []).map(CrateValue.init)
        for item in crate { add("CrateItem", item.id.uuidString, problems(in: item)) }
        if Set(crate.map(\.id)).count != crate.count { add("CrateItem", "-", ["an id repeats"]) }

        let events = ((try? context.fetch(FetchDescriptor<ListeningEvent>())) ?? []).map(EventValue.init)
        for event in events { add("ListeningEvent", event.id.uuidString, problems(in: event)) }
        if Set(events.map(\.id)).count != events.count { add("ListeningEvent", "-", ["an id repeats"]) }

        for visit in ((try? context.fetch(FetchDescriptor<DigVisit>())) ?? []).map(VisitValue.init) {
            add("DigVisit", visit.nodeID, problems(in: visit))
        }
        for step in ((try? context.fetch(FetchDescriptor<DigStep>())) ?? []).map(StepValue.init) {
            add("DigStep", step.identity, problems(in: step))
        }
        return all
    }
}
