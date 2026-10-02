//
//  UserDataDedupe.swift
//  Indigo
//
//  What the crate, the dig history and the listening log do when two devices
//  have each made a row for the same thing.
//
//  Until now the store said so itself: `@Attribute(.unique)` made a second row
//  for the same visit an update of the first. CloudKit cannot hold that
//  constraint, so rows for one thing can now exist twice, and this is the one
//  place that says what "the same thing" is, which row stays, and what the
//  result holds.
//
//  The rule for every merge is the same, and it is what lets two devices that
//  merge the same rows on their own agree without talking to each other:
//
//    * the merged result is a function of the *set* of rows, never of the order
//      they were found in -- merge(A, B) == merge(B, A), and
//      merge(merge(A, B), C) == merge(A, merge(B, C));
//    * the surviving row is chosen by a total order over properties the rows
//      already have, and keeps the id it was born with. A merge never makes
//      an id: two devices that did would disagree about which row is which;
//    * merging a result again changes nothing.
//
//  Those hold for the pure functions on values below, and are tested there. The
//  operations on a store apply them and delete what they replaced.
//
//  Two things are different and the rule is the same for both. A row with an id
//  of its own -- a crate row, a listening event -- is that id's one thing:
//  different ids are always different things, however alike, and two rows with
//  the *same* id are two copies of one, which a replayed import can make once
//  nothing refuses the second. Rows keyed by what they are about -- a node, a
//  path, a recording -- are the ones that can be two things' worth of the same
//  key, and are merged by it.
//
//  Reading never merges. A lookup uses the same orderings, so it finds the same
//  row the merge will keep, but nothing is written or deleted until somebody
//  calls an operation here.
//
//  Counters are summed. Two devices that each counted their own visits to a
//  node made two rows with two honest counts, and the total is both. The one
//  place that is wrong is a merge that runs on one device while another is
//  still adding to a row it has not yet seen merged: its increments are counted
//  once by the merge that saw them and again by the row they land on. That is
//  bounded by the increments in one sync window and is accepted. It is isolated
//  in `CounterPolicy`, so a better rule changes one function and no caller.
//

import Foundation
import SwiftData

// MARK: - Natural keys

/// What makes two crate rows the same thing.
nonisolated enum CrateKey: Hashable, Sendable {
    case recording(RecordingIdentity)
    case broadcast(providerID: String, showID: String)
    case dig(kind: String, providerID: String, entityID: String)
}

// MARK: - Counters

nonisolated enum CounterPolicy {
    /// How the counts of rows being merged combine. A sum; see the file header
    /// for where that over-counts.
    static func combine(_ counts: [Int]) -> Int { counts.reduce(0, +) }
}

// MARK: - Values
//
// Each of these is a row's mergeable content, copied out of a model. The merge
// is defined on them so that it can be tested without a store and applied to
// one afterwards.

nonisolated struct VisitValue: Equatable, Sendable {
    var id: UUID?
    var nodeID: String
    var kindRaw: String
    var title: String
    var subtitle: String?
    var visits: Int
    var firstVisitedAt: Date
    var lastVisitedAt: Date
    var mbid: String?
    var discogsID: Int?
    var providerID: String?
    var handle: String?

    init(
        id: UUID?, nodeID: String, kindRaw: String = "artist", title: String = "",
        subtitle: String? = nil, visits: Int, firstVisitedAt: Date, lastVisitedAt: Date,
        mbid: String? = nil, discogsID: Int? = nil,
        providerID: String? = nil, handle: String? = nil
    ) {
        self.id = id; self.nodeID = nodeID; self.kindRaw = kindRaw; self.title = title
        self.subtitle = subtitle; self.visits = visits
        self.firstVisitedAt = firstVisitedAt; self.lastVisitedAt = lastVisitedAt
        self.mbid = mbid; self.discogsID = discogsID
        self.providerID = providerID; self.handle = handle
    }

    init(_ visit: DigVisit) {
        self.init(
            id: visit.id, nodeID: visit.nodeID, kindRaw: visit.kindRaw, title: visit.title,
            subtitle: visit.subtitle, visits: visit.visits,
            firstVisitedAt: visit.firstVisitedAt, lastVisitedAt: visit.lastVisitedAt,
            mbid: visit.mbid, discogsID: visit.discogsID,
            providerID: visit.providerID, handle: visit.handle)
    }

    func apply(to visit: DigVisit) {
        visit.kindRaw = kindRaw; visit.title = title; visit.subtitle = subtitle
        visit.visits = visits
        visit.firstVisitedAt = firstVisitedAt; visit.lastVisitedAt = lastVisitedAt
        visit.mbid = mbid; visit.discogsID = discogsID
        visit.providerID = providerID; visit.handle = handle
    }

    /// What the rows were together. Defined on the set: the counts add, the
    /// span widens, and the description comes from the row seen most recently.
    /// Identifiers that only some rows know are kept from whichever has them.
    static func merged(_ rows: [VisitValue]) -> VisitValue? {
        guard let first = rows.first else { return nil }
        // Which row describes the node: the latest, and among rows equally
        // late, the one whose description sorts highest. Content, not ids, so
        // the answer survives merging in any grouping.
        let describing = rows.max { lhs, rhs in
            (lhs.lastVisitedAt, lhs.title, lhs.subtitle ?? "", lhs.kindRaw)
                < (rhs.lastVisitedAt, rhs.title, rhs.subtitle ?? "", rhs.kindRaw)
        } ?? first
        var result = describing
        result.id = rows.map(\.id).min(by: UserDataDedupe.idIsBefore)!
        result.visits = CounterPolicy.combine(rows.map(\.visits))
        result.firstVisitedAt = rows.map(\.firstVisitedAt).min()!
        result.lastVisitedAt = rows.map(\.lastVisitedAt).max()!
        result.mbid = rows.compactMap(\.mbid).max()
        result.discogsID = rows.compactMap(\.discogsID).max()
        result.providerID = rows.compactMap(\.providerID).max()
        result.handle = rows.compactMap(\.handle).max()
        return result
    }
}

nonisolated struct StepValue: Equatable, Sendable {
    var id: UUID?
    var identity: String
    var fromNodeID: String
    var toNodeID: String
    var count: Int
    var lastAt: Date

    init(id: UUID?, identity: String, fromNodeID: String = "", toNodeID: String = "", count: Int, lastAt: Date) {
        self.id = id; self.identity = identity; self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID; self.count = count; self.lastAt = lastAt
    }

    init(_ step: DigStep) {
        self.init(id: step.id, identity: step.identity, fromNodeID: step.fromNodeID,
                  toNodeID: step.toNodeID, count: step.count, lastAt: step.lastAt)
    }

    func apply(to step: DigStep) {
        step.count = count
        step.lastAt = lastAt
    }

    static func merged(_ rows: [StepValue]) -> StepValue? {
        guard var result = rows.first else { return nil }
        result.id = rows.map(\.id).min(by: UserDataDedupe.idIsBefore)!
        result.count = CounterPolicy.combine(rows.map(\.count))
        result.lastAt = rows.map(\.lastAt).max()!
        return result
    }
}

/// One listening event, as its copies are merged. An event is made once and
/// never edited, so copies of it are identical and any of them is the answer;
/// the rule below is for the case where they are not, and gives the same result
/// whichever device runs it.
nonisolated struct EventValue: Equatable, Sendable {
    var id: UUID
    var at: Date
    var actionRaw: String
    var nodeID: String
    var nodeKindRaw: String
    var nodeKey: String
    var title: String
    var subtitle: String?
    var mbid: String?
    var discogsID: Int?
    var providerID: String?
    var handle: String?
    var sourceProviderID: String?
    var sourceShowID: String?
    var sourceShowTitle: String?
    var seconds: Double
    var completion: Double
    var tags: [String]

    init(
        id: UUID, at: Date = .distantPast, actionRaw: String = "played", nodeID: String = "",
        nodeKindRaw: String = "artist", nodeKey: String = "", title: String = "", subtitle: String? = nil,
        mbid: String? = nil, discogsID: Int? = nil, providerID: String? = nil,
        handle: String? = nil, sourceProviderID: String? = nil, sourceShowID: String? = nil,
        sourceShowTitle: String? = nil, seconds: Double = 0, completion: Double = 0, tags: [String] = []
    ) {
        self.id = id; self.at = at; self.actionRaw = actionRaw; self.nodeID = nodeID
        self.nodeKindRaw = nodeKindRaw; self.nodeKey = nodeKey; self.title = title; self.subtitle = subtitle
        self.mbid = mbid; self.discogsID = discogsID
        self.providerID = providerID; self.handle = handle; self.sourceProviderID = sourceProviderID
        self.sourceShowID = sourceShowID; self.sourceShowTitle = sourceShowTitle
        self.seconds = seconds; self.completion = completion; self.tags = tags
    }

    init(_ e: ListeningEvent) {
        self.init(
            id: e.id, at: e.at, actionRaw: e.actionRaw, nodeID: e.nodeID, nodeKindRaw: e.nodeKindRaw,
            nodeKey: e.nodeKey, title: e.title, subtitle: e.subtitle, mbid: e.mbid, discogsID: e.discogsID,
            providerID: e.providerID, handle: e.handle,
            sourceProviderID: e.sourceProviderID, sourceShowID: e.sourceShowID,
            sourceShowTitle: e.sourceShowTitle, seconds: e.seconds, completion: e.completion, tags: e.tags)
    }

    func apply(to e: ListeningEvent) {
        e.at = at; e.actionRaw = actionRaw; e.nodeID = nodeID; e.nodeKindRaw = nodeKindRaw
        e.nodeKey = nodeKey; e.title = title; e.subtitle = subtitle; e.mbid = mbid
        e.discogsID = discogsID; e.providerID = providerID
        e.handle = handle; e.sourceProviderID = sourceProviderID; e.sourceShowID = sourceShowID
        e.sourceShowTitle = sourceShowTitle; e.seconds = seconds; e.completion = completion
        e.tags = tags
    }

    /// Copies of one event, as one: the greatest *whole row* by a total order
    /// over every persisted field. An event is made once and never edited, so
    /// its copies are identical and this returns the event itself; where they
    /// are not, it still returns a row that exists, never fields taken from
    /// several to make one that never did. Commutative, associative and
    /// idempotent, because it is a maximum.
    static func merged(_ rows: [EventValue]) -> EventValue? {
        rows.max { $0.sortKey < $1.sortKey }
    }

    /// Every field, in an order that does not change, with a missing value
    /// sorting before any present one so that `nil` and `""` stay different.
    fileprivate var sortKey: [String] {
        func opt(_ value: String?) -> String { value.map { "1" + $0 } ?? "0" }
        func num(_ value: Double) -> String { String(format: "%020.6f", value + 1_000_000_000_000) }
        return [
            num(at.timeIntervalSinceReferenceDate), actionRaw, nodeID, nodeKindRaw, nodeKey, title,
            opt(subtitle), opt(mbid), opt(discogsID.map { String($0 + 1_000_000_000) }),
            opt(providerID), opt(handle), opt(sourceProviderID),
            opt(sourceShowID), opt(sourceShowTitle), num(seconds), num(completion),
            tags.joined(separator: "\u{1F}")
        ]
    }
}

private extension Array where Element == String {
    static func < (lhs: [String], rhs: [String]) -> Bool {
        for (l, r) in zip(lhs, rhs) where l != r { return l < r }
        return lhs.count < rhs.count
    }
}

nonisolated struct CrateValue: Equatable, Sendable {
    var id: UUID
    var kindRaw: String
    var addedAt: Date
    var matchKey: String
    var unknownCode: String?
    var title: String?
    var artistName: String?
    var albumTitle: String?
    var identificationStatusRaw: String?
    var stationName: String?
    var broadcastOffsetSeconds: Double?
    var providerID: String?
    var showID: String?
    var showTitle: String?
    var showSubtitle: String?
    var artworkURLString: String?
    var playbackURLString: String?
    var embedProviderRaw: String?
    var isLiveStream: Bool
    var genreTagsRaw: String

    init(_ item: CrateItem) {
        id = item.id; kindRaw = item.kindRaw; addedAt = item.addedAt
        matchKey = item.matchKey; unknownCode = item.unknownCode
        title = item.title; artistName = item.artistName; albumTitle = item.albumTitle
        identificationStatusRaw = item.identificationStatusRaw
        stationName = item.stationName; broadcastOffsetSeconds = item.broadcastOffsetSeconds
        providerID = item.providerID; showID = item.showID
        showTitle = item.showTitle; showSubtitle = item.showSubtitle
        artworkURLString = item.artworkURLString; playbackURLString = item.playbackURLString
        embedProviderRaw = item.embedProviderRaw; isLiveStream = item.isLiveStream
        genreTagsRaw = item.genreTagsRaw
    }

    init(
        id: UUID, kindRaw: String = "broadcast", addedAt: Date, providerID: String? = nil,
        showID: String? = nil, showTitle: String? = nil, artworkURLString: String? = nil,
        playbackURLString: String? = nil, embedProviderRaw: String? = nil,
        genreTagsRaw: String = "", isLiveStream: Bool = false
    ) {
        self.id = id; self.kindRaw = kindRaw; self.addedAt = addedAt
        self.matchKey = ""
        self.providerID = providerID; self.showID = showID; self.showTitle = showTitle
        self.artworkURLString = artworkURLString; self.playbackURLString = playbackURLString
        self.embedProviderRaw = embedProviderRaw; self.genreTagsRaw = genreTagsRaw
        self.isLiveStream = isLiveStream
    }

    /// Writes everything but the id and the date the row was made, which are
    /// the survivor's own.
    func apply(to item: CrateItem) {
        item.matchKey = matchKey; item.unknownCode = unknownCode
        item.title = title; item.artistName = artistName; item.albumTitle = albumTitle
        item.identificationStatusRaw = identificationStatusRaw
        item.stationName = stationName; item.broadcastOffsetSeconds = broadcastOffsetSeconds
        item.providerID = providerID; item.showID = showID
        item.showTitle = showTitle; item.showSubtitle = showSubtitle
        item.artworkURLString = artworkURLString; item.playbackURLString = playbackURLString
        item.embedProviderRaw = embedProviderRaw; item.isLiveStream = isLiveStream
        item.genreTagsRaw = genreTagsRaw
    }

    /// The row that was kept first, with whatever it lacked filled in from the
    /// others. The id, the date it was kept, its kind and whether it is a live
    /// stream are the first row's own. Everything else is the greatest
    /// non-empty value any copy holds.
    ///
    /// "Greatest" rather than "the first copy's": a rule that prefers the
    /// earliest copy that has a value cannot give the same answer when copies
    /// are merged two at a time, because the merged pair sits at the position of
    /// its earliest and carries a value from its later one -- a third copy
    /// between them is then outranked. A rule on the values themselves can. Copies
    /// of one kept thing are made from the same provider data and rarely
    /// disagree; when they do, every device picks the same one.
    static func merged(_ rows: [CrateValue]) -> CrateValue? {
        guard var result = rows.min(by: UserDataDedupe.crateIsBefore) else { return nil }
        func greatest(_ path: KeyPath<CrateValue, String?>) -> String? {
            rows.compactMap { $0[keyPath: path] }.filter { !$0.isEmpty }.max()
        }
        result.title = greatest(\.title)
        result.artistName = greatest(\.artistName)
        result.albumTitle = greatest(\.albumTitle)
        result.identificationStatusRaw = greatest(\.identificationStatusRaw)
        result.stationName = greatest(\.stationName)
        result.providerID = greatest(\.providerID)
        result.showID = greatest(\.showID)
        result.showTitle = greatest(\.showTitle)
        result.showSubtitle = greatest(\.showSubtitle)
        result.artworkURLString = greatest(\.artworkURLString)
        result.playbackURLString = greatest(\.playbackURLString)
        result.embedProviderRaw = greatest(\.embedProviderRaw)
        result.unknownCode = greatest(\.unknownCode)
        result.broadcastOffsetSeconds = rows.compactMap(\.broadcastOffsetSeconds).max()
        result.genreTagsRaw = rows.map(\.genreTagsRaw).filter { !$0.isEmpty }.max() ?? ""
        return result
    }
}

// MARK: - The operations

nonisolated struct UserDataDedupe {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    nonisolated struct Report: Equatable {
        var idsAssigned = 0
        var crateMerged = 0
        var eventsMerged = 0
        var visitsMerged = 0
        var stepsMerged = 0
        var isEmpty: Bool { self == Report() }
    }

    // MARK: Keys and orderings

    static func key(of item: CrateItem) -> CrateKey? {
        switch item.kind {
        case .recording:
            guard item.hasRecordingSnapshot else { return nil }
            return .recording(RecordingIdentity(matchKey: item.matchKey, unknownCode: item.unknownCode))
        case .broadcast:
            guard let provider = item.providerID, let show = item.showID else { return nil }
            return .broadcast(providerID: provider, showID: show)
        case .artist, .release, .label:
            guard let provider = item.providerID, let entity = item.showID else { return nil }
            return .dig(kind: item.kindRaw, providerID: provider, entityID: entity)
        }
    }

    /// A row with no id sorts before every row with one.
    static func idIsBefore(_ lhs: UUID?, _ rhs: UUID?) -> Bool {
        (lhs?.uuidString ?? "") < (rhs?.uuidString ?? "")
    }

    /// A crate row that arrived without its date holds `Date.distantPast`, which
    /// sorts to the bottom of a newest-first crate and so is safe to show. It
    /// would also win every "earliest" contest, so a merge treats it as what it
    /// is: no date, and later than any row that has one.
    static func hasDate(_ date: Date) -> Bool { date != .distantPast }

    /// The order crate rows for one thing are kept in: the earliest first, and
    /// among rows made at the same moment by id. A row with no date comes after
    /// every row that has one.
    static func crateIsBefore(_ lhs: CrateValue, _ rhs: CrateValue) -> Bool {
        crateIsBefore(lhs.addedAt, lhs.id, rhs.addedAt, rhs.id)
    }

    static func crateIsBefore(_ lhs: CrateItem, _ rhs: CrateItem) -> Bool {
        crateIsBefore(lhs.addedAt, lhs.id, rhs.addedAt, rhs.id)
    }

    private static func crateIsBefore(_ lhsDate: Date, _ lhsID: UUID, _ rhsDate: Date, _ rhsID: UUID) -> Bool {
        let lhsHas = hasDate(lhsDate), rhsHas = hasDate(rhsDate)
        if lhsHas != rhsHas { return lhsHas }
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhsID.uuidString < rhsID.uuidString
    }

    /// The row a lookup should answer with, now, whether or not a merge has run.
    static func survivor(ofCrate items: [CrateItem]) -> CrateItem? {
        items.min(by: crateIsBefore)
    }

    static func survivor(ofVisits visits: [DigVisit]) -> DigVisit? {
        visits.min { idIsBefore($0.id, $1.id) }
    }

    static func survivor(ofSteps steps: [DigStep]) -> DigStep? {
        steps.min { idIsBefore($0.id, $1.id) }
    }

    // MARK: Ids

    /// Gives every row from before ids existed one, once. After that a row's id
    /// never changes, and a merge keeps one of the ids already there.
    @discardableResult
    func assignIDs() -> Int {
        var assigned = 0
        for visit in (try? context.fetch(FetchDescriptor<DigVisit>(
            predicate: #Predicate { $0.id == nil }))) ?? [] {
            visit.id = UUID(); assigned += 1
        }
        for step in (try? context.fetch(FetchDescriptor<DigStep>(
            predicate: #Predicate { $0.id == nil }))) ?? [] {
            step.id = UUID(); assigned += 1
        }
        return assigned
    }

    /// Whether anything here would be merged, without merging it.
    func hasDuplicates() -> Bool {
        let crate = (try? context.fetch(FetchDescriptor<CrateItem>())) ?? []
        let keys = crate.compactMap { Self.key(of: $0) }
        if Set(keys).count != keys.count { return true }
        if Set(crate.map(\.id)).count != crate.count { return true }
        let events = (try? context.fetch(FetchDescriptor<ListeningEvent>())) ?? []
        if Set(events.map(\.id)).count != events.count { return true }
        let visits = (try? context.fetch(FetchDescriptor<DigVisit>())) ?? []
        if Set(visits.map(\.nodeID)).count != visits.count { return true }
        let steps = (try? context.fetch(FetchDescriptor<DigStep>())) ?? []
        return Set(steps.map(\.identity)).count != steps.count
    }

    // MARK: Merging

    /// Everything, once: ids first, then every group of rows for one thing.
    @discardableResult
    func all() -> Report {
        var report = Report()
        report.idsAssigned = assignIDs()
        if report.idsAssigned > 0 { try? context.save() }

        // Copies of one row first: same id, one thing. Then rows for one key.
        for group in Dictionary(
            grouping: (try? context.fetch(FetchDescriptor<ListeningEvent>())) ?? [], by: \.id
        ).values where group.count > 1 {
            report.eventsMerged += mergeEvents(group)
        }
        for group in Dictionary(
            grouping: (try? context.fetch(FetchDescriptor<CrateItem>())) ?? [], by: \.id
        ).values where group.count > 1 {
            report.crateMerged += mergeCrate(group)
        }
        let crate = (try? context.fetch(FetchDescriptor<CrateItem>())) ?? []
        for group in Dictionary(grouping: crate.compactMap { item in Self.key(of: item).map { ($0, item) } },
                                by: { $0.0 }).values where group.count > 1 {
            report.crateMerged += mergeCrate(group.map(\.1))
        }
        let visits = (try? context.fetch(FetchDescriptor<DigVisit>())) ?? []
        for group in Dictionary(grouping: visits, by: \.nodeID).values where group.count > 1 {
            report.visitsMerged += mergeVisits(group)
        }
        let steps = (try? context.fetch(FetchDescriptor<DigStep>())) ?? []
        for group in Dictionary(grouping: steps, by: \.identity).values where group.count > 1 {
            report.stepsMerged += mergeSteps(group)
        }
        if report.crateMerged + report.eventsMerged + report.visitsMerged + report.stepsMerged > 0 {
            try? context.save()
        }
        return report
    }

    /// Copies of one listening event, by its id. Events with different ids are
    /// different events and are never touched.
    @discardableResult
    func event(id: UUID) -> Int {
        mergeEvents(fetch(FetchDescriptor<ListeningEvent>(predicate: #Predicate { $0.id == id })))
    }

    /// Copies of one crate row, by its id.
    @discardableResult
    func crateRow(id: UUID) -> Int {
        mergeCrate(fetch(FetchDescriptor<CrateItem>(predicate: #Predicate { $0.id == id })))
    }

    @discardableResult
    func crate(key: CrateKey) -> Int {
        mergeCrate(rows(forCrateKey: key))
    }

    @discardableResult
    func visit(nodeID: String) -> Int {
        mergeVisits(rows(forNodeID: nodeID))
    }

    @discardableResult
    func step(identity: String) -> Int {
        mergeSteps(rows(forStepIdentity: identity))
    }

    // MARK: Finding rows for one thing

    func rows(forCrateKey key: CrateKey) -> [CrateItem] {
        switch key {
        case .recording(let identity):
            let kind = CrateItemKind.recording.rawValue
            let matchKey = identity.matchKey
            if let code = identity.unknownCode {
                return fetch(FetchDescriptor<CrateItem>(predicate: #Predicate {
                    $0.kindRaw == kind && $0.matchKey == matchKey && $0.unknownCode == code }))
            }
            return fetch(FetchDescriptor<CrateItem>(predicate: #Predicate {
                $0.kindRaw == kind && $0.matchKey == matchKey && $0.unknownCode == nil }))
        case .broadcast(let provider, let show):
            let kind = CrateItemKind.broadcast.rawValue
            return fetch(FetchDescriptor<CrateItem>(predicate: #Predicate {
                $0.kindRaw == kind && $0.providerID == provider && $0.showID == show }))
        case .dig(let kind, let provider, let entity):
            return fetch(FetchDescriptor<CrateItem>(predicate: #Predicate {
                $0.kindRaw == kind && $0.providerID == provider && $0.showID == entity }))
        }
    }

    func rows(forNodeID nodeID: String) -> [DigVisit] {
        fetch(FetchDescriptor<DigVisit>(predicate: #Predicate { $0.nodeID == nodeID }))
    }

    func rows(forStepIdentity identity: String) -> [DigStep] {
        fetch(FetchDescriptor<DigStep>(predicate: #Predicate { $0.identity == identity }))
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T] {
        (try? context.fetch(descriptor)) ?? []
    }

    // MARK: Applying a merge

    /// Folds `rows` into the one that is kept and deletes the rest. Returns how
    /// many were deleted.
    private func mergeCrate(_ rows: [CrateItem]) -> Int {
        guard rows.count > 1, let kept = Self.survivor(ofCrate: rows),
              let merged = CrateValue.merged(rows.map(CrateValue.init)) else { return 0 }
        merged.apply(to: kept)
        for row in rows where row !== kept { context.delete(row) }
        return rows.count - 1
    }

    /// Copies of one event are equal, so which physical row stays does not
    /// change what it holds; the first by a stable local order is kept.
    private func mergeEvents(_ rows: [ListeningEvent]) -> Int {
        guard rows.count > 1, let merged = EventValue.merged(rows.map(EventValue.init)) else { return 0 }
        let kept = rows.min { String(describing: $0.persistentModelID) < String(describing: $1.persistentModelID) }!
        merged.apply(to: kept)
        for row in rows where row !== kept { context.delete(row) }
        return rows.count - 1
    }

    private func mergeVisits(_ rows: [DigVisit]) -> Int {
        assignMissingIDs(rows)
        guard rows.count > 1, let kept = Self.survivor(ofVisits: rows),
              let merged = VisitValue.merged(rows.map(VisitValue.init)) else { return 0 }
        merged.apply(to: kept)
        for row in rows where row !== kept { context.delete(row) }
        return rows.count - 1
    }

    private func mergeSteps(_ rows: [DigStep]) -> Int {
        assignMissingIDs(rows)
        guard rows.count > 1, let kept = Self.survivor(ofSteps: rows),
              let merged = StepValue.merged(rows.map(StepValue.init)) else { return 0 }
        merged.apply(to: kept)
        for row in rows where row !== kept { context.delete(row) }
        return rows.count - 1
    }

    /// A row that has never been given an id is given one before it is compared,
    /// so which row is kept never depends on a row that has none.
    private func assignMissingIDs(_ visits: [DigVisit]) {
        for visit in visits where visit.id == nil { visit.id = UUID() }
    }

    private func assignMissingIDs(_ steps: [DigStep]) {
        for step in steps where step.id == nil { step.id = UUID() }
    }
}
