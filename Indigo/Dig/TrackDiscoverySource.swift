//
//  TrackDiscoverySource.swift
//  Indigo
//
//  Where Discover's tracks come from, read-only and batched: the backend's
//  Discogs identity rows (`external_ids`), the radio neighbours of every
//  starting point at once (`music_relationships`, both directions, indexed),
//  the neighbours' names (`artists`), and their appearances with episodes
//  (`radio_appearances`) -- all open to the app. Plus DIG's own collaborators,
//  and, where radio has nothing of an artist's, a recording catalogued with
//  one of their releases (`ReleaseVideoTracks`). Identities and neighbours
//  are kept a day, so a second look asks for little more than the tracks.
//
//  Tracks are handed over as each one passes its playback check, so the first
//  can be on screen while the rest are still being asked about.
//

import Foundation
import Supabase

nonisolated struct TrackDiscoverySource: Sendable {
    /// What one discovery cost and found, for measurement.
    struct Report: Sendable, Equatable {
        var seeds = 0, seedsOnRadio = 0, neighbours = 0, verifiedNeighbours = 0
        var appearanceRows = 0, recordings = 0, episodeTracks = 0, releaseVideos = 0, metadataOnly = 0
        var offered = 0, own = 0, checkedPlays = 0, checkedDoesNot = 0, checkedUnknown = 0
        var requests = 0, cachedReads = 0, failures = 0
        var milliseconds = 0.0, firstTrackMilliseconds: Double?
    }

    /// One appearance row, with its episode.
    struct Row: Decodable, Sendable {
        struct Episode: Decodable, Sendable {
            struct Show: Decodable, Sendable { let title: String? }
            let provider: String
            let external_id: String
            let archive_url: String?
            let title: String?
            let aired_at: Date?
            let image_url: String?
            let genres: [String]?
            let radio_shows: Show?
        }
        let artist_id: UUID?
        let raw_track_title: String?
        let offset_seconds: Int?
        let media_url: String?
        let radio_episodes: Episode?
    }

    /// A radio adjacency between two artist rows.
    struct Edge: Sendable, Equatable { let a: UUID; let b: UUID; let episodes: Int }

    var rows: @Sendable ([Int]) async throws -> [Int: [UUID]]
    var neighbours: @Sendable ([UUID]) async throws -> [Edge]
    var artists: @Sendable ([UUID]) async throws -> [UUID: (discogs: Int, name: String)]
    var appearances: @Sendable ([UUID]) async throws -> [Row]
    /// Recordings catalogued with an artist's releases, verified to be their
    /// tracks (`ReleaseVideoTracks`); empty when nothing matches.
    var releaseVideos: @Sendable (Int, String) async -> [TrackDiscovery.Appearance] = { _, _ in [] }
    var plays: @Sendable (DiscoveredTrack.Source) async -> Bool?
    var cache: TrackDiscoveryCache = .shared

    /// What to look for.
    struct Ask: Sendable {
        var seeds: [TrackDiscovery.Seed]
        var collaborators: [TrackDiscovery.Neighbour] = []
        var taste: TasteProfile = .empty
        var knownArtists: Set<String> = []
        var knownTracks: Set<String> = []
        var limit = 12
        /// For an artist page: a few of the seed's own tracks first.
        var ownTracks = 0
        /// Release recordings for up to this many neighbours radio has
        /// nothing of.
        var releaseLookups = 0
    }

    /// Neighbours in, tracks out, ranked and checked; `progress` is called
    /// with everything offered so far, each time another track passes.
    func discover(_ ask: Ask, progress: @escaping @Sendable ([DiscoveredTrack]) async -> Void = { _ in })
        async -> (tracks: [DiscoveredTrack], report: Report) {
        let started = ContinuousClock.now
        var report = Report()
        report.seeds = ask.seeds.count
        func elapsed() -> Double {
            let spent = ContinuousClock.now - started
            return Double(spent.components.seconds) * 1000 + Double(spent.components.attoseconds) / 1e15
        }

        // Starting points as the backend's rows (kept a day).
        let seedIDs = ask.seeds.map(\.discogsID)
        var seedRows = await cache.rows(for: seedIDs)
        let missingSeeds = seedIDs.filter { seedRows[$0] == nil }
        if !missingSeeds.isEmpty {
            do {
                report.requests += 1
                let found = try await rows(missingSeeds)
                await cache.keep(rows: found, asked: missingSeeds)
                seedRows.merge(found) { first, _ in first }
            } catch { report.failures += 1 }
        } else { report.cachedReads += 1 }
        let seedOfRow = Dictionary(ask.seeds.flatMap { seed in (seedRows[seed.discogsID] ?? []).prefix(2).map { ($0, seed) } },
                                   uniquingKeysWith: { first, _ in first })

        // Every starting point's radio neighbours at once (kept a day).
        var edges = await cache.edges(for: Array(seedOfRow.keys))
        let missingRows = seedOfRow.keys.filter { edges[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
        if !missingRows.isEmpty {
            do {
                report.requests += 2
                let found = try await neighbours(missingRows)
                var byRow: [UUID: [Edge]] = Dictionary(uniqueKeysWithValues: missingRows.map { ($0, []) })
                for edge in found {
                    if byRow[edge.a] != nil { byRow[edge.a]?.append(edge) }
                    if byRow[edge.b] != nil { byRow[edge.b]?.append(Edge(a: edge.b, b: edge.a, episodes: edge.episodes)) }
                }
                await cache.keep(edges: byRow)
                edges.merge(byRow) { first, _ in first }
            } catch { report.failures += 1 }
        } else { report.cachedReads += 1 }
        report.seedsOnRadio = Set(edges.filter { !$0.value.isEmpty }.keys.compactMap { seedOfRow[$0]?.discogsID }).count

        // Who the neighbours are: verified entries only (kept a day). The
        // strongest few dozen, so a hub-heavy starting point cannot flood it.
        var scored: [UUID: (seed: TrackDiscovery.Seed, episodes: Int)] = [:]
        for (row, list) in edges {
            guard let seed = seedOfRow[row] else { continue }
            for edge in list where seedOfRow[edge.b] == nil {
                if let held = scored[edge.b], Double(held.episodes) * held.seed.weight >= Double(edge.episodes) * seed.weight { continue }
                scored[edge.b] = (seed, edge.episodes)
            }
        }
        let shortlist = scored.sorted {
            let l = Double($0.value.episodes) * $0.value.seed.weight, r = Double($1.value.episodes) * $1.value.seed.weight
            return l != r ? l > r : $0.key.uuidString < $1.key.uuidString
        }.prefix(60).map(\.key)
        var who = await cache.artists(for: shortlist)
        let unknownArtists = shortlist.filter { who[$0] == nil }
        if !unknownArtists.isEmpty {
            do {
                report.requests += 2
                let found = try await artists(unknownArtists)
                await cache.keep(artists: found, asked: unknownArtists)
                who.merge(found.mapValues { Optional($0) }) { first, _ in first }
            } catch { report.failures += 1 }
        } else { report.cachedReads += 1 }
        let seedDiscogs = Set(seedIDs)
        var neighbours = shortlist.compactMap { row -> TrackDiscovery.Neighbour? in
            guard let entry = who[row] ?? nil, let found = scored[row], !seedDiscogs.contains(entry.discogs) else { return nil }
            return .init(discogsID: entry.discogs, name: entry.name, seed: found.seed,
                         reason: "Played next to \(found.seed.name) in \(found.episodes) radio episode\(found.episodes == 1 ? "" : "s")",
                         strength: 1 + log2(Double(found.episodes)))
        }
        neighbours += ask.collaborators.filter { !seedDiscogs.contains($0.discogsID) }
        report.neighbours = scored.count + ask.collaborators.count
        report.verifiedNeighbours = Set(neighbours.map(\.discogsID)).count

        // Their tracks, and the seed's own for an artist page: one read.
        var rowOf: [UUID: Int] = [:]
        for row in shortlist { if let entry = who[row] ?? nil { rowOf[row] = entry.discogs } }
        if ask.ownTracks > 0 { for seed in ask.seeds { for row in seedRows[seed.discogsID] ?? [] { rowOf[row] = seed.discogsID } } }
        let names = Dictionary(neighbours.map { ($0.discogsID, $0.name) } + ask.seeds.map { ($0.discogsID, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        var fetched: [Row] = []
        if !rowOf.isEmpty {
            do { report.requests += 1; fetched = try await appearances(Array(rowOf.keys).sorted { $0.uuidString < $1.uuidString }) }
            catch { report.failures += 1 }
        }
        report.appearanceRows = fetched.count
        var appearances: [TrackDiscovery.Appearance] = []
        var heardOf = Set<Int>()
        for row in fetched {
            guard let uuid = row.artist_id, let id = rowOf[uuid],
                  let appearance = TrackDiscovery.appearance(from: row, artistID: id, artist: names[id] ?? "", report: &report)
            else { continue }
            heardOf.insert(id)
            appearances.append(appearance)
        }

        // Release recordings where radio has nothing of them.
        if ask.releaseLookups > 0 {
            var asked = 0
            if ask.ownTracks > 0 {
                for seed in ask.seeds where !heardOf.contains(seed.discogsID) && asked < ask.releaseLookups {
                    asked += 1
                    let found = await releaseVideos(seed.discogsID, seed.name)
                    report.requests += found.isEmpty ? 1 : 3
                    report.releaseVideos += found.count
                    appearances += found
                }
            }
            for neighbour in neighbours where !heardOf.contains(neighbour.discogsID) && asked < ask.releaseLookups {
                asked += 1
                let found = await releaseVideos(neighbour.discogsID, neighbour.name)
                report.requests += found.isEmpty ? 1 : 3
                report.releaseVideos += found.count
                appearances += found
            }
        }

        // The seed's own tracks first on an artist page, then adjacent ones.
        let own = ask.ownTracks > 0
            ? TrackDiscovery.own(appearances.filter { seedDiscogs.contains($0.artistDiscogsID) }, limit: ask.ownTracks * 2)
            : []
        let ranked = TrackDiscovery.rank(neighbours: neighbours, appearances: appearances.filter { !seedDiscogs.contains($0.artistDiscogsID) },
                                         taste: ask.taste, knownArtists: ask.knownArtists, knownTracks: ask.knownTracks,
                                         limit: ask.limit * 2)

        // Checked four at a time; each that plays is handed over at once.
        var offered: [DiscoveredTrack] = []
        var ownOffered = 0
        let queue = own + ranked
        for chunk in stride(from: 0, to: queue.count, by: 4).map({ Array(queue.dropFirst($0).prefix(4)) }) {
            guard offered.count - ownOffered < ask.limit || ownOffered < ask.ownTracks else { break }
            let checked = await withTaskGroup(of: (Int, Bool?).self) { group in
                for (index, track) in chunk.enumerated() { group.addTask { (index, await plays(track.source)) } }
                var answers: [Int: Bool?] = [:]
                for await (index, answer) in group { answers[index] = answer }
                return answers
            }
            for (index, var track) in chunk.enumerated() {
                let isOwn = seedDiscogs.contains(track.artistDiscogsID)
                if isOwn ? ownOffered >= ask.ownTracks : offered.count - ownOffered >= ask.limit { continue }
                switch checked[index] ?? nil {
                case true?:
                    track.playable = .yes
                    report.checkedPlays += 1
                    offered.append(track)
                    if isOwn { ownOffered += 1 }
                    if report.firstTrackMilliseconds == nil { report.firstTrackMilliseconds = elapsed() }
                    await progress(offered)
                case false?: report.checkedDoesNot += 1
                case nil: report.checkedUnknown += 1
                }
            }
        }
        report.offered = offered.count
        report.own = ownOffered
        report.milliseconds = elapsed()
        return (offered, report)
    }

    // MARK: Live

    static let live = TrackDiscoverySource(
        rows: RadioListenFinder.live.rows,
        neighbours: { rows in
            let client = try SupabaseService.requireClient()
            struct Raw: Decodable { let from_entity_id: UUID; let to_entity_id: UUID; let evidence_count: Int; let episode_count: Int? }
            let ids = rows.map(\.uuidString)
            async let out: [Raw] = client.from("music_relationships")
                .select("from_entity_id,to_entity_id,evidence_count,episode_count")
                .eq("relationship_type", value: "radio_neighbor").eq("from_entity_type", value: "artist")
                .eq("to_entity_type", value: "artist").in("from_entity_id", values: ids)
                .order("evidence_count", ascending: false).limit(1500).execute().value
            async let into: [Raw] = client.from("music_relationships")
                .select("from_entity_id,to_entity_id,evidence_count,episode_count")
                .eq("relationship_type", value: "radio_neighbor").eq("to_entity_type", value: "artist")
                .eq("from_entity_type", value: "artist").in("to_entity_id", values: ids)
                .order("evidence_count", ascending: false).limit(1500).execute().value
            return try await (out + into).map { Edge(a: $0.from_entity_id, b: $0.to_entity_id, episodes: max(1, $0.episode_count ?? $0.evidence_count)) }
        },
        artists: { uuids in
            let client = try SupabaseService.requireClient()
            struct ID: Decodable { let entity_id: UUID; let external_id: String }
            struct Name: Decodable { let id: UUID; let name: String }
            let values = uuids.map(\.uuidString)
            async let ids: [ID] = client.from("external_ids").select("entity_id,external_id")
                .eq("provider", value: "discogs").eq("entity_type", value: "artist")
                .in("entity_id", values: values).limit(400).execute().value
            async let names: [Name] = client.from("artists").select("id,name").in("id", values: values).limit(400).execute().value
            let named = Dictionary(try await names.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            var found: [UUID: (discogs: Int, name: String)] = [:]
            for row in try await ids {
                guard found[row.entity_id] == nil, let id = Int(row.external_id), let name = named[row.entity_id] else { continue }
                found[row.entity_id] = (id, name)
            }
            return found
        },
        appearances: { uuids in
            let client = try SupabaseService.requireClient()
            return try await client.from("radio_appearances")
                .select("artist_id,raw_track_title,offset_seconds,media_url,radio_episodes(provider,external_id,archive_url,title,aired_at,image_url,genres,radio_shows(title))")
                .in("artist_id", values: uuids.map(\.uuidString))
                .limit(900)
                .execute().value
        },
        releaseVideos: { id, name in await ReleaseVideoTracks.live.tracks(artistID: id, artist: name) },
        plays: { source in
            switch source {
            case .recording(let url, _): await YouTubeAvailability.isPlayable(url)
            case .episode(let listen, _): await RadioListenFinder.playable(provider: listen.provider, url: listen.archiveURL)
            }
        }
    )
}

/// Identities and radio neighbours, kept a day for the session's looks.
actor TrackDiscoveryCache {
    static let shared = TrackDiscoveryCache()
    private let lifetime: TimeInterval = 24 * 60 * 60
    private var rowsByID: [Int: (rows: [UUID], at: Date)] = [:]
    private var edgesByRow: [UUID: (edges: [TrackDiscoverySource.Edge], at: Date)] = [:]
    private var artistByRow: [UUID: (entry: (discogs: Int, name: String)?, at: Date)] = [:]

    private func fresh(_ at: Date) -> Bool { Date().timeIntervalSince(at) < lifetime }

    func rows(for ids: [Int]) -> [Int: [UUID]] {
        Dictionary(ids.compactMap { id in rowsByID[id].flatMap { fresh($0.at) ? (id, $0.rows) : nil } }, uniquingKeysWith: { first, _ in first })
    }
    func keep(rows found: [Int: [UUID]], asked: [Int]) {
        for id in asked { rowsByID[id] = (found[id] ?? [], Date()) }
    }
    func edges(for rows: [UUID]) -> [UUID: [TrackDiscoverySource.Edge]] {
        Dictionary(rows.compactMap { row in edgesByRow[row].flatMap { fresh($0.at) ? (row, $0.edges) : nil } }, uniquingKeysWith: { first, _ in first })
    }
    func keep(edges found: [UUID: [TrackDiscoverySource.Edge]]) {
        for (row, list) in found { edgesByRow[row] = (list, Date()) }
    }
    func artists(for rows: [UUID]) -> [UUID: (discogs: Int, name: String)?] {
        Dictionary(rows.compactMap { row in artistByRow[row].flatMap { fresh($0.at) ? (row, $0.entry) : nil } }, uniquingKeysWith: { first, _ in first })
    }
    func keep(artists found: [UUID: (discogs: Int, name: String)], asked: [UUID]) {
        for row in asked { artistByRow[row] = (found[row], Date()) }
    }
    func clear() { rowsByID = [:]; edgesByRow = [:]; artistByRow = [:] }
}

extension TrackDiscovery {
    /// An appearance row as a track that can be heard, or nil (counted) when
    /// it is a name only or an upload that is not the track.
    static func appearance(from row: TrackDiscoverySource.Row, artistID: Int, artist: String,
                           report: inout TrackDiscoverySource.Report) -> Appearance? {
        guard let title = row.raw_track_title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
              let episode = row.radio_episodes else { return nil }
        if let link = row.media_url, let url = URL(string: link), YouTubeLink.isYouTube(url) {
            guard isTrackUpload(title: title, artist: artist) else { report.metadataOnly += 1; return nil }
            report.recordings += 1
            return .init(artistDiscogsID: artistID, artist: artist, title: title,
                         source: .recording(url, channel: episode.radio_shows?.title),
                         artworkURL: DiscoveredTrack.thumbnail(for: url), genres: ListeningLog.foldTags(episode.genres ?? []))
        }
        guard let provider = RadioListenFinder.appProvider(episode.provider), let link = episode.archive_url,
              let url = URL(string: link), let offset = row.offset_seconds else { report.metadataOnly += 1; return nil }
        report.episodeTracks += 1
        return .init(artistDiscogsID: artistID, artist: artist, title: title,
                     source: .episode(RadioListen(provider: provider, episode: episode.external_id,
                                                  episodeTitle: episode.title ?? episode.radio_shows?.title ?? "Radio episode",
                                                  showTitle: episode.radio_shows?.title, airedAt: episode.aired_at,
                                                  played: title, offsetSeconds: offset, archiveURL: url), at: offset),
                     artworkURL: episode.image_url.flatMap(URL.init(string:)), genres: ListeningLog.foldTags(episode.genres ?? []))
    }

    /// An artist page's own tracks: recordings first, one per title.
    static func own(_ appearances: [Appearance], limit: Int) -> [DiscoveredTrack] {
        var seen = Set<String>()
        func order(_ source: DiscoveredTrack.Source) -> Int { if case .recording = source { 0 } else { 1 } }
        return appearances
            .sorted { order($0.source) != order($1.source) ? order($0.source) < order($1.source) : ($0.title, $0.artistDiscogsID) < ($1.title, $1.artistDiscogsID) }
            .filter { seen.insert(trackKey($0.title)).inserted }
            .prefix(limit)
            .map { appearance in
                DiscoveredTrack(artist: appearance.artist, artistDiscogsID: appearance.artistDiscogsID, title: appearance.title,
                                source: appearance.source, artworkURL: appearance.artworkURL, release: appearance.release,
                                year: appearance.year, reason: "By \(appearance.artist)", via: appearance.artist,
                                playable: .unknown, score: 0)
            }
    }
}

extension DiscoveredTrack {
    /// What the player plays, and where to start: a recording from its
    /// beginning, an episode from the moment the track was played.
    var mediaItem: (item: MediaItem, startAt: Int?) {
        switch source {
        case .recording(let url, let channel):
            return (MediaItem(id: "youtube.\(url.absoluteString)", sourceID: "youtube", kind: .track, title: title,
                              subtitle: artist, detail: release ?? channel ?? artist, remoteArtworkURL: artworkURL,
                              playbackURL: url, embedProvider: .youtube), nil)
        case .episode(let listen, let offset):
            let host = listen.archiveURL.host?.lowercased() ?? ""
            let embed: EmbedProvider? = host.hasSuffix("soundcloud.com") ? .soundcloud : host.hasSuffix("mixcloud.com") ? .mixcloud : nil
            return (MediaItem(id: "\(listen.provider).episode.\(listen.episode)", sourceID: listen.provider, kind: .episode,
                              title: listen.episodeTitle, subtitle: "\(artist) — \(title)", detail: listen.showTitle,
                              remoteArtworkURL: artworkURL, playbackURL: listen.archiveURL, embedProvider: embed), offset)
        }
    }
}
