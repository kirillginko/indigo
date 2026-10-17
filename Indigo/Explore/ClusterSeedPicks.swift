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

    static let live = ClusterSeedPicks()

    /// Reads the store: a few seconds, so never on the main thread.
    static func inputs(context: ModelContext, vectors given: [String: [String: Double]], now: Date = Date()) -> Inputs? {
        let records = ((try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? []).map(RecordProfile.init(record:))
        let vectors = given.isEmpty ? RecordSimilarity(pool: records).vectors : given
        let read = ListenerProfile.read(context: context)
        let profile = ListenerProfile.build(evidence: read.evidence, styles: read.styles, artistStyles: read.artistStyles,
                                            vectors: vectors, asOf: now)
        guard !profile.clusters.isEmpty else { return nil }
        let seeds = ListenerRetrieval.seeds(profile, vectors: vectors)
        let rows = (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? []
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
        let book = ListenerRetrieval.StyleBook(entries: rows.map { (key: $0.nameKey, id: $0.discogsID, styles: $0.styles) },
                                               records: records, vectors: vectors)
        var known = Set(read.evidence.map(\.artist))
        let people = Set(read.evidence.compactMap { read.sameArtist[$0.artist] })
        known.formUnion(read.sameArtist.filter { people.contains($0.value) }.keys)
        known.formUnion(PersonalInputs.read(context: context, asOf: now).tasteArtistKeys)
        return Inputs(profile: profile, vectors: vectors, seeds: seeds, entries: entries, releaseIDs: releaseIDs, book: book, known: known)
    }

    /// The candidates, ranked: verified ids only, styled through identity,
    /// by relevance and how strongly they were reached, slots by cluster.
    static func ranked(_ inputs: Inputs, credits: [String: [ListenerRetrieval.Credit]], excluding: Set<String>,
                       limit: Int = 40) -> [ListenerRetrieval.Candidate] {
        let sightings = ListenerRetrieval.direct(inputs.seeds, entries: inputs.entries, records: [], credits: credits)
        var candidates = ListenerRetrieval.merge(sightings).candidates.filter { c in
            c.identity.hasPrefix("discogs:")
                && !inputs.known.contains(c.nameKey) && !c.aliases.contains(where: inputs.known.contains)
                && !excluding.contains(c.nameKey) && !c.aliases.contains(where: excluding.contains)
        }
        for i in candidates.indices { ListenerRetrieval.style(&candidates[i], book: inputs.book) }
        let evidence = ListenerRetrieval.evidence(candidates)
        func score(_ c: ListenerRetrieval.Candidate) -> Double {
            (inputs.profile.relevance(styles: c.styles, vectors: inputs.vectors)?.score ?? 0) * (0.5 + (evidence[c.identity] ?? 0))
        }
        let sorted = candidates.sorted { score($0) != score($1) ? score($0) > score($1) : $0.identity < $1.identity }
        return inputs.profile.spread(sorted, limit: limit, styles: \.styles, vectors: inputs.vectors)
    }

    /// Up to `limit` tracks to hear, each confirmed to play: recordings of
    /// the artists' own first, in rank order, then moments in archived shows.
    func picks(_ inputs: Inputs, excluding: Set<String>, limit: Int = 8) async -> [DiscoveredTrack] {
        // The seeds' own releases, read together.
        let wanted = inputs.releaseIDs.values.flatMap(\.releases)
        let documents = await withTaskGroup(of: (Int, DiscogsReleaseDetail?).self) { group in
            var pending = Set(wanted).sorted().makeIterator()
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
            credits[artist] = ListenerRetrieval.credits(seedID: held.seed, releases: held.releases.compactMap { documents[$0] })
        }
        let ranked = Self.ranked(inputs, credits: credits, excluding: excluding)
        let seedNames = Dictionary(inputs.seeds.map { ($0.artist, (inputs.entries[$0.artist]?.name ?? $0.name, inputs.releaseIDs[$0.artist]?.seed)) },
                                   uniquingKeysWith: { a, _ in a })

        var recordings: [DiscoveredTrack] = [], moments: [DiscoveredTrack] = []
        for candidate in ranked where recordings.count < limit {
            guard let id = Int(candidate.identity.dropFirst("discogs:".count)) else { continue }
            let (via, viaID) = seedNames[candidate.best.seed] ?? (candidate.best.seed, nil)
            func track(_ appearance: TrackDiscovery.Appearance) -> DiscoveredTrack {
                DiscoveredTrack(artist: candidate.name, artistDiscogsID: id, title: appearance.title, source: appearance.source,
                                artworkURL: appearance.artworkURL, release: appearance.release, year: appearance.year,
                                releaseDiscogsID: appearance.releaseDiscogsID,
                                tags: candidate.styles.isEmpty ? nil : candidate.styles, reason: candidate.best.why,
                                via: via, viaDiscogsID: viaID, playable: .yes, score: 0)
            }
            var heard: DiscoveredTrack?
            for appearance in await videos.tracks(artistID: id, artist: candidate.name) {
                if await plays(appearance.source) == true { heard = track(appearance); break }
            }
            if let heard { recordings.append(heard); continue }
            // Radio: a linked recording, else the moment in the show.
            let found = ((try? await rows([id]))?[id]).map { $0 } ?? []
            guard !found.isEmpty, let lines = try? await appearances(found) else { continue }
            var report = TrackDiscoverySource.Report()
            let radio = lines.compactMap { TrackDiscovery.appearance(from: $0, artistID: id, artist: candidate.name, report: &report) }
            func isRecording(_ a: TrackDiscovery.Appearance) -> Bool { if case .recording = a.source { true } else { false } }
            for appearance in (radio.filter(isRecording) + radio.filter { !isRecording($0) }).prefix(4) {
                guard await plays(appearance.source) == true else { continue }
                if isRecording(appearance) { recordings.append(track(appearance)) } else if moments.count < limit { moments.append(track(appearance)) }
                break
            }
        }
        return Array((recordings + moments).prefix(limit))
    }
}
