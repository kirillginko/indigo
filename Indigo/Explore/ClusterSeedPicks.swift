//
//  ClusterSeedPicks.swift
//  Indigo
//
//  Listener Profile v2 in For You, behind a development switch: after For
//  You's own list, artists reached one step from every taste cluster --
//  credited on the seeds' own releases, or chosen by them for a mix or a
//  compilation -- each with a verified Discogs id and something of theirs
//  that is confirmed to play. Their own recordings first; a moment in an
//  archived show only when no recording is left.
//
//  Replayed in `ListenerExpansionReplay`: For You alone fills 22 of 80
//  playable slots over four dated cut-offs and reaches 4 later finds; with
//  these after it, 76 and 9, at lower fit to later listening.
//

import Foundation
import SwiftData

/// Development only: on with the switch in a Debug build, off everywhere
/// else, internal TestFlight builds included.
nonisolated enum ForYouClusterSeedsFeature {
    #if DEBUG
    static let switchKey = "INDIGO_FORYOU_CLUSTER_SEEDS"
    #endif
    nonisolated(unsafe) static var override: Bool?

    static var isEnabled: Bool {
        if let override { return override }
        #if DEBUG
        return UserDefaults.standard.bool(forKey: switchKey)
        #else
        return false
        #endif
    }
}

/// What working out the picks costs, kept: the picks themselves under the
/// fingerprint of what they were made from, each release document's credits,
/// and each artist's confirmed recording. On disk, in Caches: it can all be
/// worked out again, and none of it is the listener's.
actor ClusterSeedStore {
    struct Heard: Codable, Sendable {
        var title: String
        var source: DiscoveredTrack.Source
        var artworkURL: URL?
        var release: String?
        var year: Int?
        var releaseDiscogsID: Int?
        var at: Date
    }
    struct Disk: Codable {
        var key: String?
        var picks: [DiscoveredTrack] = []
        var at: Date?
        var credits: [String: [ListenerRetrieval.Credit]] = [:]
        /// By Discogs id; nil when nothing of theirs played when asked.
        var heard: [String: Heard?] = [:]
        var heardAt: [String: Date] = [:]
    }

    static let shared = ClusterSeedStore(file: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("cluster-seed-picks.json"))

    private let file: URL?
    private var disk = Disk()
    private var loaded = false
    /// A pick list is reused while what it was made from is unchanged, for a day.
    static let picksLifetime: TimeInterval = 24 * 3600
    /// Whether something plays is asked again after a week.
    static let heardLifetime: TimeInterval = 7 * 24 * 3600

    init(file: URL?) { self.file = file }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let file, let data = try? Data(contentsOf: file), let found = try? JSONDecoder().decode(Disk.self, from: data) { disk = found }
    }
    private func save() {
        guard let file, let data = try? JSONEncoder().encode(disk) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func picks(for key: String, now: Date = Date()) -> [DiscoveredTrack]? {
        load()
        guard disk.key == key, let at = disk.at, now.timeIntervalSince(at) < Self.picksLifetime else { return nil }
        return disk.picks
    }
    func keep(picks: [DiscoveredTrack], for key: String, now: Date = Date()) {
        load(); disk.key = key; disk.picks = picks; disk.at = now; save()
    }
    func credits(release id: Int) -> [ListenerRetrieval.Credit]? { load(); return disk.credits[String(id)] }
    func keep(credits: [ListenerRetrieval.Credit], release id: Int) { load(); disk.credits[String(id)] = credits }
    /// `.some(nil)`: asked recently, nothing played.
    func heard(_ id: Int, now: Date = Date()) -> Heard?? {
        load()
        guard let at = disk.heardAt[String(id)], now.timeIntervalSince(at) < Self.heardLifetime else { return nil }
        return .some(disk.heard[String(id)] ?? nil)
    }
    func keep(heard: Heard?, for id: Int, now: Date = Date()) {
        load(); disk.heard[String(id)] = .some(heard); disk.heardAt[String(id)] = now
    }
    func flush() { save() }
}

nonisolated struct ClusterSeedPicks: Sendable {
    /// What the listener's rows and the device's entries say, read once.
    struct Inputs: Sendable {
        var profile: ListenerProfile
        var vectors: [String: [String: Double]]
        var seeds: [ListenerRetrieval.Seed]
        var entries: [String: ListenerRetrieval.Entry]
        var releaseIDs: [String: (seed: Int, releases: [Int])]
        var book: ListenerRetrieval.StyleBook
        /// Everyone the listener has met, by folded name, and the people
        /// those names are (`sameArtist`).
        var known: Set<String>
    }

    var release: @Sendable (Int) async -> DiscogsReleaseDetail? = ReleaseVideoTracks.live.release
    var videos: ReleaseVideoTracks = .live
    var rows: @Sendable ([Int]) async throws -> [Int: [UUID]] = RadioListenFinder.live.rows
    var appearances: @Sendable ([UUID]) async throws -> [TrackDiscoverySource.Row] = TrackDiscoverySource.live.appearances
    var plays: @Sendable (DiscoveredTrack.Source) async -> Bool? = TrackDiscoverySource.live.plays

    var store: ClusterSeedStore? = .shared
    /// The seeds' R2 artist bundles: read through their own cache file, so
    /// the backend shadow's is never written from here. Nil reads none.
    var bundles: (@Sendable ([Int]) async -> [Int: ArtistBundle])? = ClusterSeedPicks.liveBundles

    static let liveBundles: @Sendable ([Int]) async -> [Int: ArtistBundle] = { ids in
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("cluster-seed-bundles.json")
        var cache = BundleCache.load(from: file)
        _ = await BundleFetcher.refresh(&cache, discogsIDs: ids, now: Date())
        cache.save(to: file)
        var out: [Int: ArtistBundle] = [:]
        for id in ids { if let digest = cache.refs[String(id)]?.ref?.digest, let bundle = cache.bundles[digest] { out[id] = bundle } }
        return out
    }

    static let live = ClusterSeedPicks()
    /// Raised whenever the picking changes, so kept picks are not reused.
    static let version = 4

    /// What the picks are made from, in a line: the synced history (events,
    /// crate, DIG pages) and the style caches (entries, records), each by
    /// count and newest. Cheap: counts and one row each.
    static func fingerprint(context: ModelContext) -> String {
        func count<T: PersistentModel>(_ type: T.Type) -> Int { (try? context.fetchCount(FetchDescriptor<T>())) ?? -1 }
        func newest<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, _ date: (T) -> Date) -> String {
            var d = descriptor; d.fetchLimit = 1
            return ((try? context.fetch(d))?.first).map { String(Int(date($0).timeIntervalSinceReferenceDate)) } ?? "-"
        }
        let parts = [
            // How the picks are worked out: a new way, new picks.
            "v\(Self.version)",
            "e\(count(ListeningEvent.self)):" + newest(FetchDescriptor<ListeningEvent>(sortBy: [SortDescriptor(\.at, order: .reverse)]), \.at),
            "c\(count(CrateItem.self)):" + newest(FetchDescriptor<CrateItem>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)]), \.addedAt),
            "v\(count(DigVisit.self)):" + newest(FetchDescriptor<DigVisit>(sortBy: [SortDescriptor(\.lastVisitedAt, order: .reverse)]), \.lastVisitedAt),
            "a\(count(DiscogsArtist.self)):" + newest(FetchDescriptor<DiscogsArtist>(sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]), \.fetchedAt),
            "r\(count(DiscogsReleaseRecord.self))",
        ]
        return parts.joined(separator: "|")
    }

    /// Reads the store: a few seconds, so never on the main thread.
    static func inputs(context: ModelContext, vectors given: [String: [String: Double]], now: Date = Date()) -> Inputs? {
        // Each table read once, and shared with the profile's own read.
        let releaseRows = (try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? []
        let rows = (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? []
        let vectors = given.isEmpty ? RecordSimilarity(pool: releaseRows.map(RecordProfile.init(record:))).vectors : given
        let read = ListenerProfile.read(context: context, records: releaseRows, artists: rows)
        let profile = ListenerProfile.build(evidence: read.evidence, styles: read.styles, artistStyles: read.artistStyles,
                                            vectors: vectors, asOf: now)
        guard !profile.clusters.isEmpty else { return nil }
        let seeds = ListenerRetrieval.seeds(profile, vectors: vectors)
        let byKey = Dictionary(rows.map { ($0.nameKey, $0) }, uniquingKeysWith: { a, _ in a })
        var entries: [String: ListenerRetrieval.Entry] = [:]
        var releaseIDs: [String: (seed: Int, releases: [Int])] = [:]
        for seed in seeds {
            guard let row = byKey[seed.artist] else { continue }
            entries[seed.artist] = .init(key: row.nameKey, name: row.name, collaborators: row.collaboratorNames, members: row.memberNames,
                                         groups: row.groupNames, labelNeighbours: row.labelNeighbourNames,
                                         styleNeighbours: row.styleNeighbourNames, aliases: row.aliasNames)
            if row.discogsID > 0 { releaseIDs[seed.artist] = (row.discogsID, Array(row.releaseDiscogsIDs.prefix(6))) }
        }
        // As `RecordProfile(record:)` reads a record: folded styles, and the
        // headline artists by name (a device record carries no artist ids).
        let records = releaseRows.map { record -> (id: Int, keys: Set<String>, ids: Set<Int>, styles: [String]) in
            var seen = Set<String>()
            let styles = record.styles.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
            return (record.discogsID, Set(record.artistNames.map { RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator($0)) }), [], styles)
        }
        let book = ListenerRetrieval.StyleBook(entries: rows.map { (key: $0.nameKey, id: $0.discogsID, styles: $0.styles) },
                                               recordParts: records, vectors: vectors)
        var known = Set(read.evidence.map(\.artist))
        let people = Set(read.evidence.compactMap { read.sameArtist[$0.artist] })
        known.formUnion(read.sameArtist.filter { people.contains($0.value) }.keys)
        known.formUnion(PersonalInputs.read(context: context, asOf: now).tasteArtistKeys)
        return Inputs(profile: profile, vectors: vectors, seeds: seeds, entries: entries, releaseIDs: releaseIDs, book: book, known: known)
    }

    /// The candidates, ranked: verified ids only, styled through identity,
    /// by relevance and how strongly they were reached, slots by cluster.
    static func ranked(_ inputs: Inputs, credits: [String: [ListenerRetrieval.Credit]], excluding: Set<String>,
                       bundles: [String: (id: Int, bundle: ArtistBundle)] = [:], limit: Int = 40) -> [ListenerRetrieval.Candidate] {
        let sightings = ListenerRetrieval.direct(inputs.seeds, entries: inputs.entries, records: [], credits: credits)
            + ListenerRetrieval.bundled(inputs.seeds, bundles: bundles, names: inputs.entries.mapValues(\.name))
        var candidates = ListenerRetrieval.merge(sightings).candidates.filter { c in
            c.identity.hasPrefix("discogs:")
                && !inputs.known.contains(c.nameKey) && !c.aliases.contains(where: inputs.known.contains)
                && !excluding.contains(c.nameKey) && !c.aliases.contains(where: excluding.contains)
        }
        for i in candidates.indices { ListenerRetrieval.style(&candidates[i], book: inputs.book) }
        let evidence = ListenerRetrieval.evidence(candidates)
        let scorer = ListenerProfile.Scorer(inputs.profile, vectors: inputs.vectors)
        var scores: [String: Double] = [:]
        // Fit where there is a style to judge; below every styled one, the
        // unstyled by how strongly they were reached -- never by their id.
        for c in candidates {
            let reached = evidence[c.identity] ?? 0
            scores[c.identity] = (scorer.relevance(c.styles)?.score ?? 0) * (0.5 + reached) + 0.001 * reached
        }
        let sorted = candidates.sorted { (scores[$0.identity] ?? 0) != (scores[$1.identity] ?? 0) ? (scores[$0.identity] ?? 0) > (scores[$1.identity] ?? 0) : $0.identity < $1.identity }
        return inputs.profile.spread(sorted, limit: limit) { scorer.relevance($0.styles)?.cluster }
    }

    /// Up to `limit` tracks to hear, each confirmed to play: recordings of
    /// the artists' own first, in rank order, then moments in archived shows.
    func picks(_ inputs: Inputs, excluding: Set<String>, limit: Int = 8) async -> [DiscoveredTrack] {
        // The seeds' own releases: credits kept per document, the rest read
        // together.
        var byRelease: [Int: [ListenerRetrieval.Credit]] = [:]
        var missing: [Int] = []
        for (_, held) in inputs.releaseIDs { for id in held.releases {
            if byRelease[id] != nil { continue }
            if let kept = await store?.credits(release: id) { byRelease[id] = kept } else { missing.append(id) }
        } }
        let documents = await withTaskGroup(of: (Int, DiscogsReleaseDetail?).self) { group in
            var pending = Set(missing).sorted().makeIterator()
            for _ in 0..<8 { if let id = pending.next() { group.addTask { (id, await release(id)) } } }
            var found: [Int: DiscogsReleaseDetail] = [:]
            while let (id, detail) = await group.next() {
                if let detail { found[id] = detail }
                if let next = pending.next() { group.addTask { (next, await release(next)) } }
            }
            return found
        }
        var credits: [String: [ListenerRetrieval.Credit]] = [:]
        for (artist, held) in inputs.releaseIDs {
            var all: [ListenerRetrieval.Credit] = []
            for id in held.releases {
                if let kept = byRelease[id] { all += kept; continue }
                guard let document = documents[id] else { continue }
                // Per document and without the seed's id, so it keeps for
                // whichever seed reads it; the seed is taken out below.
                let found = ListenerRetrieval.credits(seedID: nil, releases: [document])
                byRelease[id] = found
                await store?.keep(credits: found, release: id)
                all += found
            }
            // Read per document, a record's own artist is a credit on it;
            // the seed is not one of its own.
            credits[artist] = all.filter { $0.id != held.seed }
        }
        var held: [String: (id: Int, bundle: ArtistBundle)] = [:]
        if let bundles {
            let found = await bundles(inputs.releaseIDs.values.map(\.seed).sorted())
            for (artist, ids) in inputs.releaseIDs { if let bundle = found[ids.seed] { held[artist] = (ids.seed, bundle) } }
        }
        let ranked = Self.ranked(inputs, credits: credits, excluding: excluding, bundles: held)
        // No taste cluster takes more than its share of the picks while
        // another still has something to offer.
        let clusterCount = max(1, Set(ranked.map(\.best.cluster)).count)
        let perCluster = max(2, Int((Double(limit) / Double(clusterCount)).rounded(.up)))
        var fromCluster: [Int: Int] = [:]
        let seedNames = Dictionary(inputs.seeds.map { ($0.artist, (inputs.entries[$0.artist]?.name ?? $0.name, inputs.releaseIDs[$0.artist]?.seed)) },
                                   uniquingKeysWith: { a, _ in a })

        var recordings: [DiscoveredTrack] = [], moments: [DiscoveredTrack] = []
        // First each cluster up to its share; then, if slots are left because
        // a cluster had nothing that plays, the rest in rank order.
        var looked = Set<String>()
        for capped in [true, false] where recordings.count < limit {
        for candidate in ranked where recordings.count < limit {
            guard let id = Int(candidate.identity.dropFirst("discogs:".count)), !looked.contains(candidate.identity) else { continue }
            if capped, fromCluster[candidate.best.cluster, default: 0] >= perCluster { continue }
            looked.insert(candidate.identity)
            let countedBefore = recordings.count + moments.count
            defer { if recordings.count + moments.count > countedBefore { fromCluster[candidate.best.cluster, default: 0] += 1 } }
            let (via, viaID) = seedNames[candidate.best.seed] ?? (candidate.best.seed, nil)
            func track(_ appearance: TrackDiscovery.Appearance) -> DiscoveredTrack {
                DiscoveredTrack(artist: candidate.name, artistDiscogsID: id, title: appearance.title, source: appearance.source,
                                artworkURL: appearance.artworkURL, release: appearance.release, year: appearance.year,
                                releaseDiscogsID: appearance.releaseDiscogsID,
                                tags: candidate.styles.isEmpty ? nil : candidate.styles, reason: candidate.best.why,
                                via: via, viaDiscogsID: viaID, playable: .yes, score: 0)
            }
            func kept(_ h: ClusterSeedStore.Heard) -> TrackDiscovery.Appearance {
                .init(artistDiscogsID: id, artist: candidate.name, title: h.title, source: h.source, artworkURL: h.artworkURL, genres: [],
                      release: h.release, year: h.year, releaseDiscogsID: h.releaseDiscogsID)
            }
            func keep(_ a: TrackDiscovery.Appearance?) async {
                await store?.keep(heard: a.map { .init(title: $0.title, source: $0.source, artworkURL: $0.artworkURL, release: $0.release,
                                                       year: $0.year, releaseDiscogsID: $0.releaseDiscogsID, at: Date()) }, for: id)
            }
            if let asked = await store?.heard(id) {
                guard let h = asked else { continue }
                let appearance = kept(h)
                if case .recording = appearance.source { recordings.append(track(appearance)) } else if moments.count < limit { moments.append(track(appearance)) }
                continue
            }
            var heard: DiscoveredTrack?
            for appearance in await videos.tracks(artistID: id, artist: candidate.name) {
                if await plays(appearance.source) == true { heard = track(appearance); await keep(appearance); break }
            }
            if let heard { recordings.append(heard); continue }
            // Radio: a linked recording, else the moment in the show.
            let found = ((try? await rows([id]))?[id]).map { $0 } ?? []
            guard !found.isEmpty, let lines = try? await appearances(found) else { await keep(nil); continue }
            var report = TrackDiscoverySource.Report()
            let radio = lines.compactMap { TrackDiscovery.appearance(from: $0, artistID: id, artist: candidate.name, report: &report) }
            func isRecording(_ a: TrackDiscovery.Appearance) -> Bool { if case .recording = a.source { true } else { false } }
            var played: TrackDiscovery.Appearance?
            for appearance in (radio.filter(isRecording) + radio.filter { !isRecording($0) }).prefix(4) {
                guard await plays(appearance.source) == true else { continue }
                played = appearance
                if isRecording(appearance) { recordings.append(track(appearance)) } else if moments.count < limit { moments.append(track(appearance)) }
                break
            }
            await keep(played)
        }
        }
        await store?.flush()
        return Array((recordings + moments).prefix(limit))
    }
}
