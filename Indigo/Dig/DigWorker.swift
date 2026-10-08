//
//  DigWorker.swift
//  Indigo
//
//  The graph, walked somewhere other than the main thread.
//
//  Building a profile reads most of the store and walks every edge out of a
//  node. Done on the main actor — which is where a `@Model`-backed context
//  lives by default — that work happens between two frames, and the scroll
//  stops for as long as it takes. Moving it behind a `@ModelActor` gives it
//  its own context on its own executor, and the main thread only ever
//  receives the finished value.
//
//  Everything crossing that boundary is already a `Sendable` value type:
//  profiles, descents, scenes and connections are all plain structs built
//  from the store rather than references into it. That is what makes this a
//  change of thread rather than a change of design.
//

import Foundation
import SwiftData

/// Deliberately a plain actor rather than `@ModelActor`.
///
/// `@ModelActor` supplies a `DefaultSerialModelExecutor`, and a serial
/// executor is only obliged to serialise — not to own a thread. In practice
/// it can run a job inline on whichever thread enqueued it, and when that
/// thread is the main one the whole point of this type is lost: the table
/// reads and the graph walk happen on the thread that is drawing the page.
///
/// A test pinned this down. `runsOffTheMainThread()` passed when run alone
/// and failed inside the full suite — the same call landing on a different
/// thread depending on what else was running, which is exactly the kind of
/// intermittent stall that makes a scroll catch.
///
/// A plain actor has no custom executor, so its jobs go to the cooperative
/// pool, which is never the main thread. The context is made here and never
/// leaves, which is the same guarantee `@ModelActor` was giving.
actor DigWorker {
    let modelContainer: ModelContainer
    let modelContext: ModelContext

    /// Nothing configured here: `DiscogsClient()` reads the same credential
    /// the store's does, and it is a value type with no state of its own.
    private let discogs = DiscogsClient()

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
    }

    /// One engine, kept until something is written.
    ///
    /// Its caches are six whole tables, and a single page asks several
    /// questions — the profile, the descent, the scenes, the connections.
    /// Rebuilding that for each of them was most of the time it took to open
    /// anything.
    private var graph: GraphStore?
    private var engine: DigEngine?
    private var deep: DeepEngine?
    private var scenes: SceneEngine?
    /// Built on demand rather than with the engines: it reads six tables and
    /// most sessions never type into the search field. See `DigSearchIndex`.
    private var searchIndex: DigSearchIndex?
    private var generation = -1

    /// Whether this actor's work actually happens off the main thread.
    ///
    /// `@ModelActor` supplies its own serial executor, and a serial executor
    /// is not obliged to own a thread — it only has to serialise. If it runs
    /// jobs on whichever thread enqueued them, every "background" walk in
    /// here happens on the main one, which is the opposite of why this type
    /// exists.
    func runsOffTheMainThread() -> Bool { !Thread.isMainThread }

    private func refresh(_ asked: Int) {
        guard generation != asked else { return }
        // One graph per generation, and it inherits the last one's tables
        // when nothing has been inserted since. See `Caches.rowCounts`.
        let next = GraphStore(context: modelContext, inheriting: graph)
        graph = next
        engine = DigEngine(context: modelContext, graph: next)
        deep = DeepEngine(context: modelContext, graph: next)
        scenes = SceneEngine(context: modelContext, inheriting: scenes)
        // The index is deliberately *not* discarded here any more.
        //
        // It used to be, and every write moves the generation — so a listener
        // typing while the catalogue answered paid 3,591ms to rebuild six
        // tables before the next letter could be matched, over and over, which
        // is precisely when somebody is watching. `searchLocally` now asks the
        // index whether it still describes the store, which is six counts.
        generation = asked
    }

    /// Matches on this machine for a typed query.
    ///
    /// The index is the expensive half and it does not change between
    /// keystrokes, so it is built once per generation and kept — the same
    /// bargain the graph makes above.
    func searchLocally(_ query: String, limit: Int, generation asked: Int) -> [DigSearchResult] {
        refresh(asked)
        if let kept = searchIndex, kept.stillDescribes(modelContext) {
            return kept.search(query, limit: limit)
        }
        let index = Trace.step("search.index") { DigSearchIndex(context: modelContext) }
        searchIndex = index
        return index.search(query, limit: limit)
    }

    private func engine(_ asked: Int) -> DigEngine {
        refresh(asked)
        return engine ?? DigEngine(context: modelContext)
    }

    private func deepEngine(_ asked: Int) -> DeepEngine {
        refresh(asked)
        return deep ?? DeepEngine(context: modelContext)
    }

    private func sceneEngine(_ asked: Int) -> SceneEngine {
        refresh(asked)
        return scenes ?? SceneEngine(context: modelContext)
    }

    // MARK: - For You

    /// What For You's knowledge is kept for between looks, part by part.
    ///
    /// Each part is worked out again only when what it is about changes, or
    /// when it has stood for `knowledgeLifetime`. A play or a new record in
    /// the crate changes the listener's rows, not what is known about music:
    /// the neighbourhoods are kept for every starting point that is still a
    /// starting point, and only a new one is walked. The lifetime is the
    /// quarter of an hour the kept answer used to stand for -- enrichment
    /// writes several times a second, and an answer rebuilt for each would
    /// move under the reader.
    private struct ExploreKnowledgeCache {
        var since: Date?
        var walked: [MusicNode: LocalKnowledgeAdapter.Walked] = [:]
        var shows: [ShowProfile]?
        var tagKeys: Set<String>?
        var tags: [String: [String]] = [:]
        var scenes: SceneCatalogue?
        var library: [String: Int]?
    }
    private var exploreCache = ExploreKnowledgeCache()
    /// Moves whenever a part of the kept knowledge is worked out again, so a
    /// look whose knowledge is all kept reuses its digest instead of encoding
    /// a megabyte to arrive at the same string.
    private var knowledgeVersion = 0
    private var lastKnowledgeDigests: (key: KnowledgeDigestKey, shared: (digest: String, bytes: Int), local: (digest: String, bytes: Int))?
    private struct KnowledgeDigestKey: Equatable {
        let version: Int
        let origins: [MusicNode]
        let scenes: Bool
    }
    private var lastPersonal: (inputs: PersonalInputs, digest: String, bytes: Int)?
    static let knowledgeLifetime: TimeInterval = 15 * 60

    /// The listener's rows and the knowledge around them, digested.
    ///
    /// `now` decides only whether kept knowledge has expired; the answer is
    /// worked out for `asOf`. `scenes` asks for the slow half as well.
    /// `rebuild` throws everything kept away first, for a correction that
    /// landed in the store (see `DigStore.invalidateExploreOffers`).
    /// `personal` is the rows a first half already read, so the second half
    /// of one look is about the same rows.
    func exploreRun(
        asOf: Date, period: Int, generation asked: Int, scenes withScenes: Bool, rebuild: Bool, now: Date,
        personal known: PersonalInputs? = nil
    ) -> ExploreRun {
        refresh(asked)
        var report = ExploreBuildReport()
        func timed<T>(_ part: String, _ work: () -> T) -> T {
            let started = ContinuousClock.now
            let value = Trace.step("explore.build", part) { work() }
            let spent = ContinuousClock.now - started
            report.milliseconds[part, default: 0] += Double(spent.components.attoseconds) / 1e15
                + Double(spent.components.seconds) * 1_000
            return value
        }

        let personal = known ?? timed("personal") { PersonalInputs.read(context: modelContext, asOf: asOf) }
        if rebuild || exploreCache.since.map({ now.timeIntervalSince($0) > Self.knowledgeLifetime }) ?? true {
            exploreCache = ExploreKnowledgeCache(since: now)
            knowledgeVersion &+= 1
        }
        let adapter = LocalKnowledgeAdapter(
            context: modelContext, graph: graph ?? GraphStore(context: modelContext), scenes: sceneEngine(asked)
        )

        let origins = ExploreRanker.startingPoints(personal)
        var walked: [MusicNode: LocalKnowledgeAdapter.Walked] = [:]
        var fresh = 0
        for origin in origins {
            if let kept = exploreCache.walked[origin] {
                walked[origin] = kept
            } else {
                let found = timed("neighbourhoods") { adapter.neighbourhood(of: origin) }
                exploreCache.walked[origin] = found
                walked[origin] = found
                fresh += 1
            }
        }
        if fresh > 0 {
            report.rebuilt.append("neighbourhoods \(fresh)/\(origins.count)")
            knowledgeVersion &+= 1
        }
        if exploreCache.shows == nil {
            exploreCache.shows = timed("shows") { adapter.shows() }
            report.rebuilt.append("shows")
            knowledgeVersion &+= 1
        }
        let keys = personal.tasteArtistKeys
        if exploreCache.tagKeys != keys {
            exploreCache.tags = timed("artistTags") { LocalKnowledgeAdapter.artistTags(for: keys, in: modelContext) }
            exploreCache.tagKeys = keys
            report.rebuilt.append("artistTags")
            knowledgeVersion &+= 1
        }
        if exploreCache.library == nil {
            exploreCache.library = timed("library") { adapter.libraryCounts() }
            report.rebuilt.append("library")
            knowledgeVersion &+= 1
        }
        if withScenes, exploreCache.scenes == nil {
            exploreCache.scenes = timed("scenes") { adapter.sceneCatalogue() }
            report.rebuilt.append("scenes")
            knowledgeVersion &+= 1
        }

        let knowledge = timed("assemble") {
            LocalKnowledgeAdapter.assemble(
                origins: origins, walked: walked, shows: exploreCache.shows ?? [],
                artistTags: exploreCache.tags, scenes: withScenes ? exploreCache.scenes : nil,
                libraryCounts: exploreCache.library ?? [:]
            )
        }
        // The rows' digest is kept with the rows: the second half of a look
        // asks again with the same ones.
        let personalDigest: (digest: String, bytes: Int)
        if let last = lastPersonal, last.inputs == personal {
            personalDigest = (last.digest, last.bytes)
        } else {
            personalDigest = timed("digest") { CanonicalDigest.digestAndSize(of: personal) }
            lastPersonal = (personal, personalDigest.digest, personalDigest.bytes)
        }
        let digestKey = KnowledgeDigestKey(version: knowledgeVersion, origins: origins, scenes: withScenes)
        let shared: (digest: String, bytes: Int)
        let local: (digest: String, bytes: Int)
        if let last = lastKnowledgeDigests, last.key == digestKey {
            (shared, local) = (last.shared, last.local)
        } else {
            shared = timed("digest") { CanonicalDigest.digestAndSize(of: knowledge.shared) }
            local = timed("digest") { CanonicalDigest.digestAndSize(of: knowledge.deviceLocal) }
            lastKnowledgeDigests = (digestKey, shared, local)
        }
        report.bytes = ["personal": personalDigest.bytes, "shared": shared.bytes, "deviceLocal": local.bytes]
        report.counts = [
            "startingPoints": origins.count,
            "edges": knowledge.shared.neighbourhoods.reduce(0) { $0 + $1.edges.count },
            "deviceLocalEdges": knowledge.deviceLocal.neighbourhoods.reduce(0) { $0 + $1.edges.count },
            "nodes": knowledge.shared.nodes.count,
            "shows": knowledge.shared.shows.count,
            "sceneCities": knowledge.shared.scenes?.cities.count ?? 0,
        ]
        return ExploreRun(
            personal: personal, knowledge: knowledge,
            stamp: ExploreStamp(
                format: knowledge.format, period: period, personal: personalDigest.digest,
                shared: shared.digest, deviceLocal: local.digest
            ),
            report: report
        )
    }

    /// The blocks somebody can act on, ranked from a run. Pure; here only to
    /// stay off the thread that draws.
    func exploreRecommendations(_ run: ExploreRun, asOf: Date) -> ExploreOffers {
        Trace.step("explore.rank") {
            ExploreRanker.recommendations(
                personal: run.personal, knowledge: run.knowledge,
                taste: ExploreRanker.taste(personal: run.personal, knowledge: run.knowledge, asOf: asOf)
            )
        }
    }

    /// And where they are heading. `turn` moves along the list of places
    /// somebody could be said to be heading into -- EXPLORE passes its period,
    /// so every device names the same place on the same day.
    func exploreDirection(_ run: ExploreRun, asOf: Date, turn: Int) -> ExploreOffers.SceneOffer? {
        Trace.step("explore.direction") {
            ExploreRanker.direction(
                personal: run.personal, knowledge: run.knowledge,
                taste: ExploreRanker.taste(personal: run.personal, knowledge: run.knowledge, asOf: asOf),
                turn: turn
            )
        }
    }

    /// Every picture the background fill has found, by normalised name.
    ///
    /// Read here rather than on the store's own context. It is the whole
    /// `ArtistPortrait` table, it grows for as long as the app is open, and
    /// the store read it in one statement on the main actor four seconds
    /// after launch — which is the hitch a listener sees once the window has
    /// settled. A dictionary of strings and URLs crosses back, which is the
    /// same bargain every other method here makes.
    /// What a portrait lookup came back with.
    ///
    /// The store decides what to do about each of these, because pacing is
    /// its business: it knows what is on screen, whether a page is being read
    /// and whether a stream is opening. This actor only knows the answer.
    nonisolated enum PortraitOutcome: Sendable {
        case found(URL)
        /// Looked, and there is no picture. Written down, so the same name is
        /// not asked after on every launch.
        case missing
        /// Rate limited. Nothing was written and the name is still owed.
        case refused
        /// A blink of the network, which is not an answer about this artist —
        /// so nothing is written, or a name would be barred for a month over
        /// a dropped connection.
        case unreachable
        case cancelled
    }

    /// One picture: the request, and the row it becomes.
    ///
    /// Here rather than on the store for the reason the rest of this actor is
    /// here. The store is main-actor isolated, so awaiting a Discogs search
    /// from it resumed the decode, the fetch, the insert and the save on the
    /// thread that draws — a hundred and fifty times a session, which is what
    /// the trace file showed as `discogs.request [MAIN]` filling whole
    /// screens. The request itself was never the problem; everything either
    /// side of it was.
    ///
    /// Returns the address for the store to put in its own picture map. That
    /// map is what the rows read, and it stays where the rows are.
    func fillPortrait(named name: String) async -> PortraitOutcome {
        // Whoever the full lookup already decided this artist is.
        //
        // `artistThumbnail(named:)` is one search and takes the first result
        // that matches the name, which is right until two people share one.
        // Where a page has already been opened the answer is sitting in the
        // store — the right Discogs id, and their picture — so asking a
        // search engine to guess again is both a wasted request and the way
        // the video director's photograph got filed under the duo's name.
        // Unless all it holds is the 150-pixel thumb, which is why this
        // name was asked for again: then the search, for the cover.
        if let resolved = Self.resolvedPortrait(named: name, in: modelContext),
           !DiscogsClient.isSmallCut(resolved) {
            return write(resolved, named: name)
        }

        let found: String?
        do {
            found = try await discogs.artistThumbnail(named: name)
        } catch is CancellationError {
            return .cancelled
        } catch DiscogsError.rateLimited {
            return .refused
        } catch {
            return .unreachable
        }
        guard !Task.isCancelled else { return .cancelled }
        return write(found, named: name)
    }

    /// Portraits the shared catalogue had already found, written down here as
    /// though this machine had found them.
    ///
    /// The queue is then shorter by exactly the names the backend has already
    /// paid for, which is the whole point of filling them once for everybody
    /// rather than once per listener. See migration 0019.
    /// Through `write` rather than a bare insert: `nameKey` is unique, and an
    /// artist the fill already recorded a miss for is exactly the case this is
    /// most useful in.
    func adopt(_ found: [(name: String, address: String)]) {
        for entry in found {
            _ = write(entry.address, named: entry.name)
        }
    }

    /// The picture on the artist row, when a full lookup has written one.
    private static func resolvedPortrait(named name: String, in context: ModelContext) -> String? {
        let key = RecordingKey.normalizeArtist(name)
        guard !key.isEmpty else { return nil }
        var descriptor = FetchDescriptor<DiscogsArtist>(predicate: #Predicate { $0.nameKey == key })
        descriptor.fetchLimit = 1
        guard let artist = (try? context.fetch(descriptor))?.first else { return nil }
        return DiscogsClient.usableImage(artist.thumbnailURLString)
            ?? DiscogsClient.usableImage(artist.imageURLString)
    }

    private func write(_ found: String?, named name: String) -> PortraitOutcome {
        let key = RecordingKey.normalizeArtist(name)
        let record = ArtistPortrait(nameKey: key, name: name)
        if let found { record.imageURLString = found } else { record.lookupFailed = true }
        // Replaces any earlier attempt for the same name.
        var descriptor = FetchDescriptor<ArtistPortrait>(predicate: #Predicate { $0.nameKey == key })
        descriptor.fetchLimit = 1
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            modelContext.delete(existing)
        }
        modelContext.insert(record)
        try? modelContext.save()

        guard let found, let address = URL(string: found) else { return .missing }
        return .found(address)
    }

    /// Everything already known about artist pictures.
    ///
    /// Both halves come out of one read of the table. `settled` is the part
    /// the store cannot work out for itself any more: the rows are written on
    /// this actor's context now, so the store's own context never sees them,
    /// and without this it would ask after a name it had already been told
    /// there is no picture for — once per launch, forever.
    nonisolated struct PortraitIndex: Sendable {
        var found: [String: URL] = [:]
        /// Names with an answer worth keeping — a picture, or a miss recent
        /// enough that asking again is asking twice.
        var settled: Set<String> = []
    }

    func portraitIndex() -> PortraitIndex {
        Trace.step("portraits.index") {
            let records = (try? modelContext.fetch(FetchDescriptor<ArtistPortrait>())) ?? []
            return PortraitIndex(
                found: Dictionary(
                    records.compactMap { record in record.imageURL.map { (record.nameKey, $0) } },
                    uniquingKeysWith: { first, _ in first }
                ),
                settled: Set(records.filter { !$0.isWorthRetrying }.map(\.nameKey))
            )
        }
    }

    /// Names still wanting a picture: somebody named as a connection, who has
    /// neither been dug into nor already been looked up.
    ///
    /// Here for the same reason as `portraitIndex()`. It reads the artist
    /// table and the portrait table whole and normalises every credit on
    /// every artist, and the store rebuilt it on the main actor each time the
    /// revision moved — which, during enrichment, is often.
    func pendingPortraits() -> [String] {
        Trace.step("portraits.pending") {
            let artists = (try? modelContext.fetch(FetchDescriptor<DiscogsArtist>())) ?? []
            // `usableImage`, not `isEmpty`. An artist holding a Discogs
            // `spacer.gif` counted as somebody who already had a picture, so
            // 109 of 582 artists in a real store were excluded from this list
            // permanently and could never be looked up. See
            // `DiscogsArtist.imageURL`.
            let dug = Set(
                artists
                    .filter { DiscogsClient.usableImage($0.imageURLString) != nil }
                    .map(\.nameKey)
            )
            let looked = Dictionary(
                ((try? modelContext.fetch(FetchDescriptor<ArtistPortrait>())) ?? [])
                    .map { ($0.nameKey, $0.isWorthRetrying) },
                uniquingKeysWith: { first, _ in first }
            )

            var pending: [String] = []
            var seen = Set<String>()
            for artist in artists {
                let named = artist.labelNeighbourNames + artist.styleNeighbourNames
                    + artist.collaboratorNames + artist.aliasNames
                    + artist.memberNames + artist.groupNames
                for name in named {
                    let key = RecordingKey.normalizeArtist(name)
                    guard !key.isEmpty, !dug.contains(key), seen.insert(key).inserted else { continue }
                    if let worthRetrying = looked[key], !worthRetrying { continue }
                    pending.append(name)
                }
            }
            return pending
        }
    }

    /// Which cached releases list this recording.
    ///
    /// `videoURLStrings` is a plain `[String]` attribute, which the store
    /// keeps as one opaque value — there is nothing inside it for a query to
    /// look at, and a `#Predicate` naming it takes the process down. So this
    /// is a walk of the release table, and a walk belongs here: it used to
    /// happen on the main actor at the exact moment a recording refused to
    /// play, which is the moment a listener is waiting on the transport.
    func releasesListing(_ address: String) -> [Int] {
        Trace.step("releases.listing") {
            ((try? modelContext.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? [])
                .filter { $0.videoURLStrings.contains(address) }
                .map(\.discogsID)
        }
    }

    func artistProfile(name: String, mbid: String?, generation: Int) -> ArtistProfile {
        engine(generation).artistProfile(name: name, mbid: mbid)
    }

    func releaseProfile(id: Int, generation: Int) -> DigReleaseProfile? {
        engine(generation).releaseProfile(id: id)
    }

    func labelProfile(mbid: String, fallbackName: String, generation: Int) -> LabelProfile? {
        engine(generation).labelProfile(mbid: mbid, fallbackName: fallbackName)
    }

    func connections(from node: MusicNode, generation: Int) -> [MusicGraph.Connection] {
        engine(generation).connections(from: node)
    }

    func descent(
        from origin: MusicNode, at level: DeepLevel, generation: Int, showing: Set<String>
    ) -> DeepEngine.Descent {
        deepEngine(generation).descent(from: origin, at: level, showing: showing)
    }

    /// "TRY" on the DIG landing page — where this listener has not been.
    ///
    /// Here rather than on the store's own context because it is a graph walk
    /// out of four nodes, and the landing page was doing it on the thread that
    /// draws. The trace names it plainly: four `g.stored [MAIN]` reads and
    /// then `main.stall`, 448ms and 1683ms of stopped main thread, once per
    /// revision. `Suggestion` is a plain value, so it crosses back like
    /// everything else here.
    func digSuggestions(limit: Int, generation: Int) -> [DigHistory.Suggestion] {
        refresh(generation)
        return DigHistory(context: modelContext, graph: graph).suggestions(limit: limit)
    }

    /// The landing page's recommendations — one graph step out of each of
    /// the listener's own artists. Here for the same reason as the above: it
    /// walks ten neighbourhoods, and that is not work for the drawing thread.
    ///
    /// Kept between revisions. Every enrichment write moves the revision, and
    /// rebuilding for each one cost ~950ms of this actor — ten stored
    /// neighbourhoods at ~80ms apiece — every few seconds, queued in front of
    /// whatever artist page somebody was opening. A seed's neighbourhood only
    /// changes when it is forgotten, so that is what throws this away.
    func crateRecommendations(
        seeds: [CrateSeed], known: Set<String>, generation: Int
    ) -> CrateRecommendations {
        if let kept = keptRecommendations, kept.seeds == seeds, kept.known == known,
           !seeds.contains(where: {
               ForgottenNodes.shared.wasForgotten(MusicNode.artist($0.name).id, since: kept.builtAt)
           }) {
            return kept.result
        }
        refresh(generation)
        guard let graph else { return .empty }
        let builtAt = Date()
        let result = CrateRecommendations.build(seeds: seeds, known: known, graph: graph)
        keptRecommendations = (seeds, known, builtAt, result)
        return result
    }

    private var keptRecommendations: (
        seeds: [CrateSeed], known: Set<String>, builtAt: Date, result: CrateRecommendations
    )?

    func scenes(forArtist name: String, generation: Int) -> [MusicScene] {
        sceneEngine(generation).scenes(forArtist: name)
    }

    func scene(city: String, sound: String?, generation: Int) -> MusicScene? {
        sceneEngine(generation).scene(city: city, sound: sound)
    }
}
