//
//  BackendKnowledge.swift
//  Indigo
//
//  For You's knowledge from Indigo's backend, in shadow.
//
//  The visible For You is ranked from this device's own caches
//  (`LocalKnowledgeAdapter`). This builds the same snapshot from the backend's
//  `explore_knowledge` instead, ranks it with the same pure ranker, and
//  compares the two -- without showing it. What the comparison says (which
//  starting points the backend knows, which kinds of route it lacks, how much
//  of the top twenty survives) is what decides when it can be trusted.
//
//  Answers are kept by entity and by the backend's edge generation, never by
//  who asked: a starting point's neighbourhood is the same for anybody who
//  starts there, and an artist's broadcasts the same for anybody who keeps
//  them. A play that does not change the starting points asks for nothing.
//  Kept on disk, so a device offline ranks from what it last had -- and says
//  how old that is.
//
//  Nothing here ever fills a gap from this device's caches. A starting point
//  the backend does not know is a starting point with no neighbourhood, and
//  the diagnostics say so. The device-local part (the library) is the visible
//  ranking's own, carried over unchanged and digested separately.
//

import Foundation
import Supabase

// MARK: - What the backend answers

nonisolated struct BackendKnowledgeResponse: Decodable, Sendable {
    let format: Int
    let asOf: String
    let generation: String
    let nextGenerationAt: String
    let nodes: [String: BackendNodeAnswer]
    let artists: [String: BackendArtistAnswer]
}

nonisolated struct BackendNodeAnswer: Codable, Sendable, Equatable {
    /// `found`, `unknown` (the backend has no such entity) or `unsupported`
    /// (a kind it does not walk, such as a station).
    let status: String
    let edges: [BackendEdge]
}

nonisolated struct BackendEdge: Codable, Sendable, Equatable {
    let kind: String
    let reason: String
    let confidence: Double
    let occurrences: Int
    let to: BackendTarget
}

nonisolated struct BackendTarget: Codable, Sendable, Equatable {
    let kind: String
    let name: String
    let discogsID: String?
    let year: Int?
    let providerID: String?
    let handle: String?
}

nonisolated struct BackendArtistAnswer: Codable, Sendable, Equatable {
    let status: String
    let episodes: [BackendEpisode]
    let rosters: [BackendRoster]
    let genres: [String]
}

nonisolated struct BackendEpisode: Codable, Sendable, Equatable {
    let providerID: String
    let showID: String
    let title: String
    let image: String?
    let genres: [String]
}

nonisolated struct BackendRoster: Codable, Sendable, Equatable {
    let place: String
    let sound: String?
    let members: Int?
}

// MARK: - Kept by entity

/// Every answer this device has had, by entity, with the generation it came
/// from. An answer from an older generation is stale: still used, and said to
/// be, until a newer one arrives.
nonisolated struct BackendKnowledgeCache: Codable, Sendable, Equatable {
    struct Kept<Answer: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
        var answer: Answer
        var generation: String
        var fetchedAt: Date
    }

    var nodes: [String: Kept<BackendNodeAnswer>] = [:]
    var artists: [String: Kept<BackendArtistAnswer>] = [:]

    /// The edge rebuild runs at 23 minutes past every third hour (UTC). Its
    /// slot is the generation an answer is current for; the backend names it
    /// the same way (0072).
    static func generation(at moment: Date) -> String {
        "edges-\(Int(((moment.timeIntervalSince1970 - 23 * 60) / 10_800).rounded(.down)))"
    }

    static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("explore-backend-knowledge.json")
    }

    static func load(from url: URL?) -> BackendKnowledgeCache {
        guard let url, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(BackendKnowledgeCache.self, from: data) else { return .init() }
        return cache
    }

    func save(to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Asking

/// What one round of asking did.
nonisolated struct BackendFetchReport: Codable, Sendable, Equatable {
    var calls = 0
    var bytes = 0
    var milliseconds: [Double] = []
    var errors: [String] = []
    var nodesAsked = 0
    var artistsAsked = 0
    var nodesKept = 0
    var artistsKept = 0
    var generation = ""
    var nextGenerationAt = ""
}

nonisolated enum BackendKnowledgeFetcher {
    /// The function's bounds (0072). A larger ask is split; every answer is
    /// about one entity, so splitting changes nothing about what is answered.
    static let nodesPerCall = 12
    static let artistsPerCall = 50

    struct Params: Encodable, Sendable {
        struct Node: Encodable, Sendable {
            let id: String
            let kind: String
            let key: String
            let provider: String
            let handle: String
        }
        let pNodes: [Node]
        let pArtists: [String]
        enum CodingKeys: String, CodingKey {
            case pNodes = "p_nodes"
            case pArtists = "p_artists"
        }
    }

    /// One call: the raw body, so its size can be reported.
    typealias Call = @Sendable (Params) async throws -> Data

    @Sendable static func live(_ params: Params) async throws -> Data {
        try await SupabaseService.requireClient()
            .rpc("explore_knowledge", params: params)
            .execute()
            .data
    }

    /// Asks for whatever is missing or stale, in bounded calls, and keeps
    /// every answer that arrives. A call that fails leaves its entities as
    /// they were -- stale, or missing -- and says why.
    static func refresh(
        _ cache: inout BackendKnowledgeCache, nodes: [MusicNode], artists: [String],
        now: Date, call: Call = live
    ) async -> BackendFetchReport {
        var report = BackendFetchReport()
        let current = BackendKnowledgeCache.generation(at: now)
        let wantedNodes = nodes.filter { cache.nodes[$0.id]?.generation != current }
        let wantedArtists = Array(Set(artists.filter { !$0.isEmpty && cache.artists[$0]?.generation != current })).sorted()
        report.nodesKept = nodes.count - wantedNodes.count
        report.artistsKept = Set(artists).count - wantedArtists.count
        report.nodesAsked = wantedNodes.count
        report.artistsAsked = wantedArtists.count

        let nodeBatches = stride(from: 0, to: wantedNodes.count, by: nodesPerCall)
            .map { Array(wantedNodes[$0..<min($0 + nodesPerCall, wantedNodes.count)]) }
        let artistBatches = stride(from: 0, to: wantedArtists.count, by: artistsPerCall)
            .map { Array(wantedArtists[$0..<min($0 + artistsPerCall, wantedArtists.count)]) }
        for index in 0..<max(nodeBatches.count, artistBatches.count) {
            let batchNodes = index < nodeBatches.count ? nodeBatches[index] : []
            let batchArtists = index < artistBatches.count ? artistBatches[index] : []
            let params = Params(
                pNodes: batchNodes.map {
                    Params.Node(id: $0.id, kind: $0.kind.rawValue, key: $0.key,
                                provider: $0.providerID ?? "", handle: $0.handle ?? "")
                },
                pArtists: batchArtists
            )
            let started = ContinuousClock.now
            do {
                let data = try await call(params)
                let spent = ContinuousClock.now - started
                report.calls += 1
                report.bytes += data.count
                report.milliseconds.append(Double(spent.components.seconds) * 1_000 + Double(spent.components.attoseconds) / 1e15)
                let response = try JSONDecoder().decode(BackendKnowledgeResponse.self, from: data)
                report.generation = response.generation
                report.nextGenerationAt = response.nextGenerationAt
                for node in batchNodes {
                    guard let answer = response.nodes[node.id] else { continue }
                    cache.nodes[node.id] = .init(answer: answer, generation: response.generation, fetchedAt: now)
                }
                for key in batchArtists {
                    guard let answer = response.artists[key] else { continue }
                    cache.artists[key] = .init(answer: answer, generation: response.generation, fetchedAt: now)
                }
            } catch {
                report.calls += 1
                report.errors.append(String(describing: error).prefix(160).description)
            }
        }
        return report
    }
}

// MARK: - The snapshot it makes

/// How much of what For You needs the backend could say.
nonisolated struct BackendCoverage: Codable, Sendable, Equatable {
    /// Starting point id to `found`, `unknown`, `unsupported`, `missing` (never
    /// answered) -- with `stale` added when the answer is from an older
    /// generation.
    var startingPoints: [String: String] = [:]
    var artistsFound = 0
    var artistsUnknown = 0
    var artistsMissing = 0
    var staleAnswers = 0
    /// When the oldest answer used was fetched.
    var oldestFetch: Date?
}

nonisolated enum BackendKnowledgeAdapter {
    /// The artists whose answers For You reads: everybody kept (shows), every
    /// foothold (scenes, including the library's, which is this device's own
    /// knowledge about which artists matter) and every artist the crate says
    /// something about the taste of.
    static func artistsWanted(_ personal: PersonalInputs, deviceLocal: DeviceLocalKnowledge) -> [String] {
        var keys = Set(keptArtists(personal).keys)
        keys.formUnion(personal.crate.compactMap(\.sceneArtistKey))
        keys.formUnion(personal.artistPlays.keys)
        keys.formUnion(deviceLocal.libraryCounts.keys)
        keys.formUnion(personal.tasteArtistKeys)
        return keys.filter { !$0.isEmpty }.sorted()
    }

    /// Kept artists, by key, with the spelling the listener's rows give them.
    static func keptArtists(_ personal: PersonalInputs) -> [String: String] {
        var found: [String: String] = [:]
        for entry in ExploreRanker.knownGround(personal) where entry.node.kind == .artist {
            found[entry.node.key] = found[entry.node.key].map { min($0, entry.node.title) } ?? entry.node.title
        }
        return found
    }

    /// The backend's snapshot for these rows: the shared part from its
    /// answers, the device-local part carried over from this device's as it
    /// is, so the two stay separately digestible.
    static func snapshot(
        personal: PersonalInputs, deviceLocal: DeviceLocalKnowledge,
        cache: BackendKnowledgeCache, now: Date
    ) -> (KnowledgeSnapshot, BackendCoverage) {
        let current = BackendKnowledgeCache.generation(at: now)
        var coverage = BackendCoverage()
        func noteFetch(_ date: Date, _ generation: String) {
            coverage.oldestFetch = min(coverage.oldestFetch ?? date, date)
            if generation != current { coverage.staleAnswers += 1 }
        }

        let origins = ExploreRanker.startingPoints(personal)
        var walked: [MusicNode: LocalKnowledgeAdapter.Walked] = [:]
        for origin in origins {
            guard let kept = cache.nodes[origin.id] else {
                coverage.startingPoints[origin.id] = "missing"
                walked[origin] = .init(shared: [], deviceLocal: [])
                continue
            }
            noteFetch(kept.fetchedAt, kept.generation)
            coverage.startingPoints[origin.id] = kept.answer.status + (kept.generation == current ? "" : ", stale")
            var set = EdgeSet()
            for found in kept.answer.edges {
                if let edge = edge(found, from: origin) { set.insert(edge) }
            }
            walked[origin] = .init(shared: set.all, deviceLocal: [])
        }

        let kept = keptArtists(personal)
        var shows: [String: ShowProfile] = [:]
        var tags: [String: [String]] = [:]
        var rosters: [(key: String, roster: BackendRoster)] = []
        for key in artistsWanted(personal, deviceLocal: deviceLocal) {
            guard let entry = cache.artists[key] else { coverage.artistsMissing += 1; continue }
            noteFetch(entry.fetchedAt, entry.generation)
            if entry.answer.status == "found" { coverage.artistsFound += 1 } else { coverage.artistsUnknown += 1 }
            if let name = kept[key] {
                for episode in entry.answer.episodes {
                    let node = MusicNode.broadcast(providerID: episode.providerID, showID: episode.showID, title: episode.title)
                    var profile = shows[node.id] ?? ShowProfile(
                        providerID: episode.providerID, showID: episode.showID, title: episode.title,
                        artworkURL: episode.image.flatMap(URL.init(string:)), artists: [], tags: []
                    )
                    profile.artists = Array(Set(profile.artists + [name])).sorted()
                    profile.tags = Array(Set(profile.tags + ListeningLog.foldTags(episode.genres))).sorted()
                    shows[node.id] = profile
                }
            }
            if personal.tasteArtistKeys.contains(key) {
                let folded = ListeningLog.foldTags(entry.answer.genres)
                if !folded.isEmpty { tags[key] = folded }
            }
            for roster in entry.answer.rosters { rosters.append((key, roster)) }
        }

        var snapshot = LocalKnowledgeAdapter.assemble(
            origins: origins, walked: walked, shows: Array(shows.values), artistTags: tags,
            scenes: catalogue(rosters), libraryCounts: [:]
        )
        snapshot.deviceLocal = deviceLocal
        return (snapshot, coverage)
    }

    /// One backend edge as the app would have drawn it, cleaned by the app's
    /// own rules -- the backend cleans too, but the app is the authority.
    static func edge(_ found: BackendEdge, from origin: MusicNode) -> MusicEdge? {
        guard let kind = RelationshipKind(rawValue: found.kind), let target = node(found.to, from: origin)
        else { return nil }
        let source: RelationshipSource = [.playedInShow, .frequentlyPlayedNearby, .sharedBroadcast].contains(kind)
            ? .radio : .discogs
        return MusicEdge(from: origin, to: target, kind: kind, source: source, reason: found.reason,
                         confidence: found.confidence, occurrences: found.occurrences)
    }

    static func node(_ target: BackendTarget, from origin: MusicNode) -> MusicNode? {
        switch target.kind {
        case "artist":
            let name = DiscogsClient.withoutDisambiguator(target.name)
            guard ArtistName.isRealArtist(name) else { return nil }
            return .artist(name)
        case "label":
            let name = DiscogsClient.withoutDisambiguator(target.name)
            guard LabelName.isRealLabel(name), !LabelName.isOwnName(name, artist: origin.title) else { return nil }
            return .label(name)
        case "release":
            return .release(target.name, discogsID: target.discogsID.flatMap(Int.init), year: target.year.map(String.init))
        case "broadcast":
            guard let provider = target.providerID, let handle = target.handle, !handle.isEmpty else { return nil }
            return .broadcast(providerID: provider, showID: handle, title: target.name)
        default:
            return nil
        }
    }

    /// Scenes from the rosters the listener's footholds are in. A roster is
    /// a place and a sound with a member count; who else is in it does not
    /// matter to the ranking, only how many and which footholds.
    static func catalogue(_ rosters: [(key: String, roster: BackendRoster)]) -> SceneCatalogue? {
        guard !rosters.isEmpty else { return nil }
        var byScene: [String: (place: String, sound: String?, members: Int, footholds: Set<String>)] = [:]
        for (key, roster) in rosters {
            let id = "\(RecordingKey.normalize(roster.place))|\(RecordingKey.normalize(roster.sound))"
            var entry = byScene[id] ?? (roster.place, roster.sound, roster.members ?? 0, [])
            entry.footholds.insert(key)
            entry.members = max(entry.members, roster.members ?? 0)
            byScene[id] = entry
        }
        let byCity = Dictionary(grouping: byScene.values) { RecordingKey.normalize($0.place) }
        let cities = byCity.keys.sorted().compactMap { city -> SceneCity? in
            let scenes = (byCity[city] ?? [])
                .map { SceneCandidate(
                    city: $0.place, sound: $0.sound, eraLow: nil, eraHigh: nil,
                    members: $0.footholds.sorted(), artistCount: $0.members, labelCount: 0, radioAppearances: 0,
                    signature: $0.sound.map { [$0] } ?? [], tags: $0.sound.map { [$0] } ?? []
                ) }
                .filter { $0.artistCount >= SceneEngine.directionMinimum }
                .sorted { $0.id < $1.id }
            guard !scenes.isEmpty else { return nil }
            return SceneCity(key: city, members: Array(Set(scenes.flatMap(\.members))).sorted(), scenes: scenes)
        }
        return SceneCatalogue(cities: cities, creditMembers: [:])
    }
}

// MARK: - Comparing

/// The backend's ranking against the one on screen.
nonisolated struct ShadowComparison: Codable, Sendable, Equatable {
    struct Move: Codable, Sendable, Equatable {
        let id: String
        let title: String
        let visible: Int?
        let backend: Int?
    }
    struct Reworded: Codable, Sendable, Equatable {
        let id: String
        let visible: String
        let backend: String
    }

    var top12Overlap = 0
    var top20Overlap = 0
    /// Every recommendation in either top twenty, with its place in each.
    var moves: [Move] = []
    /// Kinds of route the visible top twenty rests on that the backend's
    /// snapshot does not have at all.
    var missingKinds: [String] = []
    /// The same recommendation, offered for a different reason.
    var reworded: [Reworded] = []
    var showsOverlap = 0
    var showsCount = 0
    var visibleDirection = "-"
    var backendDirection = "-"
    /// Each top twenty as "title — reason (kind ×corroboration)", for reading
    /// why the two differ.
    var visibleTop: [String] = []
    var backendTop: [String] = []

    static func compare(
        visible: (next: [ExploreSuggestion], all: [ExploreSuggestion], shows: [String], direction: String),
        backend: (next: [ExploreSuggestion], all: [ExploreSuggestion], shows: [String], direction: String),
        backendKnowledge: KnowledgeSnapshot
    ) -> ShadowComparison {
        var result = ShadowComparison()
        result.top12Overlap = Set(visible.next.prefix(12).map(\.id)).intersection(backend.next.prefix(12).map(\.id)).count
        result.top20Overlap = Set(visible.all.prefix(20).map(\.id)).intersection(backend.all.prefix(20).map(\.id)).count
        let visibleRank = Dictionary(visible.all.prefix(20).enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        let backendRank = Dictionary(backend.all.prefix(20).enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        let titles = Dictionary((visible.all + backend.all).map { ($0.id, $0.node.title) }, uniquingKeysWith: { a, _ in a })
        result.moves = Set(visibleRank.keys).union(backendRank.keys)
            .map { Move(id: $0, title: titles[$0] ?? $0, visible: visibleRank[$0], backend: backendRank[$0]) }
            .sorted { ($0.visible ?? 99, $0.backend ?? 99, $0.id) < ($1.visible ?? 99, $1.backend ?? 99, $1.id) }
        let backendKinds = Set(backendKnowledge.shared.neighbourhoods.flatMap(\.edges).map(\.kind.rawValue))
            .union(backendKnowledge.deviceLocal.neighbourhoods.flatMap(\.edges).map(\.kind.rawValue))
            .union(backendKnowledge.shared.shows.isEmpty ? [] : [RelationshipKind.playedInShow.rawValue])
        result.missingKinds = Set(visible.all.prefix(20).map(\.kind.rawValue)).subtracting(backendKinds).sorted()
        let backendByID = Dictionary(backend.all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        result.reworded = visible.all.prefix(20).compactMap { mine in
            guard let theirs = backendByID[mine.id], theirs.reason != mine.reason else { return nil }
            return Reworded(id: mine.id, visible: mine.reason, backend: theirs.reason)
        }
        result.showsOverlap = Set(visible.shows).intersection(backend.shows).count
        result.showsCount = max(visible.shows.count, backend.shows.count)
        result.visibleDirection = visible.direction
        result.backendDirection = backend.direction
        func line(_ s: ExploreSuggestion) -> String { "\(s.node.title) — \(s.reason) (\(s.kind.rawValue) ×\(s.corroboration))" }
        result.visibleTop = visible.all.prefix(20).map(line)
        result.backendTop = backend.all.prefix(20).map(line)
        return result
    }

    /// One ranking, in the shape `compare` takes.
    static func ranking(personal: PersonalInputs, knowledge: KnowledgeSnapshot, asOf: Date, turn: Int)
        -> (next: [ExploreSuggestion], all: [ExploreSuggestion], shows: [String], direction: String) {
        let taste = ExploreRanker.taste(personal: personal, knowledge: knowledge, asOf: asOf)
        let offers = ExploreRanker.recommendations(personal: personal, knowledge: knowledge, taste: taste)
        let all = ExploreRanker.suggestions(personal: personal, knowledge: knowledge, taste: taste, limit: 40)
        let direction = ExploreRanker.direction(personal: personal, knowledge: knowledge, taste: taste, turn: turn)
        return (offers.next, all, offers.shows.map(\.id), direction.map { "\($0.city) \($0.sound)" } ?? "-")
    }
}

/// Everything one shadow look found, for the diagnostics.
nonisolated struct ShadowReport: Codable, Sendable, Equatable {
    var source = "backend"
    var comparison = ShadowComparison()
    var coverage = BackendCoverage()
    var fetch = BackendFetchReport()
    var visibleShared = ""
    var backendShared = ""
    var deviceLocal = ""
    var at = Date.distantPast
}

/// Whether the shadow runs at all. On in debug builds, where its panel is;
/// off in release builds unless asked for with `-INDIGO_EXPLORE_SHADOW`, so a
/// listener's For You never makes calls only a developer reads. Never under
/// tests, which must not reach the network.
nonisolated enum ExploreShadow {
    static var isEnabled: Bool {
        guard !Persistence.isRunningTests, SupabaseService.isConfigured else { return false }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-INDIGO_EXPLORE_SHADOW_OFF") { return false }
        #if DEBUG
        return true
        #else
        return arguments.contains("-INDIGO_EXPLORE_SHADOW")
        #endif
    }
}
