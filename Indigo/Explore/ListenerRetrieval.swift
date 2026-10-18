//
//  ListenerRetrieval.swift
//  Indigo
//
//  Listener Profile v2, Phase 3 (prototype): where candidates come from.
//  For You walks one step from twelve recent artists, so most of what the
//  listener goes on to find is never in its pool. Here the pool is drawn
//  from every taste cluster, by three routes:
//
//  - **Direct**: the on-device identity graph, one step from each cluster's
//    strongest units -- credits and releases (direct), labels and scenes
//    (shared context). Never a technical credit, never the same person.
//  - **Radio**: the shared catalogue's tracklists, read-only. Who was played
//    next to a seed (adjacency), and who was played next to *them* (second
//    hop). Weighted by how close the tracks were, how focused the programme
//    is, how often it happened and on how many programmes, and whether the
//    episode's genres fit the cluster; a programme that plays everything and
//    an artist every programme plays count for less.
//  - **Similarity**: records on the device whose styles sit nearest a
//    cluster's centre, only where the record carries enough style to say so.
//
//  Every candidate keeps how it was reached, in words. A second hop is never
//  called a collaboration. Candidates are merged by verified identity --
//  a Discogs id, else a catalogue row -- never by a shared display name.
//
//  The pure parts are functions of their inputs; the reads are batched and
//  counted, and only read episodes aired before the cut-off they are given.
//

import Foundation
import Supabase

nonisolated enum ListenerRetrieval {
    enum Provenance: String, Sendable, CaseIterable, Codable {
        case direct, selection, sharedContext, radioAdjacent, radioSecondHop, musicalSimilarity, forYou

        var label: String {
            switch self {
            case .direct: "direct musical connection"
            case .selection: "chosen by an artist you play"
            case .sharedContext: "same label or scene"
            case .radioAdjacent: "played next to on radio"
            case .radioSecondHop: "second-hop radio"
            case .musicalSimilarity: "musical similarity"
            case .forYou: "For You's walk"
            }
        }
    }

    // MARK: Seeds

    struct Seed: Sendable, Equatable {
        let artist: String
        let name: String
        let cluster: Int
        /// 0...1 within its cluster: the heaviest unit is 1.
        let weight: Double
        let level: ListenerProfile.Level
        let title: String
    }

    /// Each cluster's strongest units, by artist. Slots in proportion to the
    /// time a cluster holds (over time or now, whichever is more), with a
    /// floor, so a small distinctive taste seeds as much as it needs and the
    /// largest cannot take the rest. Units are placed in the cluster they
    /// fit best; recent listening lifts a unit.
    static func seeds(_ profile: ListenerProfile, vectors: [String: [String: Double]], limit: Int = 36, floor: Int = 3) -> [Seed] {
        let clusters = profile.clusters
        guard !clusters.isEmpty else { return [] }
        let total = clusters.reduce(0) { $0 + max($1.longTermShare, $1.recentShare) }
        var quota: [Int: Int] = [:]
        for cluster in clusters {
            quota[cluster.id] = max(floor, Int((Double(limit) * max(cluster.longTermShare, cluster.recentShare) / max(total, 1e-9)).rounded()))
        }
        func strength(_ unit: ListenerProfile.Unit) -> Double { unit.longTerm + 2 * max(0, unit.recent) }
        var byCluster: [Int: [ListenerProfile.Unit]] = [:]
        let scorer = ListenerProfile.Scorer(profile, vectors: vectors)
        for unit in profile.units where unit.longTerm > 0 && !unit.styles.isEmpty {
            guard let fit = scorer.relevance(unit.styles) else { continue }
            byCluster[fit.cluster, default: []].append(unit)
        }
        var chosen = Set<String>()
        var out: [Seed] = []
        for cluster in clusters {
            let units = (byCluster[cluster.id] ?? []).sorted { strength($0) != strength($1) ? strength($0) > strength($1) : $0.id < $1.id }
            let top = units.first.map(strength) ?? 1
            var taken = 0
            for unit in units where taken < quota[cluster.id, default: floor] {
                guard !unit.artist.isEmpty, chosen.insert(unit.artist).inserted else { continue }
                out.append(Seed(artist: unit.artist, name: unit.level == .artist ? unit.title : unit.artist, cluster: cluster.id,
                                weight: strength(unit) / max(top, 1e-9), level: unit.level, title: unit.title))
                taken += 1
            }
        }
        return out
    }

    // MARK: Candidates

    struct Route: Sendable, Equatable {
        let provenance: Provenance
        /// The source's own strength, comparable only within a provenance.
        let score: Double
        /// The seed artist key it was reached from.
        let seed: String
        let cluster: Int
        /// Why, in words.
        let why: String
        /// The one piece of evidence behind it, when it is one (an episode):
        /// finds through the same tracklist are one find.
        var evidence: String? = nil
    }

    struct Candidate: Sendable, Equatable {
        /// "discogs:<id>", else "catalogue:<uuid>", else "name:<key>".
        let identity: String
        let nameKey: String
        let name: String
        var routes: [Route]
        /// Every surface key it arrived under (names, ids).
        var aliases: Set<String>
        var styles: [String] = []
        var styleSource = "none"

        var best: Route { routes.max { $0.score != $1.score ? $0.score < $1.score : $0.why > $1.why }! }
        var provenances: Set<Provenance> { Set(routes.map(\.provenance)) }
    }

    /// One sighting of a candidate, before merging.
    struct Sighting: Sendable {
        let name: String
        let discogsID: Int?
        let catalogueRow: UUID?
        let route: Route
    }

    /// Merged by verified identity: one Discogs id, else one catalogue row.
    /// A sighting with neither joins the identity whose name it shares only
    /// when exactly one identity has that name; two artists with one name
    /// stay two. Deterministic: the result is sorted by identity.
    static func merge(_ sightings: [Sighting]) -> (candidates: [Candidate], surfaceKeys: Int, nameCollisions: Int) {
        var byIdentity: [String: Candidate] = [:]
        var rowToDiscogs: [UUID: Int] = [:]
        for s in sightings { if let row = s.catalogueRow, let id = s.discogsID { rowToDiscogs[row] = min(id, rowToDiscogs[row] ?? id) } }
        var nameless: [Sighting] = []
        var surface = Set<String>()
        for s in sightings {
            let key = RecordingKey.normalizeArtist(s.name)
            surface.insert(s.discogsID.map { "d\($0)" } ?? s.catalogueRow.map { "c\($0)" } ?? "n\(key)")
            let id = s.discogsID ?? s.catalogueRow.flatMap { rowToDiscogs[$0] }
            let identity = id.map { "discogs:\($0)" } ?? s.catalogueRow.map { "catalogue:\($0.uuidString.lowercased())" }
            guard let identity else { nameless.append(s); continue }
            var c = byIdentity[identity] ?? Candidate(identity: identity, nameKey: key, name: s.name, routes: [], aliases: [])
            c.routes.append(s.route)
            c.aliases.insert(key)
            byIdentity[identity] = c
        }
        var byName: [String: [String]] = [:]
        for (identity, c) in byIdentity { for key in c.aliases { byName[key, default: []].append(identity) } }
        var collisions = 0
        for s in nameless {
            let key = RecordingKey.normalizeArtist(s.name)
            let owners = Set(byName[key] ?? [])
            if owners.count > 1 { collisions += 1 }
            let identity = owners.count == 1 ? owners.first! : "name:\(key)"
            var c = byIdentity[identity] ?? Candidate(identity: identity, nameKey: key, name: s.name, routes: [], aliases: [])
            c.routes.append(s.route)
            c.aliases.insert(key)
            byIdentity[identity] = c
        }
        let candidates = byIdentity.keys.sorted().map { key -> Candidate in
            var c = byIdentity[key]!
            c.routes.sort { ($0.provenance.rawValue, -$0.score, $0.seed, $0.why) < ($1.provenance.rawValue, -$1.score, $1.seed, $1.why) }
            return c
        }
        return (candidates, surface.count, collisions)
    }

    // MARK: Ranking

    /// How strongly each candidate was reached, 0...1: its percentile within
    /// each route it came by (best of them), lifted for every further seed
    /// that reached it. Route scores are not comparable across routes;
    /// percentiles are.
    static func evidence(_ pool: [Candidate]) -> [String: Double] {
        var rank: [String: Double] = [:]
        for provenance in Provenance.allCases {
            var scored: [(id: String, score: Double)] = []
            for c in pool { if let best = c.routes.filter({ $0.provenance == provenance }).map(\.score).max() { scored.append((c.identity, best)) } }
            scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
            let count = Double(max(1, scored.count))
            for (i, item) in scored.enumerated() { rank[item.id] = max(rank[item.id] ?? 0, 1 - Double(i) / count) }
        }
        for c in pool {
            let seeds = Set(c.routes.map(\.seed)).count
            rank[c.identity] = min(1, (rank[c.identity] ?? 0) + 0.15 * Double(seeds - 1))
        }
        return rank
    }

    /// Ranked by route evidence first, and by taste only where there is a
    /// style to judge: a styled candidate's evidence is scaled by how well it
    /// fits (0.5 + relevance); an unstyled one is neither rewarded nor
    /// punished -- it takes the pool's median fit. Scoring the unknown as
    /// zero buried every candidate the device holds no styles for.
    static func rank(_ pool: [Candidate], profile: ListenerProfile, vectors: [String: [String: Double]]) -> [Candidate] {
        let ev = evidence(pool)
        var fit: [String: Double] = [:]
        for c in pool { if let r = profile.relevance(styles: c.styles, vectors: vectors) { fit[c.identity] = max(0, r.score) } }
        let known = fit.values.sorted()
        let neutral = known.isEmpty ? 0.5 : known[known.count / 2]
        func score(_ c: Candidate) -> Double { (ev[c.identity] ?? 0) * (0.5 + (fit[c.identity] ?? neutral)) }
        return pool.sorted { score($0) != score($1) ? score($0) > score($1) : $0.identity < $1.identity }
    }

    /// The cluster a candidate belongs to: by its style where it has one,
    /// else the cluster of the seed it was best reached from.
    static func cluster(of c: Candidate, profile: ListenerProfile, vectors: [String: [String: Double]]) -> Int? {
        if let r = profile.relevance(styles: c.styles, vectors: vectors) { return r.cluster }
        return c.best.cluster >= 0 ? c.best.cluster : nil
    }

    // MARK: Styles

    /// What the device knows of artists' sound, keyed by identity.
    struct StyleBook: Sendable {
        /// A Discogs entry's own styles, by its id.
        var byID: [Int: [String]] = [:]
        /// The device's entry for an exact folded name: the identity DIG
        /// gives that name.
        var idOfName: [String: Int] = [:]
        /// Styles of the records credited to an artist by Discogs id.
        var recordsByID: [Int: [String]] = [:]
        /// Styles of records whose documents name the artist without an id.
        var recordsByName: [String: [String]] = [:]

        init() {}

        init(entries: [(key: String, id: Int, styles: [String])], records: [RecordProfile], vectors: [String: [String: Double]]) {
            self.init(entries: entries, recordParts: records.map { (id: $0.id, keys: $0.artistKeys, ids: $0.artistIDs, styles: $0.styles) },
                      vectors: vectors)
        }

        /// From records as plain parts: no need to make similarity profiles
        /// of three thousand records to know whose sound each is.
        init(entries: [(key: String, id: Int, styles: [String])], recordParts records: [(id: Int, keys: Set<String>, ids: Set<Int>, styles: [String])],
             vectors: [String: [String: Double]]) {
            for entry in entries where entry.id > 0 {
                idOfName[entry.key] = entry.id
                let known = ListeningLog.foldTags(entry.styles).filter { vectors[$0] != nil }
                if !known.isEmpty { byID[entry.id] = known }
            }
            for record in records.sorted(by: { $0.id < $1.id }) {
                let known = record.styles.filter { vectors[$0] != nil }
                guard !known.isEmpty else { continue }
                if record.ids.isEmpty {
                    for key in record.keys.sorted() { recordsByName[key, default: []] += known }
                } else {
                    for id in record.ids.sorted() { recordsByID[id, default: []] += known }
                }
            }
            func unique(_ list: [String]) -> [String] { var seen = Set<String>(); return list.filter { seen.insert($0).inserted } }
            recordsByID = recordsByID.mapValues { Array(unique($0).prefix(6)) }
            recordsByName = recordsByName.mapValues { Array(unique($0).prefix(6)) }
        }
    }

    /// A candidate's styles, only through its identity: a Discogs id reads
    /// that entry and the records credited to that id, never anything filed
    /// under a name it shares. A candidate known by name alone (a credit on
    /// an entry or a record) reads the device's entry for that exact name,
    /// as DIG would open it. A catalogue row with no Discogs id gets none:
    /// its name could be anyone's.
    static func style(_ c: inout Candidate, book: StyleBook) {
        let id: Int?
        if c.identity.hasPrefix("discogs:") { id = Int(c.identity.dropFirst("discogs:".count)) }
        else if c.identity.hasPrefix("name:") { id = book.idOfName[c.nameKey] }
        else { id = nil }
        if let id {
            if let own = book.byID[id], !own.isEmpty { c.styles = own; c.styleSource = "entry"; return }
            if let records = book.recordsByID[id], !records.isEmpty { c.styles = records; c.styleSource = "records"; return }
            return
        }
        if c.identity.hasPrefix("name:"), let records = book.recordsByName[c.nameKey], !records.isEmpty {
            c.styles = records; c.styleSource = "records by name"
        }
    }

    // MARK: Direct (on device)

    /// One step out of each seed in the identity graph: credits and releases
    /// are direct, labels and scenes shared context. Radio edges are left to
    /// the radio route, the same person is left out, and so is a credit that
    /// does not lead to somebody who makes music.
    static func direct(_ seeds: [Seed], graph: IdentityGraph) -> [Sighting] {
        var out: [Sighting] = []
        for seed in seeds {
            let hood = graph.neighbourhood(of: .artist(seed.name))
            for edge in hood.edges.all where edge.to.kind == .artist {
                guard ContributorRole.canRecommend(edge) else { continue }
                let provenance: Provenance
                switch edge.kind {
                case .collaborator, .producer, .personnel, .appearsOnRelease, .sameRelease: provenance = .direct
                case .sharedLabel, .sameScene, .sameCity, .sharedCollection: provenance = .sharedContext
                default: continue
                }
                let worth = ExploreSuggestionEngine.worth(edge)
                guard worth > 0 else { continue }
                out.append(Sighting(name: edge.to.title, discogsID: edge.to.discogsID, catalogueRow: nil,
                                    route: Route(provenance: provenance, score: worth * (0.5 + 0.5 * seed.weight), seed: seed.artist,
                                                 cluster: seed.cluster,
                                                 why: provenance == .direct ? "Credited with \(seed.name)" : "Shares a label or scene with \(seed.name)")))
            }
        }
        return out
    }

    /// What a Discogs artist entry on the device lists, as of when it was
    /// fetched: the direct route read from entries known to predate a
    /// moment, rather than from the identity graph, which is today's.
    struct Entry: Sendable, Equatable {
        let key: String
        let name: String
        var collaborators: [String] = []
        var members: [String] = []
        var groups: [String] = []
        var labelNeighbours: [String] = []
        var styleNeighbours: [String] = []
        var aliases: [String] = []
    }

    /// Somebody a seed's own release names, with their Discogs entry.
    struct Credit: Sendable, Equatable, Codable {
        let id: Int
        let name: String
        /// Every spelling this release used for them, folded.
        let keys: Set<String>
        let role: String
        let release: String
        /// On a record the seed chose rather than made -- a DJ mix, a
        /// compilation they put together: a selection, not a collaboration.
        var selection = false
    }

    /// A record of other people's music the seed chose: its formats say
    /// compilation or mixed, it is filed under Various, or the seed's own
    /// credit on it is the DJ mix, the compiling or the selecting.
    static func isSelection(_ release: DiscogsReleaseDetail, seedID: Int?) -> Bool {
        let descriptions = (release.formats ?? []).flatMap { $0.descriptions ?? [] }.map { $0.lowercased() }
        if descriptions.contains(where: { $0 == "compilation" || $0 == "mixed" }) { return true }
        if (release.artists ?? []).contains(where: { ($0.name ?? "").lowercased().hasPrefix("various") }) { return true }
        // Read without a seed (once per document), the one who chose is the
        // record's own artist.
        let chose = ["dj mix", "compiled by", "selected by", "curated by"]
        let own = seedID.map { [$0] } ?? Set((release.artists ?? []).compactMap(\.id))
        return (release.extraartists ?? []).contains { credit in
            credit.id.map(own.contains) == true && chose.contains { (credit.role ?? "").lowercased().contains($0) }
        }
    }

    /// Everyone the seed's own release documents credit with an entry --
    /// co-headliners, track artists and the musical and creative credits --
    /// never the seed itself and never a technical credit. These are the
    /// ids a credit by name on the seed's entry can be resolved to.
    static func credits(seedID: Int?, releases: [DiscogsReleaseDetail]) -> [Credit] {
        var out: [Credit] = []
        var selection = false
        func add(_ id: Int?, _ name: String?, _ anv: String?, role: String, release: String) {
            guard let id, id > 0, id != seedID, let name = name.map(DiscogsClient.withoutDisambiguator), ArtistName.isRealArtist(name) else { return }
            let keys = Set([name, anv].compactMap { $0 }.map { RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator($0)) }.filter { !$0.isEmpty })
            out.append(Credit(id: id, name: name, keys: keys, role: role, release: release, selection: selection))
        }
        for release in releases.sorted(by: { $0.id < $1.id }) {
            selection = isSelection(release, seedID: seedID)
            for artist in release.artists ?? [] { add(artist.id, artist.name, artist.anv, role: "Artist", release: release.title) }
            for credit in release.extraartists ?? [] where ContributorRole.of(credit: credit.role)?.leadsToSomebody == true {
                add(credit.id, credit.name, credit.anv, role: credit.role ?? "", release: release.title)
            }
            for track in release.tracklist ?? [] {
                for artist in track.artists ?? [] { add(artist.id, artist.name, artist.anv, role: "Artist", release: release.title) }
                for credit in track.extraartists ?? [] where ContributorRole.of(credit: credit.role)?.leadsToSomebody == true {
                    add(credit.id, credit.name, credit.anv, role: credit.role ?? "", release: release.title)
                }
            }
        }
        return out
    }

    /// One step from each seed through its own entry and its records'
    /// credits: credits, members and groups are direct; labels shared
    /// context; Discogs' own same-style neighbours similarity. Never the
    /// seed's own other names.
    ///
    /// `credits` -- what the seed's own release documents say, by entry --
    /// are offered with their ids, and a name on the seed's entry takes an id
    /// only when exactly one entry its releases credit goes by that name.
    /// Nothing is matched by name beyond the seed's own records.
    static func direct(_ seeds: [Seed], entries: [String: Entry], records: [RecordProfile],
                       credits: [String: [Credit]] = [:]) -> [Sighting] {
        func key(_ name: String) -> String { RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(name)) }
        var bySeed: [String: [RecordProfile]] = [:]
        for record in records { for artist in record.artistKeys { bySeed[artist, default: []].append(record) } }
        var out: [Sighting] = []
        for found in seeds {
            let entry = entries[found.artist]
            // Said as the entry spells it: a seed read from a recording
            // carries only its folded key.
            let seed = Seed(artist: found.artist, name: entry?.name ?? found.name, cluster: found.cluster, weight: found.weight,
                            level: found.level, title: found.title)
            let own = Set([seed.artist] + (entry?.aliases ?? []).map(key))
            let lift = 0.5 + 0.5 * seed.weight
            let credited = credits[seed.artist] ?? []
            var idsByName: [String: Set<Int>] = [:]
            for credit in credited { for k in credit.keys { idsByName[k, default: []].insert(credit.id) } }
            func resolved(_ name: String) -> Int? {
                guard let ids = idsByName[key(name)], ids.count == 1 else { return nil }
                return ids.first
            }
            func add(_ names: [String], _ provenance: Provenance, _ worth: Double, _ why: String, resolve: Bool = true) {
                for name in names {
                    let clean = DiscogsClient.withoutDisambiguator(name)
                    guard !own.contains(key(clean)), !clean.isEmpty else { continue }
                    out.append(Sighting(name: clean, discogsID: resolve ? resolved(clean) : nil, catalogueRow: nil,
                                        route: Route(provenance: provenance, score: worth * lift, seed: seed.artist, cluster: seed.cluster, why: why)))
                }
            }
            var offered = Set<Int>()
            // Made with them first: someone both on a record they made and on
            // one they chose is a collaborator.
            let ordered = credited.filter { !$0.selection } + credited.filter(\.selection)
            for credit in ordered where !own.contains(where: credit.keys.contains) && offered.insert(credit.id).inserted {
                out.append(Sighting(name: credit.name, discogsID: credit.id, catalogueRow: nil,
                                    route: credit.selection
                                        ? Route(provenance: .selection, score: 0.5 * lift, seed: seed.artist, cluster: seed.cluster,
                                                why: "Chosen by \(seed.name) for \(credit.release)")
                                        : Route(provenance: .direct, score: 0.9 * lift, seed: seed.artist, cluster: seed.cluster,
                                                why: "On \(credit.release) with \(seed.name)")))
            }
            if let entry {
                add(entry.collaborators, .direct, 1, "Credited with \(seed.name)")
                add(entry.members, .direct, 1, "A member of \(seed.name)")
                add(entry.groups, .direct, 0.9, "\(seed.name) plays in it")
                add(entry.labelNeighbours, .sharedContext, 0.6, "Shares a label with \(seed.name)", resolve: false)
                add(entry.styleNeighbours, .musicalSimilarity, 0.5, "The same styles as \(seed.name), as Discogs files them", resolve: false)
            }
            for record in (bySeed[seed.artist] ?? []).sorted(by: { $0.id < $1.id }) {
                let names = record.personnel.sorted().compactMap { record.personnelNames[$0] }
                add(names, .direct, 0.9, "On \(record.title) with \(seed.name)")
            }
        }
        return out
    }

    // MARK: Similarity (on device)

    /// Records whose own styles sit nearest each cluster's centre: at least
    /// two styles the space knows, a fit of at least `minimumFit`, one per
    /// artist, the artist's slot in proportion to the cluster's.
    static func similar(_ profile: ListenerProfile, pool: [RecordProfile], vectors: [String: [String: Double]],
                        known: Set<String>, seeds: [Seed], minimumFit: Double = 0.6, perSeedSlot: Int = 2) -> [Sighting] {
        let slots = Dictionary(grouping: seeds, by: \.cluster).mapValues { $0.count * perSeedSlot }
        var placed: [(cluster: Int, record: RecordProfile, fit: Double)] = []
        for record in pool {
            let styles = record.styles.filter { vectors[$0] != nil }
            guard styles.count >= 2, record.artistKeys.count == 1, let artist = record.artistKeys.first,
                  !artist.isEmpty, !known.contains(artist), !artist.hasPrefix("various") else { continue }
            let v = ListenerProfile.vector(styles, vectors)
            var best: (Int, Double)?
            for cluster in profile.clusters {
                let fit = MusicalCompass.dot(cluster.centroid, v)
                if best.map({ fit > $0.1 }) ?? true { best = (cluster.id, fit) }
            }
            if let best, best.1 >= minimumFit { placed.append((best.0, record, best.1)) }
        }
        var out: [Sighting] = []
        for cluster in profile.clusters {
            let ranked = placed.filter { $0.cluster == cluster.id }
                .sorted { $0.fit != $1.fit ? $0.fit > $1.fit : $0.record.id < $1.record.id }
            var artists = Set<String>()
            for item in ranked where artists.count < slots[cluster.id, default: 0] {
                guard let artist = item.record.artistKeys.first, artists.insert(artist).inserted else { continue }
                let near = item.record.styles.filter { vectors[$0] != nil }.prefix(2).joined(separator: ", ")
                out.append(Sighting(name: item.record.artists.first ?? artist, discogsID: item.record.artistIDs.count == 1 ? item.record.artistIDs.first : nil, catalogueRow: nil,
                                    route: Route(provenance: .musicalSimilarity, score: item.fit, seed: "cluster:\(cluster.id)",
                                                 cluster: cluster.id,
                                                 why: "\(item.record.title) sounds like your \(cluster.label.prefix(2).joined(separator: " / ")) (\(near))")))
            }
        }
        return out
    }

    // MARK: Radio

    /// What the shared catalogue says, as far as it was read.
    struct Radio: Sendable {
        struct Episode: Sendable, Equatable { let id: UUID; let show: UUID?; let showTitle: String?; let aired: Date; let genres: [String] }
        struct Slot: Sendable, Equatable { let index: Int; let artist: UUID }
        var episodes: [UUID: Episode] = [:]
        /// Each artist's episodes (aired before the cut-off) and where in them.
        var appearances: [UUID: [(episode: UUID, index: Int)]] = [:]
        var tracklists: [UUID: [Slot]] = [:]
        /// Genre mentions over each programme's episodes.
        var showGenres: [UUID: [String: Int]] = [:]
        /// How many programmes play each artist, catalogue-wide.
        var showsPlaying: [UUID: Int] = [:]
        var names: [UUID: (name: String, discogs: Int?)] = [:]
    }

    /// How focused a programme is: the share of its genre mentions taken by
    /// its three commonest genres. A programme that plays everything scores
    /// low; one without genres sits in the middle.
    static func specificity(_ counts: [String: Int]?) -> Double {
        guard let counts, !counts.isEmpty else { return 0.5 }
        let total = counts.values.reduce(0, +)
        let top = counts.values.sorted(by: >).prefix(3).reduce(0, +)
        return Double(top) / Double(max(total, 1))
    }

    /// Artists every programme plays say little about any one of them.
    static func hubDamping(_ shows: Int?) -> Double {
        guard let shows, shows > 8 else { return 1 }
        return sqrt(8 / Double(shows))
    }

    /// Radio leads up as easily as across: next to a seed a few programmes
    /// play sits a star every programme plays. A step to something far more
    /// played than what led there says little about the listener and much
    /// about the charts, so it is damped by how much more -- the square
    /// root of the ratio, past a margin of five programmes. Unknown counts
    /// change nothing.
    static func popularityStep(from source: Int?, to candidate: Int?) -> Double {
        guard let source, let candidate, candidate > source else { return 1 }
        return min(1, sqrt(Double(source + 5) / Double(candidate + 5)))
    }

    static func proximity(_ distance: Int) -> Double {
        switch distance { case 1: 1; case 2: 0.6; case 3: 0.4; default: 0.15 }
    }

    struct RadioScore: Sendable, Equatable {
        var score: Double
        var episodes: Int
        var shows: Int
        /// The single strongest piece of evidence: through whom, and on
        /// which episode.
        var via: UUID
        var episode: UUID
        var showTitle: String?
        var distance: Int
        var cluster: Int
        var seed: String
        /// Genres of the episodes it was heard in, by weight.
        var genres: [String: Double]
    }

    /// One hop: from each source, the artists on the same episodes, scored
    /// as the type says. `sources` are catalogue rows with a weight, the seed
    /// they stand for, and its cluster.
    ///
    /// With `perEpisode`, an episode is the unit of evidence -- one
    /// tracklist, one find: each episode offers only its `perEpisode`
    /// strongest artists, an episode with several seeds on it counts for
    /// more, and an artist's score is its best episode, raised only by
    /// *other programmes* playing it, never by more of the same tracklist.
    /// Without it, every adjacency adds up (the first prototype).
    static func hop(from sources: [(row: UUID, weight: Double, seed: String, cluster: Int)], radio: Radio,
                    centroids: [Int: [String: Double]], vectors: [String: [String: Double]], exclude: Set<UUID>,
                    episodesPerSource: Int = 12, perEpisode: Int? = nil) -> [UUID: RadioScore] {
        struct Best { var contribution: Double; var via: UUID; var distance: Int; var cluster: Int; var seed: String }
        var byEpisode: [UUID: [UUID: Best]] = [:]   // episode → candidate → best
        var seedsOn: [UUID: Set<String>] = [:]
        let ordered = sources.sorted { ($0.row.uuidString, $0.seed) < ($1.row.uuidString, $1.seed) }
        for source in ordered {
            let seen = (radio.appearances[source.row] ?? [])
                .compactMap { a in radio.episodes[a.episode].map { (a, $0) } }
                .sorted { $0.1.aired != $1.1.aired ? $0.1.aired > $1.1.aired
                    : ($0.1.id.uuidString, $0.0.index) < ($1.1.id.uuidString, $1.0.index) }
            var used = Set<UUID>()
            for (appearance, episode) in seen {
                guard used.count < episodesPerSource || used.contains(episode.id) else { break }
                used.insert(episode.id)
                seedsOn[episode.id, default: []].insert(source.seed)
                let specific = specificity(episode.show.flatMap { radio.showGenres[$0] })
                let sourceShows = radio.showsPlaying[source.row]
                let genres = ListeningLog.foldTags(episode.genres).filter { vectors[$0] != nil }
                let compat = genres.isEmpty ? 0.5
                    : max(0, MusicalCompass.dot(centroids[source.cluster] ?? [:], ListenerProfile.vector(genres, vectors)))
                for slot in radio.tracklists[episode.id] ?? [] where slot.artist != source.row && !exclude.contains(slot.artist) {
                    let distance = abs(slot.index - appearance.index)
                    guard distance > 0 else { continue }
                    let c = source.weight * proximity(distance) * (0.25 + 0.75 * specific) * (0.5 + 0.5 * compat)
                        * popularityStep(from: sourceShows, to: radio.showsPlaying[slot.artist])
                    if let held = byEpisode[episode.id]?[slot.artist], held.contribution >= c { continue }
                    byEpisode[episode.id, default: [:]][slot.artist] = Best(contribution: c, via: source.row, distance: distance,
                                                                             cluster: source.cluster, seed: source.seed)
                }
            }
        }
        // Candidate → episode → best, an episode offering only its strongest.
        var perCandidate: [UUID: [UUID: Best]] = [:]
        for episode in byEpisode.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let offered = byEpisode[episode] ?? [:]
            var kept = offered.sorted { $0.value.contribution != $1.value.contribution ? $0.value.contribution > $1.value.contribution
                : $0.key.uuidString < $1.key.uuidString }
            if let perEpisode { kept = Array(kept.prefix(perEpisode)) }
            let corroborated = perEpisode == nil ? 1 : min(2, 1 + 0.5 * Double(max(0, (seedsOn[episode]?.count ?? 1) - 1)))
            for (artist, best) in kept {
                var raised = best
                raised.contribution *= corroborated
                perCandidate[artist, default: [:]][episode] = raised
            }
        }
        var out: [UUID: RadioScore] = [:]
        for (artist, episodes) in perCandidate {
            // Summed in one order, so the same rows give the same bits.
            let order = episodes.keys.sorted { $0.uuidString < $1.uuidString }
            let total = order.reduce(0) { $0 + (episodes[$1]?.contribution ?? 0) }
            let shows = Set(episodes.keys.compactMap { radio.episodes[$0]?.show }).count
            let best = episodes.max { a, b in
                a.value.contribution != b.value.contribution ? a.value.contribution < b.value.contribution : a.key.uuidString > b.key.uuidString
            }!
            var genres: [String: Double] = [:]
            for id in order {
                guard let held = episodes[id] else { continue }
                let folded = ListeningLog.foldTags(radio.episodes[id]?.genres ?? []).filter { vectors[$0] != nil }
                for g in folded { genres[g, default: 0] += held.contribution / Double(folded.count) }
            }
            let repeated = min(2, 1 + 0.25 * Double(max(0, shows - 1)))
            let evidence = perEpisode == nil ? log2(1 + total) : best.value.contribution
            out[artist] = RadioScore(score: evidence * repeated * hubDamping(radio.showsPlaying[artist]),
                                     episodes: episodes.count, shows: shows, via: best.value.via, episode: best.key,
                                     showTitle: radio.episodes[best.key]?.showTitle, distance: best.value.distance,
                                     cluster: best.value.cluster, seed: best.value.seed, genres: genres)
        }
        return out
    }

    /// The shared catalogue, read-only, one request per call.
    struct RadioSource: Sendable {
        /// Discogs artist ids → catalogue rows.
        var rows: @Sendable ([Int]) async throws -> [Int: [UUID]]
        /// Normalised names → the one row with that name (none when several).
        var rowsByName: @Sendable ([String]) async throws -> [String: UUID]
        /// An artist's appearances on episodes aired before the date.
        var appearances: @Sendable (UUID, Date) async throws -> [(episode: Radio.Episode, index: Int)]
        var tracklists: @Sendable ([UUID]) async throws -> [UUID: [Radio.Slot]]
        var showGenres: @Sendable ([UUID]) async throws -> [UUID: [String: Int]]
        var showsPlaying: @Sendable ([UUID]) async throws -> [UUID: Int]
        var names: @Sendable ([UUID]) async throws -> [UUID: (name: String, discogs: Int?)]
    }

    struct RadioReport: Sendable {
        var seedsOnRadio = 0, bridges = 0, episodes = 0, requests = 0, failures = 0
        var milliseconds = 0.0
    }

    /// How many programmes play each row, ten rows a request, each row asked
    /// once. A row the answer leaves out is played by none: 0. A request that
    /// fails says nothing, so its rows stay unknown (nil, which damps nothing)
    /// and are asked again the next time they are wanted, rather than being
    /// remembered as played by none.
    static func readDegrees(_ rows: [UUID], into radio: inout Radio, report: inout RadioReport,
                            fetch: @Sendable ([UUID]) async throws -> [UUID: Int]) async {
        let missing = Set(rows.filter { radio.showsPlaying[$0] == nil }).sorted { $0.uuidString < $1.uuidString }
        for chunk in stride(from: 0, to: missing.count, by: 10).map({ Array(missing.dropFirst($0).prefix(10)) }) {
            report.requests += 1
            guard let found = try? await fetch(chunk) else { report.failures += 1; continue }
            for id in chunk { radio.showsPlaying[id] = found[id] ?? 0 }
        }
    }

    /// Both hops for a set of seeds, reading only what each needs. `known`
    /// rows are never candidates (the listener's own artists, by row); the
    /// second hop starts from the strongest first-hop artists that are not
    /// themselves hubs.
    static func radio(seeds: [Seed], discogsIDs: [String: Int], profile: ListenerProfile, vectors: [String: [String: Double]],
                      knownKeys: Set<String>, before cutoff: Date, source: RadioSource, bridges bridgeLimit: Int = 30,
                      perEpisode: Int? = nil)
        async -> (first: [UUID: RadioScore], second: [UUID: RadioScore], radio: Radio, rows: [String: UUID], report: RadioReport) {
        let started = ContinuousClock.now
        var report = RadioReport()
        var radio = Radio()
        func call<T>(_ body: () async throws -> T, _ fallback: T) async -> T {
            report.requests += 1
            do { return try await body() } catch { report.failures += 1; return fallback }
        }
        // Seeds to rows: by Discogs id, else a name only one row has.
        var rowOf: [String: UUID] = [:]
        let ids = seeds.compactMap { discogsIDs[$0.artist] }
        for chunk in stride(from: 0, to: ids.count, by: 40).map({ Array(ids.dropFirst($0).prefix(40)) }) {
            let found = await call({ try await source.rows(chunk) }, [:])
            for seed in seeds { if let id = discogsIDs[seed.artist], let row = found[id]?.sorted(by: { $0.uuidString < $1.uuidString }).first { rowOf[seed.artist] = row } }
        }
        let unnamed = seeds.filter { rowOf[$0.artist] == nil }.map(\.artist)
        for chunk in stride(from: 0, to: unnamed.count, by: 40).map({ Array(unnamed.dropFirst($0).prefix(40)) }) {
            let found = await call({ try await source.rowsByName(chunk) }, [:])
            for (key, row) in found where rowOf[key] == nil { rowOf[key] = row }
        }

        func readAppearances(_ rows: [UUID]) async {
            let wanted = rows.filter { radio.appearances[$0] == nil }
            await withTaskGroup(of: (UUID, [(episode: Radio.Episode, index: Int)]?).self) { group in
                var pending = wanted.makeIterator()
                func next() -> Bool {
                    guard let row = pending.next() else { return false }
                    group.addTask { (row, try? await source.appearances(row, cutoff)) }
                    return true
                }
                for _ in 0..<6 where next() {}
                while let (row, found) = await group.next() {
                    report.requests += 1
                    if found == nil { report.failures += 1 }
                    radio.appearances[row] = (found ?? []).map { (episode: $0.episode.id, index: $0.index) }
                    for item in found ?? [] { radio.episodes[item.episode.id] = item.episode }
                    _ = next()
                }
            }
        }
        func readEpisodes(for rows: [UUID]) async {
            // The episodes each hop will use: a source's dozen most recent.
            var wanted = Set<UUID>()
            for row in rows {
                let recent = (radio.appearances[row] ?? []).compactMap { radio.episodes[$0.episode] }
                    .sorted { $0.aired != $1.aired ? $0.aired > $1.aired : $0.id.uuidString < $1.id.uuidString }
                var taken = Set<UUID>()
                for episode in recent where taken.count < 12 { taken.insert(episode.id) }
                wanted.formUnion(taken)
            }
            let missing = wanted.filter { radio.tracklists[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
            for chunk in stride(from: 0, to: missing.count, by: 30).map({ Array(missing.dropFirst($0).prefix(30)) }) {
                let found = await call({ try await source.tracklists(chunk) }, [:])
                for id in chunk { radio.tracklists[id] = found[id] ?? [] }
            }
            let shows = Set(wanted.compactMap { radio.episodes[$0]?.show }).filter { radio.showGenres[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
            for chunk in stride(from: 0, to: shows.count, by: 8).map({ Array(shows.dropFirst($0).prefix(8)) }) {
                let found = await call({ try await source.showGenres(chunk) }, [:])
                for id in chunk { radio.showGenres[id] = found[id] ?? [:] }
            }
            report.episodes = radio.tracklists.count
        }
        func readDegrees(_ rows: [UUID]) async {
            await Self.readDegrees(rows, into: &radio, report: &report, fetch: source.showsPlaying)
        }

        let seedRows = seeds.compactMap { seed in rowOf[seed.artist].map { (row: $0, weight: 0.5 + 0.5 * seed.weight, seed: seed.artist, cluster: seed.cluster) } }
        report.seedsOnRadio = seedRows.count
        let centroids = Dictionary(uniqueKeysWithValues: profile.clusters.map { ($0.id, $0.centroid) })
        await readAppearances(seedRows.map(\.row))
        await readEpisodes(for: seedRows.map(\.row))
        await readDegrees(seedRows.map(\.row))

        // Rows of the listener's own artists: never candidates.
        var exclude = Set(seedRows.map(\.row))
        var firstPass = hop(from: seedRows, radio: radio, centroids: centroids, vectors: vectors, exclude: exclude, perEpisode: perEpisode)
        let firstRows = firstPass.keys.sorted { $0.uuidString < $1.uuidString }
        for chunk in stride(from: 0, to: firstRows.count, by: 150).map({ Array(firstRows.dropFirst($0).prefix(150)) }) {
            report.requests += 1   // a name and an id: two reads
            let found = await call({ try await source.names(chunk) }, [:])
            for (k, v) in found { radio.names[k] = v }
        }
        for (row, entry) in radio.names where knownKeys.contains(RecordingKey.normalizeArtist(entry.name)) { exclude.insert(row) }
        // Degrees for what could matter: the strongest few hundred.
        let strongest = firstPass.sorted { $0.value.score != $1.value.score ? $0.value.score > $1.value.score : $0.key.uuidString < $1.key.uuidString }
            .prefix(300).map(\.key)
        await readDegrees(strongest)
        firstPass = hop(from: seedRows, radio: radio, centroids: centroids, vectors: vectors, exclude: exclude, perEpisode: perEpisode)

        // Bridges: the strongest first-hop artists that are not hubs, known
        // or not -- a known artist is still a way through.
        let ranked = firstPass.sorted { $0.value.score != $1.value.score ? $0.value.score > $1.value.score : $0.key.uuidString < $1.key.uuidString }
        let bridgeRows = ranked.filter { (radio.showsPlaying[$0.key] ?? 0) <= 40 }.prefix(bridgeLimit)
        let top = bridgeRows.first?.value.score ?? 1
        let bridges = bridgeRows.map { (row: $0.key, weight: 0.5 * $0.value.score / max(top, 1e-9), seed: $0.value.seed, cluster: $0.value.cluster) }
        report.bridges = bridges.count
        await readAppearances(bridges.map(\.row))
        await readEpisodes(for: bridges.map(\.row))
        var secondExclude = exclude.union(bridges.map(\.row))
        var secondPass = hop(from: bridges, radio: radio, centroids: centroids, vectors: vectors, exclude: secondExclude, perEpisode: perEpisode.map { max(1, $0 - 1) })
        let newRows = secondPass.keys.filter { radio.names[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
        for chunk in stride(from: 0, to: newRows.count, by: 150).map({ Array(newRows.dropFirst($0).prefix(150)) }) {
            report.requests += 1   // a name and an id: two reads
            let found = await call({ try await source.names(chunk) }, [:])
            for (k, v) in found { radio.names[k] = v }
        }
        for (row, entry) in radio.names where knownKeys.contains(RecordingKey.normalizeArtist(entry.name)) { secondExclude.insert(row) }
        let secondStrongest = secondPass.sorted { $0.value.score != $1.value.score ? $0.value.score > $1.value.score : $0.key.uuidString < $1.key.uuidString }
            .prefix(300).map(\.key)
        await readDegrees(secondStrongest)
        secondPass = hop(from: bridges, radio: radio, centroids: centroids, vectors: vectors, exclude: secondExclude, perEpisode: perEpisode.map { max(1, $0 - 1) })
        // A second hop already reached in one is the first hop's.
        for row in firstPass.keys { secondPass[row] = nil }
        for row in exclude { firstPass[row] = nil }
        report.milliseconds = Double((ContinuousClock.now - started).components.attoseconds) / 1e15
            + Double((ContinuousClock.now - started).components.seconds) * 1000
        return (firstPass, secondPass, radio, rowOf, report)
    }

    /// Bounded: a seed keeps its strongest `perSeed` first-hop artists, a
    /// bridge its strongest `perBridge` second-hop ones, so one busy
    /// programme cannot fill the pool and the second hop stays a few
    /// well-evidenced steps rather than everything two episodes away.
    static func bound(_ scores: [UUID: RadioScore], per group: (RadioScore) -> String, keep: Int) -> [UUID: RadioScore] {
        var out: [UUID: RadioScore] = [:]
        for (_, members) in Dictionary(grouping: scores, by: { group($0.value) }) {
            for item in members.sorted(by: { $0.value.score != $1.value.score ? $0.value.score > $1.value.score : $0.key.uuidString < $1.key.uuidString }).prefix(keep) {
                out[item.key] = item.value
            }
        }
        return out
    }

    /// Radio scores as sightings, with their reasons.
    static func sightings(first: [UUID: RadioScore], second: [UUID: RadioScore], radio: Radio,
                          seedNames: [String: String]) -> [Sighting] {
        var out: [Sighting] = []
        for (row, score) in first {
            guard let entry = radio.names[row] else { continue }
            let seed = seedNames[score.seed] ?? score.seed
            let near = score.distance == 1 ? "next to" : "near"
            out.append(Sighting(name: entry.name, discogsID: entry.discogs, catalogueRow: row,
                                route: Route(provenance: .radioAdjacent, score: score.score, seed: score.seed, cluster: score.cluster,
                                             why: "Played \(near) \(seed)\(score.showTitle.map { " on \($0)" } ?? "")"
                                                + (score.shows > 1 ? " and \(score.shows - 1) more programmes" : ""),
                                             evidence: "episode:\(score.episode.uuidString.lowercased())")))
        }
        for (row, score) in second {
            guard let entry = radio.names[row] else { continue }
            let seed = seedNames[score.seed] ?? score.seed
            let bridge = radio.names[score.via]?.name ?? "another artist"
            out.append(Sighting(name: entry.name, discogsID: entry.discogs, catalogueRow: row,
                                route: Route(provenance: .radioSecondHop, score: score.score, seed: score.seed, cluster: score.cluster,
                                             why: "Played near \(bridge)\(score.showTitle.map { " on \($0)" } ?? ""); \(bridge) is played near \(seed)",
                                             evidence: "episode:\(score.episode.uuidString.lowercased())")))
        }
        return out
    }

    // MARK: Live

    static let liveRadio = RadioSource(
        rows: RadioListenFinder.live.rows,
        rowsByName: { keys in
            let client = try SupabaseService.requireClient()
            struct Row: Decodable { let id: UUID; let normalized_name: String }
            let rows: [Row] = try await client.from("artists").select("id,normalized_name")
                .in("normalized_name", values: keys).limit(400).execute().value
            var found: [String: [UUID]] = [:]
            for row in rows { found[row.normalized_name, default: []].append(row.id) }
            return found.compactMapValues { $0.count == 1 ? $0[0] : nil }
        },
        appearances: { row, cutoff in
            let client = try SupabaseService.requireClient()
            struct Raw: Decodable {
                struct Episode: Decodable {
                    struct Show: Decodable { let title: String? }
                    let id: UUID; let aired_at: Date?; let radio_show_id: UUID?; let genres: [String]?; let radio_shows: Show?
                }
                let track_index: Int?
                let radio_episodes: Episode?
            }
            let raw: [Raw] = try await client.from("radio_appearances")
                .select("track_index,radio_episodes!inner(id,aired_at,radio_show_id,genres,radio_shows(title))")
                .eq("artist_id", value: row.uuidString)
                .lt("radio_episodes.aired_at", value: ISO8601DateFormatter().string(from: cutoff))
                .order("radio_episode_id").order("track_index")
                .limit(200).execute().value
            return raw.compactMap { r in
                guard let e = r.radio_episodes, let aired = e.aired_at, let index = r.track_index else { return nil }
                return (Radio.Episode(id: e.id, show: e.radio_show_id, showTitle: e.radio_shows?.title, aired: aired, genres: e.genres ?? []), index)
            }
        },
        tracklists: { episodes in
            let client = try SupabaseService.requireClient()
            struct Raw: Decodable { let radio_episode_id: UUID; let track_index: Int?; let artist_id: UUID? }
            let raw: [Raw] = try await client.from("radio_appearances").select("radio_episode_id,track_index,artist_id")
                .in("radio_episode_id", values: episodes.map(\.uuidString))
                .order("radio_episode_id").order("track_index").limit(1000).execute().value
            var out: [UUID: [Radio.Slot]] = [:]
            for r in raw { if let artist = r.artist_id, let index = r.track_index { out[r.radio_episode_id, default: []].append(Radio.Slot(index: index, artist: artist)) } }
            return out
        },
        showGenres: { shows in
            let client = try SupabaseService.requireClient()
            struct Raw: Decodable { let radio_show_id: UUID; let genres: [String]? }
            let raw: [Raw] = try await client.from("radio_episodes").select("radio_show_id,genres")
                .in("radio_show_id", values: shows.map(\.uuidString)).order("id").limit(1000).execute().value
            var out: [UUID: [String: Int]] = [:]
            for r in raw { for g in ListeningLog.foldTags(r.genres ?? []) { out[r.radio_show_id, default: [:]][g, default: 0] += 1 } }
            return out
        },
        // Shows that played each row, counted from the appearances (0087):
        // `played_by` rows stop at shows that played an artist twice or more.
        showsPlaying: { rows in
            let client = try SupabaseService.requireClient()
            struct Params: Encodable { let p_artists: [UUID] }
            struct Raw: Decodable { let artist_id: UUID; let shows: Int }
            let raw: [Raw] = try await client.rpc("artist_show_counts", params: Params(p_artists: rows)).execute().value
            return Dictionary(raw.map { ($0.artist_id, $0.shows) }, uniquingKeysWith: max)
        },
        names: { rows in
            let client = try SupabaseService.requireClient()
            struct ID: Decodable { let entity_id: UUID; let external_id: String }
            struct Name: Decodable { let id: UUID; let name: String }
            let values = rows.map(\.uuidString)
            async let ids: [ID] = client.from("external_ids").select("entity_id,external_id")
                .eq("provider", value: "discogs").eq("entity_type", value: "artist")
                .in("entity_id", values: values).limit(1000).execute().value
            async let names: [Name] = client.from("artists").select("id,name").in("id", values: values).limit(1000).execute().value
            var discogs: [UUID: Int] = [:]
            for row in try await ids { if let id = Int(row.external_id) { discogs[row.entity_id] = min(id, discogs[row.entity_id] ?? id) } }
            var out: [UUID: (name: String, discogs: Int?)] = [:]
            for row in try await names { out[row.id] = (row.name, discogs[row.id]) }
            return out
        }
    )
}
