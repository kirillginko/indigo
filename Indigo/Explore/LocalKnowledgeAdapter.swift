//
//  LocalKnowledgeAdapter.swift
//  Indigo
//
//  A knowledge snapshot built from what this device has cached.
//
//  The first source of `KnowledgeSnapshot`, and for now the only one. It asks
//  the same code For You always asked -- `GraphStore` for each starting point's
//  neighbourhood, the appearance log for tracklists, the Discogs cache for
//  styles, `SceneEngine` for scenes -- and writes the answers down as plain
//  values instead of handing them straight to the ranking. So nothing about
//  what is discovered changes; what changes is that it can be compared, and
//  later replaced by Indigo's backend part by part.
//
//  Two things are kept out of the shared part. The library's edges and track
//  counts go in the device-local part: they are real knowledge, but only this
//  device has the files. And the crate's own edges ("in your crate") are left
//  out altogether: they are the listener's rows restated, which the ranker
//  already has, and their route is worth nothing, so no suggestion rests on
//  them.
//

import Foundation
import SwiftData

nonisolated struct LocalKnowledgeAdapter {
    let context: ModelContext
    let graph: GraphStore
    let scenes: SceneEngine

    init(context: ModelContext, graph: GraphStore? = nil, scenes: SceneEngine? = nil) {
        self.context = context
        self.graph = graph ?? GraphStore(context: context)
        self.scenes = scenes ?? SceneEngine(context: context)
    }

    /// One starting point's edges, sorted into the part every device shares
    /// and the part only this one has.
    struct Walked: Sendable, Equatable {
        var shared: [MusicEdge]
        var deviceLocal: [MusicEdge]
    }

    func neighbourhood(of origin: MusicNode) -> Walked {
        Self.split(graph.neighbors(of: origin).all)
    }

    /// Edges sorted into the shared part and this device's own.
    static func split(_ edges: [MusicEdge]) -> Walked {
        var walked = Walked(shared: [], deviceLocal: [])
        for edge in edges {
            switch edge.source {
            case .library: walked.deviceLocal.append(edge)
            // The listener's own rows, restated as an edge. See the header.
            case .crate: continue
            default: walked.shared.append(edge)
            }
        }
        return walked
    }

    func shows() -> [ShowProfile] {
        ShowSuggestionEngine(context: context).profiles()
    }

    func sceneCatalogue() -> SceneCatalogue {
        scenes.catalogue()
    }

    /// Tracks per artist, before joint credits are shared out.
    func libraryCounts() -> [String: Int] {
        LibraryAlbums.shared.index(in: context).trackCounts
    }

    /// Styles and genres, folded, for these artists. Only the artists the
    /// crate says something about the taste of are asked for, not the whole
    /// catalogue: that is all the taste profile reads.
    static func artistTags(for keys: Set<String>, in context: ModelContext) -> [String: [String]] {
        guard !keys.isEmpty else { return [:] }
        let wanted = Array(keys)
        let descriptor = FetchDescriptor<DiscogsArtist>(predicate: #Predicate { wanted.contains($0.nameKey) })
        var found: [String: [String]] = [:]
        for artist in (try? context.fetch(descriptor)) ?? [] {
            let tags = ListeningLog.foldTags(artist.styles + artist.genres)
            if !tags.isEmpty { found[artist.nameKey] = tags }
        }
        return found
    }

    /// The whole snapshot for one listener's rows, built now.
    func snapshot(for personal: PersonalInputs, scenes withScenes: Bool) -> KnowledgeSnapshot {
        let origins = ExploreRanker.startingPoints(personal)
        var walked: [MusicNode: Walked] = [:]
        for origin in origins { walked[origin] = neighbourhood(of: origin) }
        return Self.assemble(
            origins: origins, walked: walked, shows: shows(),
            artistTags: Self.artistTags(for: personal.tasteArtistKeys, in: context),
            scenes: withScenes ? sceneCatalogue() : nil,
            libraryCounts: libraryCounts()
        )
    }

    /// Writes the parts down as a snapshot: every node once, in a table of
    /// its own per part, everything in an order of its content.
    static func assemble(
        origins: [MusicNode], walked: [MusicNode: Walked], shows: [ShowProfile],
        artistTags: [String: [String]], scenes: SceneCatalogue?, libraryCounts: [String: Int]
    ) -> KnowledgeSnapshot {
        let sharedTable = NodeTable(origins + origins.flatMap { walked[$0]?.shared.flatMap { [$0.from, $0.to] } ?? [] })
        let localOrigins = origins.filter { !(walked[$0]?.deviceLocal.isEmpty ?? true) }
        let localTable = NodeTable(localOrigins + localOrigins.flatMap { walked[$0]?.deviceLocal.flatMap { [$0.from, $0.to] } ?? [] })

        func neighbourhoods(_ origins: [MusicNode], _ table: NodeTable, _ edges: (Walked) -> [MusicEdge]) -> [Neighbourhood] {
            origins
                .map { origin in
                    Neighbourhood(
                        origin: table.index(origin),
                        edges: (walked[origin].map(edges) ?? [])
                            .sorted(by: MusicEdge.precedes)
                            .map { KnownEdge(
                                from: table.index($0.from), to: table.index($0.to), kind: $0.kind,
                                source: $0.source.rawValue, reason: $0.reason,
                                confidence: $0.confidence, occurrences: $0.occurrences
                            ) }
                    )
                }
                .sorted { $0.origin < $1.origin }
        }

        return KnowledgeSnapshot(
            shared: SharedKnowledge(
                nodes: sharedTable.nodes,
                neighbourhoods: neighbourhoods(origins, sharedTable, \.shared),
                shows: shows.sorted { $0.key < $1.key },
                artistTags: artistTags,
                scenes: scenes
            ),
            deviceLocal: DeviceLocalKnowledge(
                nodes: localTable.nodes,
                neighbourhoods: neighbourhoods(localOrigins, localTable, \.deviceLocal),
                libraryCounts: scenes.map { usable(libraryCounts, by: $0) } ?? [:]
            )
        )
    }

    /// The library's counts for the artists a scene could be reached through:
    /// members of some place, and joint credits with such a member in them.
    /// Nothing else in the library can move For You -- footholds are all it is
    /// read for -- so nothing else is written, and a device whose library
    /// holds nobody from anywhere has the same, empty, device-local part as a
    /// device with no library at all.
    static func usable(_ counts: [String: Int], by catalogue: SceneCatalogue) -> [String: Int] {
        var members = Set<String>()
        for city in catalogue.cities {
            members.formUnion(city.members)
            for scene in city.scenes { members.formUnion(scene.members) }
        }
        let credits = Set(catalogue.creditMembers.filter { !members.isDisjoint(with: $0.value) }.keys)
        return counts.filter { members.contains($0.key) || credits.contains($0.key) }
    }

    /// Every distinct node, sorted by id and then by spelling, and where each
    /// one sits.
    private struct NodeTable {
        let nodes: [MusicNode]
        private let places: [MusicNode: Int]

        init(_ found: [MusicNode]) {
            nodes = Array(Set(found)).sorted {
                $0.id == $1.id ? MusicNode.isPreferred($0, over: $1) : $0.id < $1.id
            }
            places = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })
        }

        func index(_ node: MusicNode) -> Int { places[node] ?? -1 }
    }
}
