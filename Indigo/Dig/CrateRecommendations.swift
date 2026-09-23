//
//  CrateRecommendations.swift
//  Indigo
//
//  Music to go and find, worked out from what is already kept.
//
//  The DIG landing page used to be a list of the listener's own artists — a
//  way into things they already had. This is the other half: the people next
//  to those artists that they do not have yet. Everything here is one step
//  out of the graph from somebody in the crate, so each pick still carries
//  the fact it rests on ("Both release on Warp") rather than a similarity
//  score nobody can check.
//
//  Nothing here asks the network. It reads the neighbourhoods the graph has
//  already worked out, which is why it fills in as enrichment lands.
//

import Foundation

/// An artist the listener keeps, as the place a recommendation starts from.
nonisolated struct CrateSeed: Sendable, Hashable {
    let name: String
    let mbid: String?
    let crateCount: Int
    let libraryCount: Int

    /// How much a pick from here should count. Something crated is a choice;
    /// something that merely sits in a music folder is weaker evidence of
    /// taste, and a single crated track less than several.
    var weight: Double {
        crateCount > 0 ? 0.7 + 0.3 * min(1, Double(crateCount) / 4) : 0.5
    }
}

nonisolated struct CrateRecommendations: Sendable, Codable {
    /// One artist or label worth opening, and which of the listener's artists
    /// argue for it.
    nonisolated struct Pick: Identifiable, Sendable, Hashable, Codable {
        let node: MusicNode
        /// The seeds it was reached from, strongest first.
        let because: [String]
        /// The best single fact behind it — "Both release on Warp".
        let reason: String
        let score: Double

        var id: String { node.id }

        /// "Like Aphex Twin · Autechre" — who in the crate this is next to.
        var becauseLine: String {
            let shown = because.prefix(2).joined(separator: " · ")
            let more = because.count - 2
            return more > 0 ? "Like \(shown) +\(more)" : "Like \(shown)"
        }
    }

    /// "More like Aphex Twin" — one seed and what is next to it.
    nonisolated struct Shelf: Identifiable, Sendable, Hashable, Codable {
        let seed: String
        let picks: [Pick]
        var id: String { seed }
    }

    var forYou: [Pick] = []
    var shelves: [Shelf] = []
    var labels: [Pick] = []

    static let empty = CrateRecommendations()

    var isEmpty: Bool { forYou.isEmpty && shelves.isEmpty && labels.isEmpty }

    // MARK: Between launches

    /// The first build of a launch reads six tables cold and walks ten
    /// neighbourhoods behind whatever else the worker has queued — five
    /// seconds in the trace. Last launch's answer is a fine thing to look at
    /// while that happens, and it is replaced in place when it lands.
    private static let savedKey = "dig.crateRecommendations"

    static func saved(in defaults: UserDefaults = .standard) -> CrateRecommendations? {
        guard let data = defaults.data(forKey: savedKey) else { return nil }
        return try? JSONDecoder().decode(CrateRecommendations.self, from: data)
    }

    func save(in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.savedKey)
    }

    /// Edges that say nothing about what to listen to next. An alias is the
    /// same person; "in your crate" and "your library" are about the listener
    /// rather than the music; and sharing a decade is only ever a qualifier.
    private static let ignored: Set<RelationshipKind> = [
        .sameAlias, .aliasOrProject, .inYourCrate, .inYourLibrary, .sharedCollection, .sameEra
    ]

    /// - Parameters:
    ///   - seeds: the listener's artists, most-kept first.
    ///   - known: normalised keys of every artist already in the crate or the
    ///     library. A recommendation of something they have is a mirror.
    static func build(
        seeds: [CrateSeed],
        known: Set<String>,
        graph: GraphStore,
        seedLimit: Int = 10,
        forYouLimit: Int = 12,
        shelfCount: Int = 4,
        shelfLimit: Int = 10,
        labelLimit: Int = 8
    ) -> CrateRecommendations {
        let seeds = Array(seeds.filter { ArtistName.isRealArtist($0.name) }.prefix(seedLimit))
        guard !seeds.isEmpty else { return .empty }

        struct Contribution { let seed: String; let score: Double; let reason: String }
        var artists: [String: (node: MusicNode, from: [Contribution])] = [:]
        var labels: [String: (node: MusicNode, from: [Contribution])] = [:]
        // Every seed's whole family, so AFX is left out even when it is
        // Autechre's neighbourhood that reached it.
        var families: Set<String> = []

        for seed in seeds {
            let node = MusicNode.artist(seed.name, mbid: seed.mbid)
            let neighbours = graph.neighbors(of: node)
            let family = neighbours.aliasKeys.union([node.key])
            families.formUnion(family)

            for connection in neighbours.byDestination
            where connection.node.destination != nil {
                let edges = connection.edges.filter { !ignored.contains($0.kind) }
                guard let best = edges.first else { continue }
                let score = ConfidenceMath.combined(edges.map(\.weight)) * seed.weight
                let contribution = Contribution(seed: seed.name, score: score, reason: best.reason)

                switch connection.node.kind {
                case .artist:
                    let key = connection.node.key
                    guard !family.contains(key), !known.contains(key),
                          ArtistName.isRealArtist(connection.node.title) else { continue }
                    var entry = artists[connection.node.id] ?? (connection.node, [])
                    // Whichever sighting came with a picture.
                    if entry.node.artworkURL == nil, connection.node.artworkURL != nil {
                        entry.node = connection.node
                    }
                    entry.from.append(contribution)
                    artists[connection.node.id] = entry
                case .label:
                    guard LabelName.isRealLabel(connection.node.title) else { continue }
                    var entry = labels[connection.node.id] ?? (connection.node, [])
                    entry.from.append(contribution)
                    labels[connection.node.id] = entry
                default:
                    continue
                }
            }
        }

        func pick(_ node: MusicNode, _ from: [Contribution]) -> Pick {
            // One contribution per seed, the strongest.
            var bySeed: [String: Contribution] = [:]
            for item in from where (bySeed[item.seed]?.score ?? -1) < item.score {
                bySeed[item.seed] = item
            }
            let ordered = bySeed.values.sorted { $0.score > $1.score }
            return Pick(
                node: node,
                because: ordered.map(\.seed),
                reason: ordered.first?.reason ?? "",
                score: ConfidenceMath.combined(ordered.map(\.score))
            )
        }

        func ranked(_ picks: [Pick]) -> [Pick] {
            picks.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.node.title.localizedCaseInsensitiveCompare($1.node.title) == .orderedAscending
            }
        }

        let artistPicks = ranked(
            artists.values
                .filter { !families.contains($0.node.key) }
                .map { pick($0.node, $0.from) }
        )

        // Agreement first: somebody next to three of the listener's artists
        // is a better bet than the strongest neighbour of any one of them.
        let forYou = Array(
            artistPicks
                .sorted {
                    $0.because.count == $1.because.count
                        ? $0.score > $1.score
                        : $0.because.count > $1.because.count
                }
                .prefix(forYouLimit)
        )

        // One shelf per seed, each showing only what no earlier row has, so
        // the page is more music rather than the same faces again.
        var shown = Set(forYou.map(\.id))
        var shelves: [Shelf] = []
        for seed in seeds where shelves.count < shelfCount {
            let own = artistPicks
                .filter { $0.because.contains(seed.name) && !shown.contains($0.id) }
                .map { pick in
                    // Said from this seed's side, not the strongest one's.
                    let reason = artists[pick.id]?.from
                        .filter { $0.seed == seed.name }
                        .max { $0.score < $1.score }?.reason ?? pick.reason
                    return Pick(node: pick.node, because: pick.because, reason: reason, score: pick.score)
                }
                .prefix(shelfLimit)
            guard own.count >= 3 else { continue }
            shelves.append(Shelf(seed: seed.name, picks: Array(own)))
            shown.formUnion(own.map(\.id))
        }

        let labelPicks = labels.values
            .map { pick($0.node, $0.from) }
            .sorted {
                $0.because.count == $1.because.count
                    ? $0.score > $1.score
                    : $0.because.count > $1.because.count
            }

        return CrateRecommendations(
            forYou: forYou,
            shelves: shelves,
            labels: Array(labelPicks.prefix(labelLimit))
        )
    }
}
