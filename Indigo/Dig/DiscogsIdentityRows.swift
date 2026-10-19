//
//  DiscogsIdentityRows.swift
//  Indigo
//
//  How the app reads an artist row's Discogs entry from `external_ids`.
//
//  Off (every release build, and a development build unless switched on),
//  nothing changes: a `discogs` link only, each reader folding the rows as it
//  always has. On, a `musicbrainz_discogs` link counts too -- a Discogs id an
//  NTS-published MusicBrainz recording leads to, written only after it was
//  verified (radio identity Tier 1). A direct link always wins; within one
//  provider the smallest id does, so a row reads the same entry however the
//  rows arrive. A row whose MusicBrainz links name two Discogs entries reads
//  neither: one MusicBrainz artist can cover an alias or a second project,
//  and two projects are never made one. Nothing here reads a name or
//  `artists.musicbrainz_id`.
//
//  On only in a development build, by launch argument
//  (`-INDIGO_MUSICBRAINZ_DISCOGS YES`), the Sync diagnostics toggle, or in a
//  test. Never in a release build.
//

import Foundation
import Supabase

nonisolated enum DiscogsIdentityRows {
    #if DEBUG
    /// A development build's own switch. Compiled into development builds
    /// only.
    static let switchKey = "INDIGO_MUSICBRAINZ_DISCOGS"
    #endif

    /// For tests and measurements: on or off whatever the defaults say.
    nonisolated(unsafe) static var override: Bool?

    static var isEnabled: Bool {
        if let override { return override }
        #if DEBUG
        return UserDefaults.standard.bool(forKey: switchKey)
        #else
        return false
        #endif
    }

    /// The providers that name an artist row's Discogs entry, preferred first.
    static let providers = ["discogs", "musicbrainz_discogs"]

    /// The provider filter on an `external_ids` read: `discogs` alone when
    /// off, exactly as before.
    static func providerFilter(_ query: PostgrestFilterBuilder, enabled: Bool = isEnabled) -> PostgrestFilterBuilder {
        enabled ? query.in("provider", values: providers) : query.eq("provider", value: "discogs")
    }

    struct Link: Decodable, Sendable, Equatable {
        let entity_id: UUID
        let provider: String
        let external_id: String
    }

    // MARK: On

    /// The links read: a `discogs` link always, a `musicbrainz_discogs` one
    /// only when it is the row's one such entry.
    static func trusted(_ links: [Link]) -> [(row: UUID, rank: Int, id: Int)] {
        var musicBrainz: [UUID: Set<Int>] = [:]
        for link in links where link.provider == providers[1] { if let id = Int(link.external_id) { musicBrainz[link.entity_id, default: []].insert(id) } }
        return links.compactMap { link in
            guard let rank = providers.firstIndex(of: link.provider), let id = Int(link.external_id) else { return nil }
            if rank > 0, (musicBrainz[link.entity_id]?.count ?? 0) > 1 { return nil }
            return (link.entity_id, rank, id)
        }
    }

    /// Each row's one Discogs id.
    static func discogs(byRow links: [Link]) -> [UUID: Int] {
        var best: [UUID: (rank: Int, id: Int)] = [:]
        for link in trusted(links) {
            let rank = link.rank, id = link.id
            if let held = best[link.row], (held.rank, held.id) <= (rank, id) { continue }
            best[link.row] = (rank, id)
        }
        return best.mapValues(\.id)
    }


    /// Each Discogs id's rows: directly linked rows first, then the rest,
    /// each by row id.
    static func rows(byDiscogs links: [Link]) -> [Int: [UUID]] {
        var ranked: [Int: [UUID: Int]] = [:]
        for link in trusted(links) {
            ranked[link.id, default: [:]][link.row] = min(link.rank, ranked[link.id]?[link.row] ?? link.rank)
        }
        return ranked.mapValues { rows in
            rows.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key.uuidString < $1.key.uuidString }.map(\.key)
        }
    }

    // MARK: Off: each reader's own fold, unchanged

    /// `TrackDiscoverySource`: the first link a row arrives with.
    static func firstDiscogs(byRow links: [Link]) -> [UUID: Int] {
        var found: [UUID: Int] = [:]
        for link in links where found[link.entity_id] == nil { if let id = Int(link.external_id) { found[link.entity_id] = id } }
        return found
    }

    /// `ListenerRetrieval`: the smallest id a row has.
    static func smallestDiscogs(byRow links: [Link]) -> [UUID: Int] {
        var found: [UUID: Int] = [:]
        for link in links { if let id = Int(link.external_id) { found[link.entity_id] = min(id, found[link.entity_id] ?? id) } }
        return found
    }

    /// `RadioListenFinder`: each id's rows in the order they arrive.
    static func arrivingRows(byDiscogs links: [Link]) -> [Int: [UUID]] {
        var mapped: [Int: [UUID]] = [:]
        for link in links { if let id = Int(link.external_id) { mapped[id, default: []].append(link.entity_id) } }
        return mapped
    }
}
