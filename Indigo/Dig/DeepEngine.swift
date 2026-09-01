//
//  DeepEngine.swift
//  Indigo
//
//  ↓ DEEPER.
//
//  DEEP is not "more results". It is the same graph with the obvious answers
//  progressively taken away — so pressing DEEPER cannot show you the record
//  you were already looking at from a different angle. Every candidate is
//  assigned the *shallowest* level that would have offered it, and each level
//  shows only what belongs to it. That is what makes the exclusion real
//  rather than a filter that happens to reorder things.
//
//  Levels 1–3 are about how you arrived: through a catalogue, through an
//  imprint, through the radio. Levels 4–5 are about what the thing is: a
//  small pressing, or music nobody has named. That split is deliberate — a
//  white label reached through a radio show is still a white label, and
//  filing it under RADIO because of how it was found would bury the deepest
//  object in the graph at level three.
//

import Foundation
import SwiftData

nonisolated enum DeepLevel: Int, CaseIterable, Hashable, Sendable, Comparable {
    case surface = 1
    case label
    case radio
    case underground
    case unknown

    var title: String {
        switch self {
        case .surface: "SURFACE"
        case .label: "LABEL"
        case .radio: "RADIO"
        case .underground: "UNDERGROUND"
        case .unknown: "UNKNOWN"
        }
    }

    var caption: String {
        switch self {
        case .surface: "Known related artists and releases"
        case .label: "Smaller catalogue connections"
        case .radio: "Played in specialist shows"
        case .underground: "Small pressings, self-releases, obscure aliases"
        case .unknown: "White labels, dubplates, unidentified recordings"
        }
    }

    var deeper: DeepLevel? { DeepLevel(rawValue: rawValue + 1) }
    var shallower: DeepLevel? { DeepLevel(rawValue: rawValue - 1) }

    static func < (lhs: DeepLevel, rhs: DeepLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated struct DeepResult: Identifiable, Sendable {
    let node: MusicNode
    let reasons: [Relationship]
    let level: DeepLevel
    /// Internal ranking input. Never rendered as a number — see
    /// `ObscuritySignals`.
    let signals: ObscuritySignals

    var id: String { node.id }
    var why: WhyThis? { WhyThis(reasons: reasons) }
    var confidence: Double { ConfidenceMath.combined(reasons.map(\.confidence)) }
    var band: RelationshipConfidence { RelationshipConfidence.band(confidence) }
}

nonisolated struct DeepEngine {
    let context: ModelContext

    /// Built once for the life of this engine — see `DigEngine` for why.
    private let shared = CacheBox()

    private final class CacheBox {
        var caches: DeepCaches?
    }

    private var caches: DeepCaches {
        if let existing = shared.caches { return existing }
        let fresh = DeepCaches(context: context)
        shared.caches = fresh
        return fresh
    }

    /// Above this, an object is treated as underground on its own merits even
    /// with no white-label marker on it: a tiny catalogue on a tiny imprint
    /// that the listener has never encountered.
    static let undergroundThreshold = 0.72

    private let sharedGraph = GraphBox()

    private final class GraphBox {
        var store: GraphStore?
    }

    private var graph: GraphStore {
        if let existing = sharedGraph.store { return existing }
        let fresh = GraphStore(context: context)
        sharedGraph.store = fresh
        return fresh
    }

    /// Shares one walked graph with whoever else answers for this page.
    ///
    /// Assembling a `GraphStore`'s caches reads several whole tables. Each
    /// engine built its own, so a page that asks for a profile and a descent
    /// paid for the same tables twice.
    init(context: ModelContext, graph: GraphStore? = nil) {
        self.context = context
        sharedGraph.store = graph
    }

    /// Everything reachable from a node, each filed at the shallowest level
    /// that would have shown it.
    func results(from origin: MusicNode, distance: Int = 1) -> [DeepResult] {
        let caches = self.caches
        return graph.neighbors(of: origin).byDestination.map { candidate in
            let signals = caches.signals(for: candidate.node, distance: distance)
            return DeepResult(
                node: candidate.node,
                reasons: candidate.edges.map(\.relationship),
                level: Self.level(for: candidate.node, edges: candidate.edges, signals: signals),
                signals: signals
            )
        }
    }

    /// One descent, ready to render: what is at this level, and whether there
    /// is anywhere further to go.
    ///
    /// Both answers come from a single walk on purpose. Asking for them
    /// separately means walking the graph twice and rebuilding every cache
    /// with it, which is exactly how opening an artist page got slow.
    func descent(from origin: MusicNode, at level: DeepLevel, distance: Int = 1) -> Descent {
        let all = results(from: origin, distance: distance)
        return Descent(
            level: level,
            results: Self.ordered(all.filter { $0.level == level }),
            next: Self.nextLevel(after: level, in: all)
        )
    }

    nonisolated struct Descent: Sendable {
        let level: DeepLevel
        /// Deepest first — the least reachable thing is at the top.
        let results: [DeepResult]
        /// The next level with anything in it, or nil at the bottom.
        let next: DeepLevel?
    }

    /// What ↓ DEEPER shows next. Ordered deepest-first inside the level, so
    /// the least reachable thing is at the top of the page.
    func results(from origin: MusicNode, at level: DeepLevel, distance: Int = 1) -> [DeepResult] {
        Self.ordered(results(from: origin, distance: distance).filter { $0.level == level })
    }

    /// The next level down that actually has something in it. Pressing DEEPER
    /// onto an empty page is how a discovery tool loses somebody's trust.
    func nextLevel(from origin: MusicNode, after level: DeepLevel, distance: Int = 1) -> DeepLevel? {
        Self.nextLevel(after: level, in: results(from: origin, distance: distance))
    }

    private static func ordered(_ results: [DeepResult]) -> [DeepResult] {
        results.sorted {
            // Confidence breaks ties, because a deep connection nobody can
            // justify is a guess wearing a good disguise.
            $0.signals.score == $1.signals.score
                ? $0.confidence > $1.confidence
                : $0.signals.score > $1.signals.score
        }
    }

    private static func nextLevel(after level: DeepLevel, in results: [DeepResult]) -> DeepLevel? {
        var candidate = level.deeper
        while let next = candidate {
            if results.contains(where: { $0.level == next }) { return next }
            candidate = next.deeper
        }
        return nil
    }

    // MARK: Level assignment

    static func level(
        for node: MusicNode,
        edges: [MusicEdge],
        signals: ObscuritySignals
    ) -> DeepLevel {
        // What the thing is outranks how it was found. A white label reached
        // through a radio show is still a white label.
        if node.isUnidentified { return .unknown }
        if signals.releaseKind.isUnderground || signals.score >= undergroundThreshold {
            return .underground
        }

        let kinds = Set(edges.map(\.kind))
        // The obvious answers: another name for the same person, someone they
        // recorded with, a record they are both on.
        if !kinds.isDisjoint(with: [.sameAlias, .aliasOrProject, .collaborator,
                                    .sameRelease, .appearsOnRelease, .sameArtist]) {
            return .surface
        }
        if kinds.contains(.sharedLabel) { return .label }
        if !kinds.isDisjoint(with: [.sharedBroadcast, .playedInShow,
                                    .playedBySameSelector, .frequentlyPlayedNearby]) {
            return .radio
        }
        return .surface
    }

}

// MARK: - Caches

/// One fetch of each table per descent, and the per-artist tallies worked out
/// once rather than once per candidate.
///
/// The first version of this asked `libraryTrackCount(artist:)` for every
/// candidate, and each of those scanned the whole track table. Twenty
/// candidates on a decent library is twenty full scans — per redraw.
nonisolated struct DeepCaches {
    private let recordingsByID: [UUID: Recording]
    private let artistsByKey: [String: DiscogsArtist]
    private let libraryCounts: [String: Int]
    private let crateCounts: [String: Int]
    private let radioCounts: [String: Int]
    private let labelSizes: [String: Int]
    private let releaseKinds: [String: ReleaseKind]
    private let metadataByRecording: [UUID: RecordingMetadata]
    private let bandcampArtistKeys: Set<String>

    init(context: ModelContext) {
        let recordings = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        recordingsByID = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let artists = (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? []
        artistsByKey = Dictionary(artists.map { ($0.nameKey, $0) }, uniquingKeysWith: { first, _ in first })

        var library: [String: Int] = [:]
        for track in (try? context.fetch(FetchDescriptor<Track>())) ?? [] {
            for key in DigEngine.artistKeys(for: track) { library[key, default: 0] += 1 }
        }
        libraryCounts = library

        var crate: [String: Int] = [:]
        for item in (try? context.fetch(FetchDescriptor<CrateItem>())) ?? [] {
            let name = item.recording?.artistName ?? (item.kind == .artist ? item.displayTitle : nil)
            guard let name, !name.isEmpty else { continue }
            crate[RecordingKey.normalizeArtist(name), default: 0] += 1
        }
        crateCounts = crate

        var radio: [String: Int] = [:]
        for recording in recordings {
            let key = RecordingKey.normalizeArtist(recording.artistName)
            guard !key.isEmpty else { continue }
            radio[key, default: 0] += recording.appearances.count
        }
        radioCounts = radio

        let discogsReleases = (try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? []
        var sizes: [String: Int] = [:]
        var kinds: [String: ReleaseKind] = [:]
        for release in discogsReleases {
            for name in release.labelNames { sizes[RecordingKey.normalize(name), default: 0] += 1 }
            let kind = ReleaseClassifier.classify(
                title: release.title, notes: release.notes,
                catalogNumber: release.catalogNumbers.first,
                artistNames: release.artistNames
            )
            kinds[MusicNode.release(release.title, discogsID: release.discogsID).id] = kind
            for catalog in release.catalogNumbers where !catalog.isEmpty {
                kinds[MusicNode.catalogNumber(catalog).id] = kind
            }
        }
        for label in (try? context.fetch(FetchDescriptor<MusicLabel>())) ?? [] {
            let key = RecordingKey.normalize(label.name)
            sizes[key] = max(sizes[key] ?? 0, label.catalogueSize)
        }
        labelSizes = sizes
        releaseKinds = kinds

        let entries = (try? context.fetch(FetchDescriptor<RecordingMetadata>())) ?? []
        metadataByRecording = Dictionary(entries.map { ($0.recordingID, $0) },
                                         uniquingKeysWith: { first, _ in first })
        bandcampArtistKeys = Set(
            ((try? context.fetch(FetchDescriptor<BandcampRelease>())) ?? []).map(\.artistKey)
        )
    }

    func signals(for node: MusicNode, distance: Int) -> ObscuritySignals {
        var signals = ObscuritySignals()
        signals.distance = distance
        signals.isUnidentified = node.isUnidentified

        switch node.kind {
        case .artist:
            signals.libraryMatches = libraryCounts[node.key] ?? 0
            signals.crateCount = crateCounts[node.key] ?? 0
            signals.radioAppearances = radioCounts[node.key] ?? 0
            let discogs = artistsByKey[node.key]
            signals.knownReleases = discogs?.releaseTitles.count ?? 0
            signals.labelCatalogueSize = (discogs?.labelNames ?? [])
                .compactMap { labelSizes[RecordingKey.normalize($0)] }
                .max() ?? 0
            // An artist is not a pressing, so nothing here should be read as
            // one; the release kind stays neutral.
            signals.releaseKind = .album

        case .release:
            signals.releaseKind = releaseKinds[node.id] ?? .unknown
            signals.knownReleases = 1
            signals.labelCatalogueSize = labelSizes[node.key] ?? 0

        case .label:
            signals.labelCatalogueSize = labelSizes[node.key] ?? 0
            signals.knownReleases = signals.labelCatalogueSize
            signals.releaseKind = .album

        case .recording, .unknownRecording:
            if let identifier = node.recordingID, let recording = recordingsByID[identifier] {
                signals.radioAppearances = recording.appearances.count
                let artistKey = RecordingKey.normalizeArtist(recording.artistName)
                signals.libraryMatches = libraryCounts[artistKey] ?? 0
                // Known to Bandcamp and to no catalogue: a record that exists
                // only where the artist put it.
                signals.isBandcampOnly = bandcampArtistKeys.contains(artistKey)
                    && metadataByRecording[identifier]?.releaseMBID == nil
            }
            signals.releaseKind = node.isUnidentified ? .unknown : .single

        case .catalogNumber:
            signals.releaseKind = releaseKinds[node.id] ?? .unknown

        case .broadcast, .selector, .style, .scene:
            signals.releaseKind = .album
        }
        return signals
    }
}
