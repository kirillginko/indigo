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

import CoreData
import Foundation
import SwiftData

@MainActor
struct HistoryObserver {
    let context: ModelContext
    let defaults: UserDefaults
    /// The author of this process's own writes, which are not looked at.
    let ownAuthor: String?

    static let tokenKey = "userDataHistoryToken"
    /// Which store the token belongs to. A token is a place in one store's
    /// history; a store made again at the same path has a history of its own,
    /// and the old token compares as newer than all of it.
    static let storeKey = "userDataHistoryStore"

    /// What one pass looked at, as counts. For a harness that wants to know why
    /// a pass did nothing; the app does not set it.
    nonisolated struct Pass: Sendable {
        var hadToken = false
        var transactions = 0
        var foreign = 0
        var named = 0
        var fetched = 0
        var merged = 0
    }
    var onPass: ((Pass) -> Void)? = nil

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
            onPass?(Pass(hadToken: token != nil, transactions: -1))
            return fullPass(dedupe)
        }
        // A token that names nothing any more returns the whole history or none
        // of it; either way what it cannot tell us is covered by a full pass.
        if token != nil, transactions.isEmpty {
            onPass?(Pass(hadToken: true))
            return .init()
        }

        // What the history names, by entity. It names rows that have since been
        // deleted -- a removal on another device is an insert and a delete --
        // and asking for the model of a row that is gone and reading it traps.
        // So the identifiers are only ever used to *fetch*, which returns the
        // rows that are still there and nothing else.
        var named: [String: Set<PersistentIdentifier>] = [:]
        var newest: DefaultHistoryToken?
        var pass = Pass(hadToken: token != nil, transactions: transactions.count)

        for transaction in transactions {
            newest = transaction.token
            if let ownAuthor, transaction.author == ownAuthor { continue }
            pass.foreign += 1
            for change in transaction.changes {
                switch change {
                case .insert(let insert): named[insert.changedPersistentIdentifier.entityName, default: []].insert(insert.changedPersistentIdentifier)
                case .update(let update): named[update.changedPersistentIdentifier.entityName, default: []].insert(update.changedPersistentIdentifier)
                default: continue
                }
            }
        }

        var crate = Set<CrateKey>()
        var crateIDs = Set<UUID>()
        var eventIDs = Set<UUID>()
        var visits = Set<String>()
        var steps = Set<String>()
        for chunk in Self.chunks(named["CrateItem"]) {
            for item in (try? context.fetch(FetchDescriptor<CrateItem>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))) ?? [] {
                crateIDs.insert(item.id)
                if let key = UserDataDedupe.key(of: item) { crate.insert(key) }
            }
        }
        for chunk in Self.chunks(named["ListeningEvent"]) {
            for event in (try? context.fetch(FetchDescriptor<ListeningEvent>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))) ?? [] {
                eventIDs.insert(event.id)
            }
        }
        for chunk in Self.chunks(named["DigVisit"]) {
            for visit in (try? context.fetch(FetchDescriptor<DigVisit>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))) ?? [] {
                visits.insert(visit.nodeID)
            }
        }
        for chunk in Self.chunks(named["DigStep"]) {
            for step in (try? context.fetch(FetchDescriptor<DigStep>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))) ?? [] {
                steps.insert(step.identity)
            }
        }

        pass.named = named.values.reduce(0) { $0 + $1.count }
        pass.fetched = crateIDs.count + eventIDs.count + visits.count + steps.count
        var report = UserDataDedupe.Report()
        report.idsAssigned = dedupe.assignIDs()
        for id in eventIDs { report.eventsMerged += dedupe.event(id: id) }
        for id in crateIDs { report.crateMerged += dedupe.crateRow(id: id) }
        for key in crate { report.crateMerged += dedupe.crate(key: key) }
        for nodeID in visits { report.visitsMerged += dedupe.visit(nodeID: nodeID) }
        for identity in steps { report.stepsMerged += dedupe.step(identity: identity) }
        if !report.isEmpty { try? context.save() }
        pass.merged = report.crateMerged + report.eventsMerged + report.visitsMerged + report.stepsMerged
        onPass?(pass)

        if let newest { store(newest) }
        return report
    }

    /// Identifiers in groups small enough for one predicate.
    private static func chunks(_ identifiers: Set<PersistentIdentifier>?) -> [[PersistentIdentifier]] {
        guard let identifiers, !identifiers.isEmpty else { return [] }
        let all = Array(identifiers)
        return stride(from: 0, to: all.count, by: 400).map { Array(all[$0..<min($0 + 400, all.count)]) }
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
        guard let token = defaults.data(forKey: Self.tokenKey)
            .flatMap({ try? JSONDecoder().decode(DefaultHistoryToken.self, from: $0) }) else { return nil }
        // A store on disk can say who it is; one in memory cannot, and its
        // token is trusted as it always was.
        guard let current = storeIdentity else { return token }
        return defaults.string(forKey: Self.storeKey) == current ? token : nil
    }

    private func store(_ token: DefaultHistoryToken) {
        if let data = try? JSONEncoder().encode(token) { defaults.set(data, forKey: Self.tokenKey) }
        defaults.set(storeIdentity, forKey: Self.storeKey)
    }

    /// The UUID Core Data gave the `UserData` store when it was made.
    private var storeIdentity: String? {
        let configurations = context.container.configurations
        guard let url = (configurations.first { $0.name == "UserData" } ?? configurations.first)?.url,
              url.path != "/dev/null", FileManager.default.fileExists(atPath: url.path),
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        else { return nil }
        return metadata[NSStoreUUIDKey] as? String
    }
}
