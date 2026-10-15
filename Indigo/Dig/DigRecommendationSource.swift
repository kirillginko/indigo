//
//  DigRecommendationSource.swift
//  Indigo
//
//  `DigRecommender`'s questions, answered from what this device holds: the
//  page's routes (the identity graph), the records they name and the
//  recordings catalogued with them (the release cache), the radio
//  appearances already known (stored graph answers), whether a musician
//  leads on (`OnwardIndex`), and the listener: long-term taste, the pages
//  opened in the last few hours, and what they already keep or have played.
//
//  Nothing here asks the network; a card is never waited on.
//

import Foundation
import SwiftData

extension DigStore {
    /// The cards for an artist page, worked out once per revision.
    func recommendations(forArtist name: String, discogsID: Int?) -> [DigRecommendation] {
        let key = "\(RecordingKey.normalizeArtist(name))|\(discogsID ?? 0)"
        if let held = recommendationCache[key], held.revision == revision { return held.cards }
        let source = DigRecommendationSource(context: context)
        let now = Date()
        // Taste and what they know move slowly; worked out every few minutes,
        // not on every page.
        if recommendationListener.map({ now.timeIntervalSince($0.at) > 300 }) ?? true {
            recommendationListener = (now, Trace.step("dig.recommend.listener") { source.longTerm(now: now) })
        }
        let cards = Trace.step("dig.recommend.cards", name) {
            source.recommendations(forArtist: name, discogsID: discogsID, now: now, longTerm: recommendationListener?.listener,
                                   shelf: shelfEvidence[RecordingKey.normalizeArtist(name)] ?? [:])
        }
        recommendationCache[key] = (revision, cards)
        return cards
    }
}

nonisolated struct DigRecommendationSource {
    let context: ModelContext
    /// How long a dig is: pages opened within this are this session's.
    static let session: TimeInterval = 3 * 60 * 60

    func recommendations(forArtist name: String, discogsID: Int?, now: Date = Date(),
                         longTerm: DigRecommender.Listener? = nil,
                         shelf: [String: DigRecommender.ShelfEntry] = [:]) -> [DigRecommendation] {
        let origin = MusicNode.artist(name, discogsID: discogsID)
        let edges = IdentityGraph(context: context).neighbourhood(of: origin).edges.all
        return DigRecommender.recommend(from: edges, origin: origin, lookups: lookups(for: name, shelf: shelf),
                                        listener: listener(now: now, opened: origin, longTerm: longTerm))
    }

    func lookups(for name: String, shelf: [String: DigRecommender.ShelfEntry] = [:]) -> DigRecommender.Lookups {
        let ids = GraphStore(context: context).releaseIDs(creditedTo: RecordingKey.normalizeArtist(name))
        var records: [Int: DiscogsReleaseRecord] = [:]
        if !ids.isEmpty {
            let wanted = ids
            let found = (try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>(
                predicate: #Predicate { wanted.contains($0.discogsID) }))) ?? []
            for record in found { records[record.discogsID] = record }
        }
        var byTitle: [String: (id: Int, year: Int?)] = [:]
        for record in records.values.sorted(by: { $0.discogsID < $1.discogsID }) where byTitle[record.title] == nil {
            byTitle[record.title] = (record.discogsID, record.year)
        }
        var lookups = DigRecommender.Lookups()
        lookups.release = { byTitle[$0] }
        lookups.shelf = { shelf[RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator($0.title))] }
        let enricherForRecords = DiscogsEnricher(context: context, client: DiscogsClient())
        lookups.recordings = { id in
            // Not one already known to refuse; unasked is offered, as the
            // release page offers it. A record of somebody else's that the
            // card names is read from the cache too.
            ((records[id] ?? enricherForRecords.cachedRelease(id: id))?.allVideos ?? [])
                .filter { $0.playable != 2 }.map { (url: $0.url, title: $0.title) }
        }
        lookups.tracks = { id in
            guard let record = records[id] ?? enricherForRecords.cachedRelease(id: id) else { return [] }
            return zip(record.trackPositions, record.trackTitles).map { (position: $0.0, title: $0.1) }
        }
        lookups.radio = { artist in radio(for: artist) }
        let onward = OnwardIndex(context: context)
        lookups.onward = { onward.count(for: $0) }
        let enricher = DiscogsEnricher(context: context, client: DiscogsClient())
        lookups.tags = { artist in
            enricher.cachedArtist(named: artist.title).map { ListeningLog.foldTags($0.styles + $0.genres) }
        }
        // Who a bare name is, by the rules every page opens by: an entry the
        // name was verified to, never a guess among namesakes.
        let identities = ArtistIdentityStore(context: context)
        lookups.identity = { artist in
            if artist.discogsID != nil || artist.mbid != nil { return artist }
            let resolved = identities.artistResolution(ArtistReference(name: artist.title))
            guard resolved.isVerified, let id = resolved.identity.discogsID else { return nil }
            var node = MusicNode.artist(resolved.canonicalName, discogsID: id)
            node.artworkURL = artist.artworkURL
            return node
        }
        // The page's own artist under another name: what their entry lists.
        let resolved = identities.artistResolution(ArtistReference(name: name))
        if let id = resolved.identity.discogsID, let facts = identities.facts(id) {
            let ids = Set([id] + facts.aliases.map(\.id))
            let names = Set(([facts.name, facts.realName].compactMap { $0 } + facts.nameVariations + facts.aliases.map(\.name))
                .map(DigRecommender.nameKey))
            lookups.samePerson = { artist in
                artist.discogsID.map(ids.contains) == true || names.contains(DigRecommender.nameKey(artist.title))
            }
        }
        return lookups
    }

    /// A broadcast the stored graph already says they were played on.
    private func radio(for artist: MusicNode) -> DigRecommendation.Listen? {
        for identity in Set([artist.id, MusicNode.artist(artist.title).id]) {
            var rows = FetchDescriptor<StoredEdge>(predicate: #Predicate { $0.fromID == identity && $0.toKindRaw == "broadcast" })
            rows.fetchLimit = 12
            let found = ((try? context.fetch(rows)) ?? [])
                .sorted { $0.occurrences != $1.occurrences ? $0.occurrences > $1.occurrences : $0.toID < $1.toID }
            if let edge = found.first {
                let page = edge.destination
                return .radio(title: page.title, show: page.subtitle, url: nil, page: page)
            }
        }
        return nil
    }

    /// Taste over time and what they already know: slow to read, slow to change.
    func longTerm(now: Date) -> DigRecommender.Listener {
        let personal = PersonalInputs.read(context: context, asOf: now)
        let taste = TasteProfile.collected(
            personal: personal,
            artistTags: LocalKnowledgeAdapter.artistTags(for: personal.tasteArtistKeys, in: context), now: now)
        return DigRecommender.Listener(
            taste: taste, known: Set(personal.crate.compactMap { $0.node?.id }).union(personal.met.map(\.node.id)))
    }

    /// The listener on this page: their long-term taste, and this dig -- the
    /// pages opened in the last few hours and what those pages sound like.
    func listener(now: Date, opened: MusicNode, longTerm: DigRecommender.Listener? = nil) -> DigRecommender.Listener {
        var listener = longTerm ?? self.longTerm(now: now)
        // A click is not a preference: pages opened recently are kept out of
        // the cards, so a dig moves on rather than in circles, and their
        // styles say what this dig is about -- nothing more.
        let since = now.addingTimeInterval(-Self.session)
        let recent = DigHistory(context: context).recent(limit: 60).filter { $0.lastVisitedAt >= since }
        listener.visited = Set(recent.map(\.nodeID)).union([opened.id])
        let artists = [opened.title] + recent.filter { $0.kind == .artist }.prefix(6).map(\.node.title)
        listener.visitedNames = artists
        let enricher = DiscogsEnricher(context: context, client: DiscogsClient())
        var tags: [String] = []
        for name in artists {
            for tag in ListeningLog.foldTags((enricher.cachedArtist(named: name)).map { $0.styles + $0.genres } ?? []) where !tags.contains(tag) {
                tags.append(tag)
            }
        }
        listener.sessionTags = tags
        return listener
    }
}
