//
//  HistoryObserver.swift
//  Indigo
//
//  Finds the rows another writer made, and has them deduplicated.
//
//  Once the listener's data syncs, rows arrive from outside this process --
//  imported by CloudKit on a context of its own -- and two devices' rows for the
//  same thing arrive as two rows. SwiftData keeps a history of every
//  transaction, with who made it. This reads the ones this context did not
//  make, since the last one it read, takes the natural key of each row they
//  inserted or changed, and merges only those keys through `UserDataDedupe`.
//
//  It reads the history and never trusts it: if the history cannot be read, or
//  the token it kept no longer names anything, it falls back to one full pass,
//  which is correct and only slower.
//

import Foundation
import SwiftData

@MainActor
struct HistoryObserver {
    let context: ModelContext
    let defaults: UserDefaults
    /// The author of this process's own writes, which are not looked at.
    let ownAuthor: String?

    static let tokenKey = "userDataHistoryToken"

    init(context: ModelContext, defaults: UserDefaults = .standard, ownAuthor: String? = nil) {
        self.context = context
        self.defaults = defaults
        self.ownAuthor = ownAuthor
    }

    /// What was found and merged.
    @discardableResult
    func process() -> UserDataDedupe.Report {
        let dedupe = UserDataDedupe(context: context)
        let token = storedToken()

        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let token { descriptor.predicate = #Predicate { $0.token > token } }
        guard let transactions = try? context.fetchHistory(descriptor) else {
            return fullPass(dedupe)
        }
        // A token that names nothing any more returns the whole history or none
        // of it; either way what it cannot tell us is covered by a full pass.
        if token != nil, transactions.isEmpty { return .init() }

        var crate = Set<CrateKey>()
        var crateIDs = Set<UUID>()
        var eventIDs = Set<UUID>()
        var visits = Set<String>()
        var steps = Set<String>()
        var newest: DefaultHistoryToken?

        for transaction in transactions {
            newest = transaction.token
            if let ownAuthor, transaction.author == ownAuthor { continue }
            for change in transaction.changes {
                let identifier: PersistentIdentifier
                switch change {
                case .insert(let insert): identifier = insert.changedPersistentIdentifier
                case .update(let update): identifier = update.changedPersistentIdentifier
                default: continue
                }
                switch identifier.entityName {
                case "CrateItem":
                    if let item = context.model(for: identifier) as? CrateItem {
                        crateIDs.insert(item.id)
                        if let key = UserDataDedupe.key(of: item) { crate.insert(key) }
                    }
                case "ListeningEvent":
                    if let event = context.model(for: identifier) as? ListeningEvent { eventIDs.insert(event.id) }
                case "DigVisit":
                    if let visit = context.model(for: identifier) as? DigVisit { visits.insert(visit.nodeID) }
                case "DigStep":
                    if let step = context.model(for: identifier) as? DigStep { steps.insert(step.identity) }
                default:
                    continue
                }
            }
        }

        var report = UserDataDedupe.Report()
        report.idsAssigned = dedupe.assignIDs()
        for id in eventIDs { report.eventsMerged += dedupe.event(id: id) }
        for id in crateIDs { report.crateMerged += dedupe.crateRow(id: id) }
        for key in crate { report.crateMerged += dedupe.crate(key: key) }
        for nodeID in visits { report.visitsMerged += dedupe.visit(nodeID: nodeID) }
        for identity in steps { report.stepsMerged += dedupe.step(identity: identity) }
        if !report.isEmpty { try? context.save() }

        if let newest { store(newest) }
        return report
    }

    private func fullPass(_ dedupe: UserDataDedupe) -> UserDataDedupe.Report {
        let report = dedupe.all()
        if let latest = try? context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).last?.token {
            store(latest)
        }
        return report
    }

    // MARK: The token

    private func storedToken() -> DefaultHistoryToken? {
        defaults.data(forKey: Self.tokenKey).flatMap { try? JSONDecoder().decode(DefaultHistoryToken.self, from: $0) }
    }

    private func store(_ token: DefaultHistoryToken) {
        if let data = try? JSONEncoder().encode(token) { defaults.set(data, forKey: Self.tokenKey) }
    }
}
