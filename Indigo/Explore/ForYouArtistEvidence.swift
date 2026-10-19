//
//  ForYouArtistEvidence.swift
//  Indigo
//
//  Somebody reached only as a producer, remixer or co-producer is offered
//  by For You's mix only when something shows they are an artist in their
//  own right. A producer is creative, never technical (`ContributorRole`),
//  but a studio producer's credit on a record the listener keeps is not a
//  reason to send them to that producer's page as if to a musician.
//
//  Evidence, cheapest first: a record DIG holds under their own name, or a
//  recording of theirs heard on radio here (`DigWorker.artistEvidence`);
//  then the shared radio catalogue -- their own tracks played on air,
//  asked once for the few who need it, by Discogs entry, and kept a day
//  (`TrackDiscoveryCache`). Unanswered is not evidence: offline, they wait.
//

import Foundation
import Supabase

nonisolated enum ForYouArtistEvidence {
    /// Whether a suggestion's route is a creative credit (produced,
    /// co-produced, remixed) to an artist.
    static func isCreativeRoute(_ suggestion: ExploreSuggestion) -> Bool {
        suggestion.node.kind == .artist && ContributorRole.of(edge: MusicEdge(
            from: .artist(suggestion.via), to: suggestion.node, kind: suggestion.kind, source: .discogs,
            reason: suggestion.reason, confidence: 1)) == .creative
    }

    /// Of these artists, the node ids the shared catalogue has radio
    /// appearances for, under their own Discogs entry. One read for the
    /// entries' rows (kept a day) and one for their appearances.
    ///
    /// An artist without a Discogs entry here is looked for by their exact
    /// name (`byName`), the way a radio tracklist names them.
    static func onRadio(_ nodes: [MusicNode], source: TrackDiscoverySource = .live,
                        byName: @Sendable ([String]) async throws -> [String: [UUID]] = Self.rowsNamed) async -> Set<String> {
        let byID = Dictionary(nodes.compactMap { node in node.discogsID.map { ($0, node.id) } }, uniquingKeysWith: { first, _ in first })
        let named = Dictionary(nodes.filter { $0.discogsID == nil }.map { ($0.title, $0.id) }, uniquingKeysWith: { first, _ in first })
        // Each catalogue row, and the node it speaks for.
        var owner: [UUID: String] = [:]
        if !byID.isEmpty {
            let ids = Array(byID.keys).sorted()
            var rows = await source.cache.rows(for: ids)
            let missing = ids.filter { rows[$0] == nil }
            if !missing.isEmpty, let found = try? await source.rows(missing) {
                await source.cache.keep(rows: found, asked: missing)
                rows.merge(found) { first, _ in first }
            }
            for (id, list) in rows { for row in list { owner[row] = byID[id] } }
        }
        // A name only when one catalogue artist answers to it: two rows of
        // one name are namesakes, and either could be the one on air.
        if !named.isEmpty, let found = try? await byName(Array(named.keys).sorted()) {
            for (name, list) in found where list.count == 1 { owner[list[0]] = named[name] }
        }
        guard !owner.isEmpty, let appearances = try? await source.appearances(Array(owner.keys).sorted { $0.uuidString < $1.uuidString })
        else { return [] }
        return Set(appearances.compactMap { $0.artist_id.flatMap { owner[$0] } })
    }

    /// The shared catalogue's artist rows named exactly so.
    static let rowsNamed: @Sendable ([String]) async throws -> [String: [UUID]] = { names in
        let client = try SupabaseService.requireClient()
        struct Row: Decodable { let id: UUID; let name: String }
        let rows: [Row] = try await client.from("artists").select("id,name").in("name", values: names).limit(200).execute().value
        return Dictionary(grouping: rows, by: \.name).mapValues { $0.map(\.id) }
    }

    /// The offers without the unproven whom the catalogue did not vouch for.
    static func kept(_ offers: ExploreOffers, unproven: [MusicNode], vouched: Set<String>) -> ExploreOffers {
        let out = Set(unproven.map(\.id)).subtracting(vouched)
        var kept = offers
        kept.next = offers.next.filter { !out.contains($0.id) }
        kept.artists = offers.artists.filter { !out.contains($0.id) }
        return kept
    }
}
