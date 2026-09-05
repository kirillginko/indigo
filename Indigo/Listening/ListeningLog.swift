//
//  ListeningLog.swift
//  Indigo
//
//  Reading and writing the encounter log.
//
//  Kept as a struct over a `ModelContext` for the same reason `DigHistory` is:
//  there is no state worth holding, and every caller already has a context.
//  The write side is deliberately narrow — one method — because the value of
//  the log is that every encounter is shaped the same way, and a second
//  entrance is how that stops being true.
//

import Foundation
import SwiftData

nonisolated struct ListeningLog {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Writing

    /// Logs one encounter.
    ///
    /// Returns the row so a caller can attach to it, and discards silently for
    /// a node with no key — an unnamed thing with no identity would be a row
    /// nothing could ever be counted against.
    @discardableResult
    func record(
        _ node: MusicNode,
        action: ListeningAction,
        at: Date = Date(),
        seconds: Double = 0,
        completion: Double = 0,
        tags: [String] = [],
        source: ListeningSource? = nil
    ) -> ListeningEvent? {
        guard !node.key.isEmpty else { return nil }
        let event = ListeningEvent(
            node: node, action: action, at: at,
            seconds: seconds, completion: completion,
            tags: Self.foldTags(tags), source: source
        )
        context.insert(event)
        try? context.save()
        return event
    }

    /// Tags arrive spelled however a provider felt like spelling them —
    /// "Ambient", "ambient", "AMBIENT / DRONE". Folded on the way in, because
    /// a profile that counts three spellings of one interest separately is
    /// three times as confident and no more informed.
    static func foldTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var folded: [String] = []
        for tag in tags {
            for part in tag.split(whereSeparator: { $0 == "/" || $0 == "," }) {
                let cleaned = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !cleaned.isEmpty, cleaned.count > 1 else { continue }
                if seen.insert(cleaned).inserted { folded.append(cleaned) }
            }
        }
        return folded
    }

    func forget() {
        for event in all() { context.delete(event) }
        try? context.save()
    }

    // MARK: - Reading

    func all() -> [ListeningEvent] {
        (try? context.fetch(FetchDescriptor<ListeningEvent>())) ?? []
    }

    /// Everything logged since a moment, newest first.
    func since(_ moment: Date, limit: Int? = nil) -> [ListeningEvent] {
        var descriptor = FetchDescriptor<ListeningEvent>(
            predicate: #Predicate { $0.at >= moment },
            sortBy: [SortDescriptor(\.at, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Every encounter with one thing, newest first.
    func events(for node: MusicNode) -> [ListeningEvent] { events(nodeID: node.id) }

    func events(nodeID: String) -> [ListeningEvent] {
        let descriptor = FetchDescriptor<ListeningEvent>(
            predicate: #Predicate { $0.nodeID == nodeID },
            sortBy: [SortDescriptor(\.at, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// True when this listener has met something before — the check a
    /// recommendation has to pass before it is worth offering.
    func hasEncountered(_ node: MusicNode) -> Bool {
        let identity = node.id
        var descriptor = FetchDescriptor<ListeningEvent>(
            predicate: #Predicate { $0.nodeID == identity }
        )
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.isEmpty == false)
    }

    // MARK: What they have been listening to

    /// The things met most often, of a given kind.
    ///
    /// Ranked by summed weight rather than by row count, so a station left on
    /// all afternoon outranks one clicked into six times and abandoned. Skips
    /// weigh nothing and so drop out on their own.
    func mostMet(kind: MusicNodeKind, since moment: Date? = nil, limit: Int = 6) -> [Encountered] {
        let raw = kind.rawValue
        var descriptor = FetchDescriptor<ListeningEvent>(
            predicate: #Predicate { $0.nodeKindRaw == raw }
        )
        if let moment {
            descriptor.predicate = #Predicate { $0.nodeKindRaw == raw && $0.at >= moment }
        }
        let events = (try? context.fetch(descriptor)) ?? []
        return Self.gather(events)
            .filter { $0.weight > 0 }
            .sorted {
                $0.weight == $1.weight ? $0.lastAt > $1.lastAt : $0.weight > $1.weight
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Which stations this listener favours, heaviest first.
    func stations(since moment: Date? = nil, limit: Int = 8) -> [Encountered] {
        mostMet(kind: .station, since: moment, limit: limit)
    }

    /// Which artists keep turning up.
    func artists(since moment: Date? = nil, limit: Int = 8) -> [Encountered] {
        mostMet(kind: .artist, since: moment, limit: limit)
    }

    /// Everything met, most recently first, one row per thing.
    func recent(limit: Int = 12) -> [Encountered] {
        Self.gather(all())
            .sorted { $0.lastAt > $1.lastAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Encounters with one thing

    /// The whole history with one node, in the shape a page wants to render:
    /// how many times, when it started, when it last happened, and where.
    ///
    /// Nil rather than an empty summary when there is nothing, so a caller can
    /// leave the section out entirely instead of drawing a heading over a
    /// count of zero.
    func encounters(with node: MusicNode) -> Encounters? {
        let events = events(for: node)
        guard !events.isEmpty else { return nil }
        return Encounters(node: node, events: events)
    }

    /// One thing, and everything the log knows about meeting it.
    nonisolated struct Encounters: Sendable {
        let node: MusicNode
        /// Newest first.
        let events: [ListeningEvent]

        /// Encounters that were actually listening, which is what a count
        /// shown to someone should mean. Opening a page four times while
        /// reading about an artist is not hearing them four times.
        var listens: [ListeningEvent] { events.filter { $0.action == .played && $0.weight > 0 } }

        var count: Int { listens.count }
        var firstAt: Date? { events.last?.at }
        var lastAt: Date? { events.first?.at }
        var isSaved: Bool { events.contains { $0.action == .saved } }
        var secondsHeard: Double { events.reduce(0) { $0 + $1.seconds } }

        /// Where they met it, most recent first and each place named once —
        /// "Noods / Endpapers", "NTS / Perfect Sound Forever".
        var places: [Place] {
            var seen = Set<String>()
            var found: [Place] = []
            for event in events {
                guard let line = event.sourceLine else { continue }
                guard seen.insert(line).inserted else { continue }
                found.append(Place(
                    line: line,
                    at: event.at,
                    providerID: event.sourceProviderID,
                    showID: event.sourceShowID,
                    showTitle: event.sourceShowTitle
                ))
            }
            return found
        }

        nonisolated struct Place: Identifiable, Sendable {
            let line: String
            let at: Date
            let providerID: String?
            let showID: String?
            let showTitle: String?

            var id: String { line }

            /// The broadcast this was heard in, when it can be reopened.
            var destination: DetailPage? {
                guard let providerID, let showID else { return nil }
                return BroadcastSource.destination(showID: showID, providerID: providerID)
            }
        }
    }

    // MARK: - Aggregation

    /// One thing, with its encounters summed.
    nonisolated struct Encountered: Identifiable, Sendable {
        let node: MusicNode
        let count: Int
        let weight: Double
        let firstAt: Date
        let lastAt: Date
        let secondsHeard: Double

        var id: String { node.id }
    }

    /// Folds a flat list of events into one row per thing.
    ///
    /// Done in Swift rather than by the store because SwiftData has no group
    /// clause, and because the alternative — a fetch per node — is what turns
    /// a summary into a hundred round trips.
    static func gather(_ events: [ListeningEvent]) -> [Encountered] {
        var byNode: [String: (node: MusicNode, count: Int, weight: Double, first: Date, last: Date, seconds: Double)] = [:]
        for event in events {
            let weight = event.weight
            guard var existing = byNode[event.nodeID] else {
                byNode[event.nodeID] = (event.node, 1, weight, event.at, event.at, event.seconds)
                continue
            }
            existing.count += 1
            existing.weight += weight
            existing.first = min(existing.first, event.at)
            existing.last = max(existing.last, event.at)
            existing.seconds += event.seconds
            // The best-identified spelling wins: a node met by name first and
            // by MBID later should end up knowing both.
            if existing.node.mbid == nil, event.mbid != nil { existing.node = event.node }
            byNode[event.nodeID] = existing
        }
        return byNode.values.map {
            Encountered(
                node: $0.node, count: $0.count, weight: $0.weight,
                firstAt: $0.first, lastAt: $0.last, secondsHeard: $0.seconds
            )
        }
    }
}
