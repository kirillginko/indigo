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
        scenes = SceneEngine(context: modelContext)
        generation = asked
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

    /// Every picture the background fill has found, by normalised name.
    ///
    /// Read here rather than on the store's own context. It is the whole
    /// `ArtistPortrait` table, it grows for as long as the app is open, and
    /// the store read it in one statement on the main actor four seconds
    /// after launch — which is the hitch a listener sees once the window has
    /// settled. A dictionary of strings and URLs crosses back, which is the
    /// same bargain every other method here makes.
    func portraitIndex() -> [String: URL] {
        Trace.step("portraits.index") {
            Dictionary(
                ((try? modelContext.fetch(FetchDescriptor<ArtistPortrait>())) ?? [])
                    .compactMap { record in record.imageURL.map { (record.nameKey, $0) } },
                uniquingKeysWith: { first, _ in first }
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
            let dug = Set(artists.filter { $0.imageURLString?.isEmpty == false }.map(\.nameKey))
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

    func descent(from origin: MusicNode, at level: DeepLevel, generation: Int) -> DeepEngine.Descent {
        deepEngine(generation).descent(from: origin, at: level)
    }

    func undergroundCuts(for node: MusicNode, generation: Int) -> [DeepResult] {
        deepEngine(generation).results(from: node, at: .underground)
    }

    func scenes(forArtist name: String, generation: Int) -> [MusicScene] {
        sceneEngine(generation).scenes(forArtist: name)
    }

    func scene(city: String, generation: Int) -> MusicScene? {
        sceneEngine(generation).scene(city: city)
    }
}
