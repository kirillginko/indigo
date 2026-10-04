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

    /// Each store's position, `{uuid: n}`. v2: the token kept before named
    /// whichever store wrote last -- usually `Local` -- and is not read.
    static let tokenKey = "userDataHistoryPositions.v2"

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
    /// Told the generation when a row arrives saying the store was written by
    /// a build newer than this one. Nothing in that pass is merged; see
    /// `SyncGeneration`.
    var onNewerGeneration: ((Int) -> Void)? = nil

    init(context: ModelContext, defaults: UserDefaults = .standard, ownAuthor: String? = nil) {
        self.context = context
        self.defaults = defaults
        self.ownAuthor = ownAuthor
    }

    /// What was found and merged.
    @discardableResult
    func process() -> UserDataDedupe.Report {
        let dedupe = UserDataDedupe(context: context)
        let positions = storedPositions()
        let token = positions.flatMap(Self.token(at:))

        // The container holds two stores, and a transaction's token names only
        // its own. Resuming from one transaction's token -- usually a `Local`
        // cache write, which outnumber the listener's by hundreds to one --
        // left the other store's position unknown. So the place kept is every
        // store's newest position, merged, and only UserData's transactions
        // are acted on.
        // With no place to resume from, the history is not read at all: see
        // `startFromNow`.
        guard let token else { return startFromNow(dedupe) }
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        descriptor.predicate = #Predicate { $0.token > token }
        let fetched = Trace.step("userdata.history") {
            try? context.fetchHistory(descriptor)
        }
        guard let transactions = fetched else {
            onPass?(Pass(hadToken: true, transactions: -1))
            return fullPass(dedupe)
        }
        // Nothing since the last pass.
        if transactions.isEmpty {
            onPass?(Pass(hadToken: true))
            return .init()
        }

        // What the history names, by entity. It names rows that have since been
        // deleted -- a removal on another device is an insert and a delete --
        // and asking for the model of a row that is gone and reading it traps.
        // So the identifiers are only ever used to *fetch*, which returns the
        // rows that are still there and nothing else.
        var changed: [String: Set<PersistentIdentifier>] = [:]
        var reached = positions ?? [:]
        var pass = Pass(hadToken: true, transactions: transactions.count)
        let userData = storeIdentity

        for transaction in transactions {
            for (store, position) in Self.positions(of: transaction.token) { reached[store] = max(reached[store] ?? 0, position) }
            if let userData, transaction.storeIdentifier != userData { continue }
            if let ownAuthor, transaction.author == ownAuthor { continue }
            pass.foreign += 1
            for change in transaction.changes {
                switch change {
                case .insert(let insert): changed[insert.changedPersistentIdentifier.entityName, default: []].insert(insert.changedPersistentIdentifier)
                case .update(let update): changed[update.changedPersistentIdentifier.entityName, default: []].insert(update.changedPersistentIdentifier)
                default: continue
                }
            }
        }

        var named = UserDataDedupe.Named()
        var generation: Int?
        for chunk in Self.chunks(changed["CrateItem"]) {
            for item in (try? context.fetch(FetchDescriptor<CrateItem>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))) ?? [] {
                named.crateIDs.insert(item.id)
                if let key = UserDataDedupe.key(of: item) { named.crateKeys.insert(key) }
            }
        }
        for chunk in Self.chunks(changed["ListeningEvent"]) {
            for event in (try? context.fetch(FetchDescriptor<ListeningEvent>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))) ?? [] {
                named.eventIDs.insert(event.id)
            }
        }
        for chunk in Self.chunks(changed["DigVisit"]) {
            for visit in (try? context.fetch(FetchDescriptor<DigVisit>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))) ?? [] {
                named.visits.insert(visit.nodeID)
            }
        }
        for chunk in Self.chunks(changed["DigStep"]) {
            for step in (try? context.fetch(FetchDescriptor<DigStep>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))) ?? [] {
                named.steps.insert(step.identity)
            }
        }
        // A component from another device changes what its row should say, and
        // may arrive before or after that row. Either order ends the same way:
        // the row is projected when the component arrives, and again when the
        // row does.
        for chunk in Self.chunks(changed["DigCounter"]) {
            for counter in (try? context.fetch(FetchDescriptor<DigCounter>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))) ?? [] {
                guard let kind = counter.kind else { continue }
                named.counters.insert(.init(kind: kind, key: counter.key))
                if kind == .generation { generation = max(generation ?? 0, counter.count) }
            }
        }
        // A newer build wrote this store. Its rows are left as it wrote them,
        // and the place is not kept, so a later pass sees them again.
        if SyncGeneration.isNewer(generation), let generation {
            onPass?(pass)
            onNewerGeneration?(generation)
            return .init()
        }

        pass.named = changed.values.reduce(0) { $0 + $1.count }
        pass.fetched = named.crateIDs.count + named.eventIDs.count + named.visits.count + named.steps.count + named.counters.count
        let report = Trace.step("userdata.merge", "\(pass.fetched) keys") { dedupe.merge(named) }
        if !report.isEmpty || context.hasChanges { try? context.save() }
        pass.merged = report.crateMerged + report.eventsMerged + report.visitsMerged + report.stepsMerged + report.countersMerged
        onPass?(pass)

        store(reached)
        return report
    }

    /// Identifiers in groups small enough for one predicate.
    private static func chunks(_ identifiers: Set<PersistentIdentifier>?) -> [[PersistentIdentifier]] {
        guard let identifiers, !identifiers.isEmpty else { return [] }
        let all = Array(identifiers)
        return stride(from: 0, to: all.count, by: 400).map { Array(all[$0..<min($0 + 400, all.count)]) }
    }

    /// A pass with no place to resume from: dedupe what is in the tables, and
    /// take up the history from where each store is now.
    ///
    /// Reading the history from its start meant reading the cache's too. A
    /// fetch cannot be limited to one store, the cache writes hundreds of
    /// times for every write of the listener's, and a new UserData store beside
    /// a well-used cache (38,569 transactions) held the main thread for 41
    /// seconds at launch to find 35. A token cannot skip only the cache either:
    /// a store left out of one returns nothing, and a position before a store's
    /// oldest transaction is refused as expired.
    ///
    /// So the newest transaction of each store is read from its file first;
    /// then every row already there is merged from the tables; then that is
    /// the place. Whatever commits after the positions were read is after the
    /// place, and the next pass reads it. If the files cannot be read -- stores
    /// in memory -- it falls back to the full pass.
    private func startFromNow(_ dedupe: UserDataDedupe) -> UserDataDedupe.Report {
        guard let now = newestPositions() else { return fullPass(dedupe) }
        if let generation = SyncGeneration.advertised(in: context), SyncGeneration.isNewer(generation) {
            onPass?(Pass())
            onNewerGeneration?(generation)
            return .init()
        }
        let report = Trace.step("userdata.merge", "every row") { dedupe.merge(dedupe.everything()) }
        if !report.isEmpty || context.hasChanges { try? context.save() }
        var pass = Pass()
        pass.merged = report.crateMerged + report.eventsMerged + report.visitsMerged + report.stepsMerged + report.countersMerged
        onPass?(pass)
        store(now)
        return report
    }

    /// Each store's newest transaction, from the history table in its file
    /// (`Z_PK` is the position a token holds for that store). A store with no
    /// history yet has none; UserData without one is kept from being a place
    /// by `storedPositions`, so the next pass starts from the tables again --
    /// cheap, since a store with no history is new. Nil only when no file could
    /// be read at all: stores in memory.
    private func newestPositions() -> [String: Int]? {
        var positions: [String: Int] = [:]
        for configuration in context.container.configurations {
            let url = configuration.url
            guard let store = Self.uuid(of: url),
                  let newest = SQLiteFiles.integer("SELECT MAX(Z_PK) FROM ATRANSACTION", in: url) else { continue }
            positions[store] = newest
        }
        return positions.isEmpty ? nil : positions
    }

    private func fullPass(_ dedupe: UserDataDedupe) -> UserDataDedupe.Report {
        let report = dedupe.all()
        var reached: [String: Int] = [:]
        for transaction in (try? context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())) ?? [] {
            for (store, position) in Self.positions(of: transaction.token) { reached[store] = max(reached[store] ?? 0, position) }
        }
        store(reached)
        return report
    }

    // MARK: The place

    /// Each store's position in a token: `{"storeTokens": {uuid: n}}`, the
    /// form SwiftData encodes it in. A token that does not read that way gives
    /// nothing, and the next pass is a full one.
    static func positions(of token: DefaultHistoryToken) -> [String: Int] {
        guard let data = try? JSONEncoder().encode(token),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stores = object["storeTokens"] as? [String: Any] else { return [:] }
        return stores.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    static func token(at positions: [String: Int]) -> DefaultHistoryToken? {
        guard !positions.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["storeTokens": positions]) else { return nil }
        return try? JSONDecoder().decode(DefaultHistoryToken.self, from: data)
    }

    /// Where the last pass got to, store by store -- if it is about these
    /// stores. A position in a store that has since been made again names
    /// nothing in it, so it is dropped; without UserData's own, the place is
    /// not trusted and the next pass is a full one.
    private func storedPositions() -> [String: Int]? {
        guard let data = defaults.data(forKey: Self.tokenKey),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Int], !saved.isEmpty else { return nil }
        let known = knownStores
        guard !known.isEmpty else { return saved }           // stores in memory say nothing
        let kept = saved.filter { known.contains($0.key) }
        guard let userData = storeIdentity, kept[userData] != nil else { return nil }
        return kept
    }

    private func store(_ positions: [String: Int]) {
        guard !positions.isEmpty, let data = try? JSONSerialization.data(withJSONObject: positions) else { return }
        defaults.set(data, forKey: Self.tokenKey)
    }

    /// The UUID Core Data gave the `UserData` store when it was made.
    private var storeIdentity: String? {
        let configurations = context.container.configurations
        return Self.uuid(of: (configurations.first { $0.name == "UserData" } ?? configurations.first)?.url)
    }

    /// Every store on disk in the container.
    private var knownStores: Set<String> {
        Set(context.container.configurations.compactMap { Self.uuid(of: $0.url) })
    }

    private static func uuid(of url: URL?) -> String? {
        guard let url, url.path != "/dev/null", FileManager.default.fileExists(atPath: url.path),
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        else { return nil }
        return metadata[NSStoreUUIDKey] as? String
    }
}
