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
    nonisolated static func discoverInputs(context: ModelContext, now: Date = Date()) -> DiscoverInputs {
        let identityStore = ArtistIdentityStore(context: context)
        let personal = PersonalInputs.read(context: context, asOf: now)
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
                seeds.append(.init(discogsID: id, name: resolution.canonicalName, weight: origin.weight))
                break
            }
        }
        // DIG's verified collaborators of the strongest few: someone they made
        // a record with, by entry.
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

    /// Works Discover out again unless a fresh answer is held. Tracks appear
    /// as each one passes its playback check.
    func refreshDiscover(force: Bool = false) async {
        guard TrackDiscoveryFeature.isEnabled, SupabaseService.isConfigured else { return }
        if !force, let at = discover.at, Date().timeIntervalSince(at) < 30 * 60, !discover.tracks.isEmpty { return }
        guard !discover.working else { return }
        discover.working = true
        let source = trackDiscoverySource
        let container = context.container
        let (tracks, report) = await Task.detached(priority: .userInitiated) { [weak self] in
            // Read on a context of its own: two seconds of the listener's
            // history is not something to read on the thread that draws.
            let inputs = Trace.step("dig.discover.inputs") { DigStore.discoverInputs(context: ModelContext(container)) }
            let ask = TrackDiscoverySource.Ask(seeds: inputs.seeds, collaborators: inputs.collaborators, taste: inputs.taste,
                                               knownArtists: inputs.knownArtists, knownTracks: inputs.knownTracks,
                                               limit: 12, releaseLookups: 2)
            return await source.discover(ask) { so in
                await MainActor.run { self?.discover.tracks = so }
            }
        }.value
        discover = DiscoverState(tracks: tracks, report: report, at: Date(), working: false)
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
        // Who DIG says they made records with, by entry.
        let collaborators = IdentityGraph(context: context).neighbourhood(of: .artist(page.name, discogsID: id)).edges.forDIG.all
            .filter { [.collaborator, .personnel, .producer].contains($0.kind) && !MusicianFirst.isTechnicalCredit($0) }
            .compactMap { edge -> TrackDiscovery.Neighbour? in
                guard let other = edge.to.discogsID, edge.to.kind == .artist, other != id else { return nil }
                return .init(discogsID: other, name: edge.to.title, seed: seed, reason: edge.reason, strength: 2)
            }
        let ask = TrackDiscoverySource.Ask(seeds: [seed], collaborators: collaborators,
                                           knownArtists: [RecordingKey.normalizeArtist(page.name)],
                                           limit: 5, ownTracks: 3, releaseLookups: 3)
        let source = trackDiscoverySource
        let (tracks, report) = await Task.detached(priority: .userInitiated) { [weak self] in
            await source.discover(ask) { so in await MainActor.run { self?.artistDiscover[key]?.tracks = so } }
        }.value
        artistDiscover[key] = DiscoverState(tracks: tracks, report: report, at: Date(), working: false)
    }
}

/// What Discover is showing.
struct DiscoverState: Sendable {
    var tracks: [DiscoveredTrack] = []
    var report: TrackDiscoverySource.Report?
    var at: Date?
    var working = false
}
