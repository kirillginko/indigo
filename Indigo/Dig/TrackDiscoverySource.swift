//
//  TrackDiscoverySource.swift
//  Indigo
//
//  Where Discover's tracks come from, read-only: the backend's Discogs
//  identity rows (`external_ids`), each starting point's radio neighbours
//  (`artist_radio_relations`: artists played next to them in tracklists), and
//  the neighbours' appearances with their episodes (`radio_appearances`, all
//  open to the app). Plus the starting points' collaborators from DIG's own
//  graph. Bounded: a dozen starting points, a few dozen candidates, a few
//  hundred appearance rows, and playback checks only for what is about to be
//  shown.
//

import Foundation
import Supabase

nonisolated struct TrackDiscoverySource: Sendable {
    /// What one discovery cost and found, for measurement.
    struct Report: Sendable, Equatable {
        var seeds = 0, seedsOnRadio = 0, neighbours = 0, verifiedNeighbours = 0
        var appearanceRows = 0, recordings = 0, episodeTracks = 0, metadataOnly = 0
        var offered = 0, checkedPlays = 0, checkedDoesNot = 0, checkedUnknown = 0
        var requests = 0, failures = 0
        var milliseconds = 0.0
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

    var rows: @Sendable ([Int]) async throws -> [Int: [UUID]]
    var discogsIDs: @Sendable ([UUID]) async throws -> [UUID: Int]
    var relations: @Sendable (UUID) async throws -> [Catalog.RadioRelation]
    var appearances: @Sendable ([UUID]) async throws -> [Row]
    var plays: @Sendable (DiscoveredTrack.Source) async -> Bool?

    /// Neighbours in, tracks out, ranked and checked.
    func discover(
        seeds: [TrackDiscovery.Seed], collaborators: [TrackDiscovery.Neighbour], taste: TasteProfile,
        knownArtists: Set<String>, knownTracks: Set<String>, limit: Int = 12
    ) async -> (tracks: [DiscoveredTrack], report: Report) {
        let started = ContinuousClock.now
        var report = Report()
        report.seeds = seeds.count
        func elapsed() -> Double {
            let spent = ContinuousClock.now - started
            return Double(spent.components.seconds) * 1000 + Double(spent.components.attoseconds) / 1e15
        }
        // Starting points as the backend's rows.
        var seedRows: [Int: [UUID]] = [:]
        do { report.requests += 1; seedRows = try await rows(seeds.map(\.discogsID)) } catch { report.failures += 1 }

        // Who radio plays next to them.
        var neighbourRows: [(uuid: UUID, name: String, seed: TrackDiscovery.Seed, episodes: Int)] = []
        let asks = seeds.flatMap { seed in (seedRows[seed.discogsID] ?? []).prefix(2).map { (seed, $0) } }
        // Four at a time, answers put back in the seeds' order so the result
        // does not depend on which came back first.
        for chunk in stride(from: 0, to: asks.count, by: 4).map({ Array(asks.dropFirst($0).prefix(4)) }) {
            let answers = await withTaskGroup(of: (Int, [Catalog.RadioRelation]?).self) { group in
                for (index, ask) in chunk.enumerated() { group.addTask { (index, try? await relations(ask.1)) } }
                var found: [Int: [Catalog.RadioRelation]?] = [:]
                for await (index, answer) in group { found[index] = answer }
                return found
            }
            for (index, ask) in chunk.enumerated() {
                report.requests += 1
                guard let found = answers[index] ?? nil else { report.failures += 1; continue }
                if !found.isEmpty { report.seedsOnRadio += 1 }
                for relation in found where relation.relationshipType == "radio_neighbor" && relation.entityType == "artist" {
                    let episodes = relation.metadata?.episodes ?? relation.metadata?.adjacencies ?? relation.evidenceCount
                    neighbourRows.append((relation.entityID, relation.title ?? "", ask.0, max(1, episodes)))
                }
            }
        }
        // Only verified entries: a neighbour with no Discogs identity is a
        // name, not somebody a card can open.
        var verified: [UUID: Int] = [:]
        let wanted = Array(Set(neighbourRows.map(\.uuid))).sorted { $0.uuidString < $1.uuidString }
        for chunk in stride(from: 0, to: wanted.count, by: 80).map({ Array(wanted.dropFirst($0).prefix(80)) }) {
            do { report.requests += 1; verified.merge(try await discogsIDs(chunk)) { first, _ in first } } catch { report.failures += 1 }
        }
        var neighbours = neighbourRows.compactMap { row -> TrackDiscovery.Neighbour? in
            guard let id = verified[row.uuid], id != row.seed.discogsID else { return nil }
            return .init(discogsID: id, name: row.name, seed: row.seed,
                         reason: "Played next to \(row.seed.name) in \(row.episodes) radio episode\(row.episodes == 1 ? "" : "s")",
                         strength: 1 + log2(Double(row.episodes)))
        }
        neighbours += collaborators
        report.neighbours = Set(neighbourRows.map(\.uuid)).count + collaborators.count
        report.verifiedNeighbours = Set(neighbours.map(\.discogsID)).count

        // Their tracks, the strongest neighbours first.
        let strongest = Dictionary(neighbours.map { ($0.discogsID, $0.strength * $0.seed.weight) }, uniquingKeysWith: max)
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(48).map(\.key)
        var candidateRows: [Int: [UUID]] = [:]
        do { report.requests += 1; candidateRows = try await rows(strongest) } catch { report.failures += 1 }
        let byRow = Dictionary(candidateRows.flatMap { id, uuids in uuids.map { ($0, id) } }, uniquingKeysWith: { first, _ in first })
        var fetched: [Row] = []
        let rowIDs = Array(byRow.keys).sorted { $0.uuidString < $1.uuidString }
        for chunk in stride(from: 0, to: rowIDs.count, by: 24).map({ Array(rowIDs.dropFirst($0).prefix(24)) }) {
            do { report.requests += 1; fetched += try await appearances(chunk) } catch { report.failures += 1 }
        }
        report.appearanceRows = fetched.count
        let names = Dictionary(neighbours.map { ($0.discogsID, $0.name) }, uniquingKeysWith: { first, _ in first })
        var appearances: [TrackDiscovery.Appearance] = []
        for row in fetched {
            guard let uuid = row.artist_id, let id = byRow[uuid], let title = row.raw_track_title?.trimmingCharacters(in: .whitespaces),
                  !title.isEmpty, let episode = row.radio_episodes else { continue }
            let source: DiscoveredTrack.Source
            var artwork: URL?
            if let link = row.media_url, let url = URL(string: link), YouTubeLink.isYouTube(url) {
                // An upload is the track only if it says so: not footage or
                // an interview, and not headed by somebody else's name.
                guard TrackDiscovery.isTrackUpload(title: title, artist: names[id] ?? "") else { report.metadataOnly += 1; continue }
                source = .recording(url, channel: episode.radio_shows?.title)
                artwork = DiscoveredTrack.thumbnail(for: url)
                report.recordings += 1
            } else if let provider = RadioListenFinder.appProvider(episode.provider), let link = episode.archive_url,
                      let url = URL(string: link), let offset = row.offset_seconds {
                source = .episode(RadioListen(provider: provider, episode: episode.external_id,
                                              episodeTitle: episode.title ?? episode.radio_shows?.title ?? "Radio episode",
                                              showTitle: episode.radio_shows?.title, airedAt: episode.aired_at,
                                              played: title, offsetSeconds: offset, archiveURL: url), at: offset)
                artwork = episode.image_url.flatMap(URL.init(string:))
                report.episodeTracks += 1
            } else {
                report.metadataOnly += 1
                continue
            }
            appearances.append(.init(artistDiscogsID: id, artist: names[id] ?? "", title: title, source: source,
                                     artworkURL: artwork, genres: ListeningLog.foldTags(episode.genres ?? [])))
        }

        // Ranked, then checked until there are enough that play.
        let ranked = TrackDiscovery.rank(neighbours: neighbours, appearances: appearances, taste: taste,
                                         knownArtists: knownArtists, knownTracks: knownTracks, limit: limit * 2)
        var offered: [DiscoveredTrack] = []
        for chunk in stride(from: 0, to: ranked.count, by: 4).map({ Array(ranked.dropFirst($0).prefix(4)) }) {
            guard offered.count < limit else { break }
            let checked = await withTaskGroup(of: (Int, Bool?).self) { group in
                for (index, track) in chunk.enumerated() { group.addTask { (index, await plays(track.source)) } }
                var answers: [Int: Bool?] = [:]
                for await (index, answer) in group { answers[index] = answer }
                return answers
            }
            for (index, var track) in chunk.enumerated() where offered.count < limit {
                switch checked[index] ?? nil {
                case true?: track.playable = .yes; report.checkedPlays += 1; offered.append(track)
                case false?: report.checkedDoesNot += 1
                case nil: report.checkedUnknown += 1
                }
            }
        }
        report.offered = offered.count
        report.milliseconds = elapsed()
        return (offered, report)
    }

    // MARK: Live

    static let live = TrackDiscoverySource(
        rows: RadioListenFinder.live.rows,
        discogsIDs: { uuids in
            let client = try SupabaseService.requireClient()
            struct Row: Decodable { let entity_id: UUID; let external_id: String }
            let found: [Row] = try await client.from("external_ids").select("entity_id,external_id")
                .eq("provider", value: "discogs").eq("entity_type", value: "artist")
                .in("entity_id", values: uuids.map(\.uuidString)).limit(400).execute().value
            var mapped: [UUID: Int] = [:]
            for row in found { if let id = Int(row.external_id), mapped[row.entity_id] == nil { mapped[row.entity_id] = id } }
            return mapped
        },
        relations: { row in try await RadioRepository().relations(forArtist: row, limit: 24) },
        appearances: { uuids in
            let client = try SupabaseService.requireClient()
            return try await client.from("radio_appearances")
                .select("artist_id,raw_track_title,offset_seconds,media_url,radio_episodes(provider,external_id,archive_url,title,aired_at,image_url,genres,radio_shows(title))")
                .in("artist_id", values: uuids.map(\.uuidString))
                .limit(600)
                .execute().value
        },
        plays: { source in
            switch source {
            case .recording(let url, _): await YouTubeAvailability.isPlayable(url)
            case .episode(let listen, _): await RadioListenFinder.playable(provider: listen.provider, url: listen.archiveURL)
            }
        }
    )
}

extension DiscoveredTrack {
    /// What the player plays, and where to start: a recording from its
    /// beginning, an episode from the moment the track was played.
    var mediaItem: (item: MediaItem, startAt: Int?) {
        switch source {
        case .recording(let url, let channel):
            return (MediaItem(id: "youtube.\(url.absoluteString)", sourceID: "youtube", kind: .track, title: title,
                              subtitle: artist, detail: channel ?? artist, remoteArtworkURL: artworkURL,
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
