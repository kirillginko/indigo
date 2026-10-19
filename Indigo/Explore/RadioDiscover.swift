// Radio Discover is deliberately separate from the credit-based For You mix.
import Foundation
import SwiftData

nonisolated enum RadioDiscoverFeature {
    static let switchKey = "INDIGO_RADIO_DISCOVER"
    static var isEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: switchKey)
        #else
        false
        #endif
    }
}

nonisolated struct RadioDiscoverPick: Identifiable, Codable, Sendable {
    enum Timing: String, Codable, Sendable {
        case directRecording, publisherEstimated, publisherReported, playbackVerified
        var label: String {
            switch self {
            case .directRecording: "Direct recording · playback checked"
            case .publisherEstimated: "Publisher-estimated timestamp · archive checked; offset unverified"
            case .publisherReported: "Publisher timestamp · archive checked; offset unverified"
            case .playbackVerified: "Playback-verified offset"
            }
        }
    }
    var track: DiscoveredTrack
    var artistRow: UUID
    var cluster: Int
    var clusterLabel: String
    var programme: String
    var episode: String
    var curator: String?
    var timing: Timing
    var supportEpisodes: Int
    var nearest: String
    var distance: Int
    var styles: [String]
    var id: String { "\(artistRow)|\(TrackDiscovery.trackKey(track.title))" }
}

nonisolated struct RadioDiscover: Sendable {
    struct Seed: Sendable {
        var id: Int
        var name: String
        var cluster: Int
        var weight: Double
        var recordings: Set<String>
    }
    struct Inputs: Sendable {
        var seeds: [Seed]
        var labels: [Int: String]
        var styles: [Int: Set<String>]
        var artistStyles: [Int: Set<String>]
        var known: Set<String>
        var key: String
    }
    struct Episode: Codable, Sendable {
        struct Show: Codable, Sendable { var title: String?; var host_name: String? }
        var id: UUID
        var radio_show_id: UUID?
        var provider: String
        var external_id: String
        var archive_url: String?
        var title: String?
        var aired_at: Date?
        var image_url: String?
        var duration_seconds: Int?
        var radio_shows: Show?
        var programmeKey: String { radio_show_id?.uuidString ?? "\(provider):\(external_id)" }
        var programme: String { radio_shows?.title ?? title ?? provider }
    }
    struct Slot: Codable, Sendable {
        var artist_id: UUID?
        var raw_artist_name: String?
        var raw_track_title: String?
        var track_index: Int?
        var offset_seconds: Int?
        var media_url: String?
        var radio_episodes: Episode?
    }
    struct Identity: Sendable {
        var id: Int
        var name: String
    }
    struct Candidate: Sendable {
        var slot: Slot
        var identity: Identity
        var cluster: Int
        var score: Double
        var nearest: String
        var distance: Int
        var repeats: Int
        var sharedStyles: [String]
        var recordingEpisodes: Int
    }
    struct Programme: Codable, Sendable {
        var key: String
        var cluster: Int
        var episodes: Int
        var overlapArtists: [String]
    }
    struct Result: Codable, Sendable {
        var key: String
        var at: Date
        var picks: [RadioDiscoverPick]
        var programmes: [Programme]
        var requests: Int
        var checked: Int
    }
    var source: RadioDiscoverSource

    /// Listener Profile v2 supplies the clusters, recording/album interests,
    /// aliases and independent record styles. This does not construct another profile.
    static func inputs(context: ModelContext) -> Inputs? {
        guard let held = ClusterSeedPicks.inputs(context: context, vectors: [:], now: Date(timeIntervalSince1970: Double(RecommendationRotation.period(at: Date()) + 1) * RecommendationRotation.interval)) else { return nil }
        let rows = (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? []
        let safe = Dictionary(rows.filter { $0.discogsID > 0 && $0.isFiledUnderItsOwnName() }
            .map { ($0.nameKey, $0) }, uniquingKeysWith: { a, _ in a })
        var seeds: [Seed] = []
        var labels: [Int: String] = [:], styles: [Int: Set<String>] = [:]
        for cluster in held.profile.clusters {
            labels[cluster.id] = cluster.label.prefix(3).joined(separator: " / ")
            styles[cluster.id] = Set(cluster.label)
            var seen = Set<Int>()
            for unit in cluster.examples.sorted(by: { $0.longTerm + $0.recent > $1.longTerm + $1.recent }) {
                guard let artist = safe[unit.artist], seen.insert(artist.discogsID).inserted else { continue }
                let knownRecordings = Set(held.profile.units.filter { $0.artist == unit.artist && $0.level == .recording }
                    .map { TrackDiscovery.trackKey($0.title) })
                seeds.append(Seed(id: artist.discogsID, name: DiscogsClient.withoutDisambiguator(artist.name), cluster: cluster.id,
                                  weight: max(0.1, unit.longTerm + unit.recent), recordings: knownRecordings))
                if seen.count >= 4 { break }
            }
        }
        var artistStyles = held.book.byID.mapValues(Set.init)
        for (id, tags) in held.book.recordsByID { artistStyles[id, default: []].formUnion(tags) }
        let parts = held.profile.units.map { "\($0.id)|\($0.longTerm)|\($0.recent)|\($0.styles.joined(separator: ","))" }.sorted()
        return Inputs(seeds: seeds, labels: labels, styles: styles, artistStyles: artistStyles, known: held.known,
                      key: "radio-curators-v1:" + CanonicalDigest.of(parts + seeds.map { "\($0.cluster):\($0.id)" }.sorted() + held.known.sorted()))
    }

    /// Conflicting destinations are excluded, including ambiguous MBID→Discogs
    /// mappings. No name query, new link or artist-style guess is made here.
    static func identities(_ links: [DiscogsIdentityRows.Link], names: [UUID: String]) -> [UUID: Identity] {
        var out: [UUID: Identity] = [:]
        for (row, held) in Dictionary(grouping: links, by: \.entity_id) {
            let direct = Set(held.filter { $0.provider == "discogs" }.compactMap { Int($0.external_id) }.filter { $0 > 0 })
            let mb = Set(held.filter { $0.provider == "musicbrainz_discogs" }.compactMap { Int($0.external_id) }.filter { $0 > 0 })
            let ids = direct.union(mb)
            guard ids.count == 1, let id = ids.first, let name = names[row], ArtistName.isRealArtist(name) else { continue }
            out[row] = Identity(id: id, name: name)
        }
        return out
    }

    static func rank(inputs: Inputs, rows: [Int: [UUID]], slots: [Slot], identities: [UUID: Identity]) -> ([Candidate], [Programme]) {
        let grouped = Dictionary(grouping: slots.filter { $0.radio_episodes != nil }, by: { $0.radio_episodes!.id })
        let rowSeeds = inputs.seeds.flatMap { seed in (rows[seed.id] ?? []).map { ($0, seed) } }
        var programmeSeeds: [String: [Int: Set<String>]] = [:]
        var programmeEpisodes: [String: [Int: Set<UUID>]] = [:]
        var seedFrequency: [Int: Set<UUID>] = [:]
        for (episode, list) in grouped {
            guard let info = list.first?.radio_episodes else { continue }
            for (row, seed) in rowSeeds where list.contains(where: { $0.artist_id == row }) {
                programmeSeeds[info.programmeKey, default: [:]][seed.cluster, default: []].insert(seed.name)
                programmeEpisodes[info.programmeKey, default: [:]][seed.cluster, default: []].insert(episode)
                seedFrequency[seed.id, default: []].insert(episode)
            }
        }
        var recordings: [String: Set<UUID>] = [:]
        for slot in slots {
            if let row = slot.artist_id, let episode = slot.radio_episodes?.id, let title = slot.raw_track_title {
                recordings["\(row)|\(TrackDiscovery.trackKey(title))", default: []].insert(episode)
            }
        }
        var candidates: [Candidate] = [], programmes: [Programme] = []
        for (key, clusters) in programmeEpisodes {
            for (cluster, episodes) in clusters {
                programmes.append(Programme(key: key, cluster: cluster, episodes: episodes.count,
                                            overlapArtists: (programmeSeeds[key]?[cluster] ?? []).sorted()))
            }
        }
        for (_, list) in grouped {
            guard let episode = list.first?.radio_episodes else { continue }
            let clusters = Set(rowSeeds.filter { pair in list.contains { $0.artist_id == pair.0 } }.map { $0.1.cluster })
            for cluster in clusters {
                let overlaps = list.flatMap { slot -> [(Slot, Seed)] in
                    rowSeeds.filter { $0.0 == slot.artist_id && $0.1.cluster == cluster }.map { (slot, $0.1) }
                }
                let repeatCount = programmeEpisodes[episode.programmeKey]?[cluster]?.count ?? 1
                let unique = Set(overlaps.map { $0.1.id }).count
                let overlapScore = overlaps.reduce(0.0) { score, hit in
                    let distinctive = log(1 + Double(grouped.count) / Double(seedFrequency[hit.1.id]?.count ?? 1))
                    let exact = hit.1.recordings.contains(TrackDiscovery.trackKey(hit.0.raw_track_title ?? "")) ? 2.0 : 1.0
                    return score + log(1 + hit.1.weight) * distinctive * exact
                }
                for slot in list {
                    guard let row = slot.artist_id, let identity = identities[row], let title = slot.raw_track_title,
                          !title.isEmpty, let index = slot.track_index,
                          !inputs.known.contains(RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(identity.name))),
                          !inputs.seeds.contains(where: { $0.id == identity.id }) else { continue }
                    let distances = overlaps.compactMap { hit -> (Int, String)? in
                        guard let at = hit.0.track_index else { return nil }
                        return (abs(index - at), "\(hit.1.name) — \(hit.0.raw_track_title ?? "a track")")
                    }.sorted { $0.0 < $1.0 }
                    guard let nearest = distances.first else { continue }
                    let shared = (inputs.artistStyles[identity.id] ?? []).intersection(inputs.styles[cluster] ?? []).sorted()
                    // Each episode/sequence must earn its own place. A DJ's
                    // eclectic overall history cannot pull in unrelated tracks.
                    guard nearest.0 <= 3 || (unique >= 2 && !shared.isEmpty) else { continue }
                    let repeatRecording = recordings["\(row)|\(TrackDiscovery.trackKey(title))"]?.count ?? 1
                    let score = log(1 + Double(repeatRecording)) * 2 + overlapScore + log(1 + Double(repeatCount)) + Double(shared.count) * 1.5 + 3 / Double(max(1, nearest.0))
                    candidates.append(Candidate(slot: slot, identity: identity, cluster: cluster, score: score,
                                                nearest: nearest.1, distance: nearest.0, repeats: repeatCount, sharedStyles: shared, recordingEpisodes: repeatRecording))
                }
            }
        }
        return (candidates.sorted { $0.score == $1.score ? ($0.identity.id, $0.slot.raw_track_title ?? "") < ($1.identity.id, $1.slot.raw_track_title ?? "") : $0.score > $1.score }, programmes)
    }

    func discover(_ inputs: Inputs, progress: @escaping @Sendable ([RadioDiscoverPick]) async -> Void = { _ in }) async throws -> Result {
        let beforeReads = await source.catalogueReads()
        let rows = try await source.rows(Array(Set(inputs.seeds.map(\.id))))
        var seedSlots: [Slot] = []
        // A bounded batch per cluster avoids a prolific artist crowding all
        // other tastes out of a single capped database response.
        for cluster in inputs.labels.keys.sorted() {
            try Task.checkCancellation()
            let ids = Set(inputs.seeds.filter { $0.cluster == cluster }.flatMap { rows[$0.id] ?? [] })
            guard !ids.isEmpty else { continue }
            seedSlots += try await source.seedAppearances(Array(ids))
        }
        // Fair episode allocation, without ranking the existing artist mix.
        var episodes: [UUID] = []
        for cluster in inputs.labels.keys.sorted() {
            try Task.checkCancellation()
            let ids = Set(inputs.seeds.filter { $0.cluster == cluster }.flatMap { rows[$0.id] ?? [] })
            let list = seedSlots.filter { $0.artist_id.map(ids.contains) ?? false }
                .sorted { ($0.radio_episodes?.aired_at ?? .distantPast) > ($1.radio_episodes?.aired_at ?? .distantPast) }
            var seen = Set<UUID>()
            for slot in list where seen.count < 6 {
                if let id = slot.radio_episodes?.id, seen.insert(id).inserted, !episodes.contains(id) { episodes.append(id) }
            }
        }
        let slots = try await source.tracklists(Array(episodes.prefix(36)))
        let artistRows = Array(Set(slots.compactMap(\.artist_id)))
        let identities = try await source.identities(artistRows)
        let (ranked, programmes) = Self.rank(inputs: inputs, rows: rows, slots: slots, identities: identities)
        // Round-robin clusters, then their strongest still-unheard recordings.
        var queues = Dictionary(grouping: ranked, by: \.cluster)
        var picks: [RadioDiscoverPick] = [], used = Set<Int>(), checked = 0, perProgramme: [String: Int] = [:]
        var directLookups = 0
        while picks.count < 8, checked < 28, queues.values.contains(where: { !$0.isEmpty }) {
            for cluster in inputs.labels.keys.sorted() where picks.count < 8 && checked < 28 {
                guard var queue = queues[cluster], !queue.isEmpty else { continue }
                try Task.checkCancellation()
                let candidate = queue.removeFirst(); queues[cluster] = queue
                let slot = candidate.slot
                guard let episode = slot.radio_episodes, let row = slot.artist_id, let title = slot.raw_track_title,
                      !used.contains(candidate.identity.id), perProgramme[episode.programmeKey, default: 0] < 2 else { continue }
                var direct: TrackDiscovery.Appearance?
                if let address = slot.media_url, let url = URL(string: address), YouTubeLink.isYouTube(url),
                   TrackDiscovery.isTrackUpload(title: title, artist: candidate.identity.name) {
                    direct = .init(artistDiscogsID: candidate.identity.id, artist: candidate.identity.name, title: title,
                                   source: .recording(url, channel: episode.programme), artworkURL: DiscoveredTrack.thumbnail(for: url), genres: [])
                } else if directLookups < 3 {
                    directLookups += 1
                    if let found = await source.recording(candidate.identity.id, candidate.identity.name, title),
                       found.artistDiscogsID == candidate.identity.id,
                       TrackDiscovery.trackKey(found.title) == TrackDiscovery.trackKey(title) { direct = found }
                }
                var playable: DiscoveredTrack.Source?, art = episode.image_url.flatMap(URL.init(string:))
                var timing = RadioDiscoverPick.Timing.directRecording
                if let direct {
                    checked += 1
                    if await source.plays(direct.source) == true { playable = direct.source; art = direct.artworkURL }
                }
                if playable == nil, let at = slot.offset_seconds, at >= 0,
                   (at > 0 || slot.track_index == 0),
                   episode.duration_seconds.map({ at < $0 }) ?? true,
                   let provider = RadioListenFinder.appProvider(episode.provider),
                   let address = episode.archive_url, let url = URL(string: address) {
                    let listen = RadioListen(provider: provider, episode: episode.external_id, episodeTitle: episode.title ?? episode.programme,
                                             showTitle: episode.programme, airedAt: episode.aired_at, played: title, offsetSeconds: at, archiveURL: url)
                    let proposed = DiscoveredTrack.Source.episode(listen, at: at)
                    checked += 1
                    if await source.plays(proposed) == true {
                        playable = proposed
                        timing = episode.provider == "nts" ? .publisherEstimated : .publisherReported
                    }
                }
                guard let playable else { continue }
                used.insert(candidate.identity.id); perProgramme[episode.programmeKey, default: 0] += 1
                let distance = candidate.distance == 1 ? "next to" : "within \(candidate.distance) tracks of"
                var reason = "\(episode.programme) played this \(distance) \(candidate.nearest)."
                if candidate.recordingEpisodes > 1 { reason += " This recording appears in \(candidate.recordingEpisodes) matched broadcasts." }
                if candidate.repeats > 1 { reason += " This programme features your cluster's artists in \(candidate.repeats) matched episodes." }
                if !candidate.sharedStyles.isEmpty { reason += " Its artist's own catalogue shares \(candidate.sharedStyles.joined(separator: ", ")) with this cluster." }
                let track = DiscoveredTrack(artist: candidate.identity.name, artistDiscogsID: candidate.identity.id, title: title,
                                           source: playable, artworkURL: art, release: direct?.release, year: direct?.year,
                                           releaseDiscogsID: direct?.releaseDiscogsID, knownArtist: false, tags: candidate.sharedStyles,
                                           reason: reason, via: episode.programme, playable: .yes, score: candidate.score)
                picks.append(RadioDiscoverPick(track: track, artistRow: row, cluster: cluster, clusterLabel: inputs.labels[cluster] ?? "",
                                              programme: episode.programme, episode: episode.title ?? episode.programme,
                                              curator: episode.radio_shows?.host_name, timing: timing, supportEpisodes: candidate.repeats,
                                              nearest: candidate.nearest, distance: candidate.distance, styles: candidate.sharedStyles))
                await progress(picks)
            }
        }
        return Result(key: inputs.key, at: Date(), picks: picks, programmes: programmes, requests: await source.catalogueReads() - beforeReads, checked: checked)
    }
}
