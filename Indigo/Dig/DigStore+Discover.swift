//
//  DigStore+Discover.swift
//  Indigo
//
//  Discover on the device: the listener's starting points as verified
//  entries, DIG's own collaborators of them, and `TrackDiscoverySource` for
//  the rest. Worked out off the main thread, kept half an hour.
//

import Foundation
import SwiftData

extension DigStore {
    /// The inputs Discover is worked out from, read from the store.
    struct DiscoverInputs: Sendable {
        var seeds: [TrackDiscovery.Seed]
        var collaborators: [TrackDiscovery.Neighbour]
        var taste: TasteProfile
        var knownArtists: Set<String>
        var knownTracks: Set<String>
    }

    /// Up to twelve starting points that are verified entries, the long-term
    /// half and a bounded "now" (`MusicianFirstRanker.startingPoints`).
    func discoverInputs(now: Date = Date()) -> DiscoverInputs {
        Self.discoverInputs(context: context, now: now)
    }

    /// The same, from any context: Discover reads it off the main thread.
    nonisolated static func discoverInputs(context: ModelContext, now: Date = Date(), collaborators withCollaborators: Bool = true) -> DiscoverInputs {
        discoverInputs(personal: PersonalInputs.read(context: context, asOf: now), context: context, now: now,
                       collaborators: withCollaborators)
    }

    /// The same, from rows already read: a measurement's history as it was
    /// at an earlier moment.
    nonisolated static func discoverInputs(personal: PersonalInputs, context: ModelContext, now: Date,
                                           collaborators withCollaborators: Bool = true) -> DiscoverInputs {
        let identityStore = ArtistIdentityStore(context: context)
        var seeds: [TrackDiscovery.Seed] = []
        var seen = Set<Int>()
        for origin in MusicianFirstRanker.startingPoints(personal, asOf: now, count: 40) where seeds.count < 12 {
            let names: [String]
            switch origin.node.kind {
            case .artist: names = [origin.node.title]
            case .release, .recording:
                let kept = personal.crate.first { $0.node?.id == origin.node.id }
                names = [origin.node.subtitle].compactMap { $0 }.filter { !$0.isEmpty } + (kept?.tasteArtistKeys ?? [])
            default: names = []
            }
            for name in names.prefix(2) {
                let resolution = identityStore.artistResolution(
                    ArtistReference(name: name, discogsID: origin.node.kind == .artist ? origin.node.discogsID : nil))
                guard resolution.isVerified, let id = resolution.identity.discogsID, seen.insert(id).inserted else { continue }
                seeds.append(.init(discogsID: id, name: resolution.canonicalName, weight: origin.weight,
                                   signal: origin.half == .now ? .recent : .longTerm))
                break
            }
        }
        let collaborators = withCollaborators ? discoverCollaborators(of: seeds, context: context) : []
        var knownArtists = Set<String>(), knownTracks = Set<String>()
        for met in personal.met {
            switch met.node.kind {
            case .artist: knownArtists.insert(RecordingKey.normalizeArtist(met.node.title))
            case .recording: if let artist = met.node.subtitle {
                knownTracks.insert(TrackDiscovery.knownTrackKey(artist, met.node.title))
                knownArtists.insert(RecordingKey.normalizeArtist(artist))
            }
            default: break
            }
        }
        knownArtists.formUnion(personal.tasteArtistKeys)
        let taste = TasteProfile.collected(
            personal: personal, artistTags: LocalKnowledgeAdapter.artistTags(for: personal.tasteArtistKeys, in: context), now: now)
        return DiscoverInputs(seeds: seeds, collaborators: collaborators, taste: taste,
                              knownArtists: knownArtists, knownTracks: knownTracks)
    }

    /// DIG's verified collaborators of the strongest few starting points:
    /// someone they made a record with, by entry. A graph walk each -- seconds
    /// on a long history -- so Discover asks for it beside the backend.
    nonisolated static func discoverCollaborators(of seeds: [TrackDiscovery.Seed], context: ModelContext) -> [TrackDiscovery.Neighbour] {
        var collaborators: [TrackDiscovery.Neighbour] = []
        let identity = IdentityGraph(context: context)
        for seed in seeds.prefix(6) {
            for edge in identity.neighbourhood(of: .artist(seed.name, discogsID: seed.discogsID)).edges.forDIG.all
            where [.collaborator, .personnel, .producer].contains(edge.kind) && !MusicianFirst.isTechnicalCredit(edge) {
                guard let id = edge.to.discogsID, edge.to.kind == .artist, id != seed.discogsID else { continue }
                collaborators.append(.init(discogsID: id, name: edge.to.title, seed: seed,
                                           reason: "With \(seed.name): \(edge.reason)", strength: 2))
            }
        }
        return collaborators
    }

    /// The last list found, kept in Caches so DIG opens with it.
    private nonisolated static var heldDiscoverFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("discover-landing.json")
    }
    private struct HeldDiscover: Codable { let tracks: [DiscoveredTrack]; let at: Date }

    /// Works Discover out again unless a fresh answer is held. Tracks appear
    /// as each one passes its playback check.
    func refreshDiscover(force: Bool = false) async {
        guard TrackDiscoveryFeature.isEnabled || ForYouTracksFeature.isEnabled || ForYouMixFeature.isEnabled,
              SupabaseService.isConfigured else { return }
        // The list from last time, at once: every track on it played within
        // the day. A newer one replaces it whole when it is ready.
        if discover.tracks.isEmpty, discover.at == nil, let file = Self.heldDiscoverFile,
           let data = try? Data(contentsOf: file), let held = try? JSONDecoder().decode(HeldDiscover.self, from: data),
           Date().timeIntervalSince(held.at) < 24 * 60 * 60, !held.tracks.isEmpty {
            discover = DiscoverState(tracks: held.tracks, at: held.at)
        }
        if !force, let at = discover.at, Date().timeIntervalSince(at) < 30 * 60,
           RecommendationRotation.period(at: at) == RecommendationRotation.period(at: Date()),
           !discover.tracks.isEmpty { return }
        guard !discover.working else { return }
        discover.working = true
        let showing = !discover.tracks.isEmpty
        let source = trackDiscoverySource
        let container = context.container
        let (tracks, report) = await Task.detached(priority: .userInitiated) { [weak self] in
            // Read on a context of its own: the listener's history is not
            // something to read on the thread that draws.
            let inputs = Trace.step("dig.discover.inputs") {
                DigStore.discoverInputs(context: ModelContext(container), collaborators: false)
            }
            // DIG's collaborators are a graph walk each, seconds on a long
            // history: walked on another context while the radio's tracks are
            // found and shown, then everything ranked together once they are
            // in -- a second pass the first one's cached reads make cheap.
            let seeds = inputs.seeds
            let walk = Task.detached(priority: .userInitiated) {
                Trace.step("dig.discover.collaborators") { DigStore.discoverCollaborators(of: seeds, context: ModelContext(container)) }
            }
            var ask = TrackDiscoverySource.Ask(seeds: inputs.seeds, taste: inputs.taste,
                                               knownArtists: inputs.knownArtists, knownTracks: inputs.knownTracks,
                                               limit: 12, turn: RecommendationRotation.period(at: Date()), releaseLookups: 2)
            let first = await source.discover(ask) { so in
                // Over a held list, nothing until the new one is whole.
                guard !showing else { return }
                await MainActor.run { self?.discover.tracks = so }
            }
            ask.collaborators = await walk.value
            guard !ask.collaborators.isEmpty else { return first }
            let joint = await source.discover(ask)
            return joint.tracks.isEmpty ? first : joint
        }.value
        if tracks.isEmpty, showing {
            discover.working = false
            return
        }
        discover = DiscoverState(tracks: tracks, report: report, at: Date(), working: false)
        if let file = Self.heldDiscoverFile, let data = try? JSONEncoder().encode(HeldDiscover(tracks: tracks, at: Date())) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Discover from one artist's page: a few of their own tracks, then
    /// tracks by artists played next to them or credited with them -- for
    /// the obscure page with nothing else to offer above all.
    func refreshArtistDiscover(name: String, discogsID: Int?) async {
        guard TrackDiscoveryFeature.isEnabled, SupabaseService.isConfigured else { return }
        let page = artistPage(ArtistReference(name: name, discogsID: discogsID))
        guard let id = page.discogsID else { return }
        let key = "\(id)"
        if let held = artistDiscover[key], let at = held.at, Date().timeIntervalSince(at) < 30 * 60 { return }
        guard artistDiscover[key]?.working != true else { return }
        artistDiscover[key] = DiscoverState(working: true)
        let seed = TrackDiscovery.Seed(discogsID: id, name: page.name, weight: 1)
        let container = context.container
        // Who DIG says they made records with, by entry: a graph walk, on a
        // context of its own while the backend is asked.
        let ask = TrackDiscoverySource.Ask(seeds: [seed],
                                           collaboratorsLater: {
                                               DigStore.pageCollaborators(of: seed, context: ModelContext(container))
                                           },
                                           knownArtists: [RecordingKey.normalizeArtist(page.name)],
                                           limit: 5, ownTracks: 3, releaseLookups: 3)
        let source = trackDiscoverySource
        let (tracks, report) = await Task.detached(priority: .userInitiated) { [weak self] in
            await source.discover(ask) { so in await MainActor.run { self?.artistDiscover[key]?.tracks = so } }
        }.value
        artistDiscover[key] = DiscoverState(tracks: tracks, report: report, at: Date(), working: false)
    }
}

extension DigStore {
    /// An artist page's verified collaborators, as its Listen section offers them.
    nonisolated static func pageCollaborators(of seed: TrackDiscovery.Seed, context: ModelContext) -> [TrackDiscovery.Neighbour] {
        IdentityGraph(context: context).neighbourhood(of: .artist(seed.name, discogsID: seed.discogsID)).edges.forDIG.all
            .filter { [.collaborator, .personnel, .producer].contains($0.kind) && !MusicianFirst.isTechnicalCredit($0) }
            .compactMap { edge -> TrackDiscovery.Neighbour? in
                guard let other = edge.to.discogsID, edge.to.kind == .artist, other != seed.discogsID else { return nil }
                return .init(discogsID: other, name: edge.to.title, seed: seed, reason: edge.reason, strength: 2)
            }
    }
}

/// What Discover is showing.
struct DiscoverState: Sendable {
    var tracks: [DiscoveredTrack] = []
    var report: TrackDiscoverySource.Report?
    var at: Date?
    var working = false
}
