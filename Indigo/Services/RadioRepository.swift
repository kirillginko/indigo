//
//  RadioRepository.swift
//  Indigo
//
//  What radio knows, as Indigo's own database rather than a station's.
//
//  Distinct from MediaAppearance, which is the listener's private provenance —
//  what *they* heard, kept in SwiftData. This is the shared record: every
//  tracklist Indigo has ingested, from every episode anyone opened, which is
//  what lets an artist page answer "which shows have played this" rather than
//  only "which shows have played this while you were listening".
//
//  Reads come straight from Postgres. Writes do not: the app ships a
//  publishable key with read-only policies, so ingestion is asked for and the
//  Edge Function does it (see supabase/functions/_shared/nts.ts).
//

import Foundation
import Supabase

nonisolated struct RadioRepository: Sendable {
    static let shared = RadioRepository()

    /// How long Indigo waits before re-asking a station about an episode.
    ///
    /// Not the lifetime of the provenance — appearances are rows and outlive
    /// any cache. This only decides how quickly a tracklist published days
    /// after the broadcast gets noticed, which is common enough to be worth a
    /// month and rare enough not to be worth a week.
    static let episodeLifetime: TimeInterval = 30 * 86_400

    // MARK: - Entities

    func show(id showID: UUID) async throws -> Catalog.RadioShow? {
        try await CatalogLookup.entity(
            Catalog.RadioShow.self, in: CatalogLookup.Table.radioShows, id: showID)
    }

    func show(provider: String, externalID: String) async throws -> Catalog.RadioShow? {
        try await first(Catalog.RadioShow.self,
                        in: CatalogLookup.Table.radioShows,
                        provider: provider, externalID: externalID)
    }

    func episode(id episodeID: UUID) async throws -> Catalog.RadioEpisode? {
        try await CatalogLookup.entity(
            Catalog.RadioEpisode.self, in: CatalogLookup.Table.radioEpisodes, id: episodeID)
    }

    func episode(provider: String, externalID: String) async throws -> Catalog.RadioEpisode? {
        try await first(Catalog.RadioEpisode.self,
                        in: CatalogLookup.Table.radioEpisodes,
                        provider: provider, externalID: externalID)
    }

    /// A show's broadcasts, newest first. Nulls last: an episode with no
    /// broadcast date is a record missing a field, not the most recent thing
    /// the programme did — and Postgres sorts nulls first on a descending
    /// order by default.
    func episodes(ofShow showID: UUID, limit: Int = 50) async throws -> [Catalog.RadioEpisode] {
        let client = try SupabaseService.requireClient()
        return try await client
            .from(CatalogLookup.Table.radioEpisodes)
            .select()
            .eq("radio_show_id", value: showID.uuidString)
            .order("aired_at", ascending: false, nullsFirst: false)
            .limit(limit)
            .execute()
            .value
    }

    // MARK: - Reads shaped for a screen

    /// The radio header of an artist page: how often, across how many shows,
    /// since when, and which programmes play them most.
    ///
    /// One call, because the alternative is shipping every appearance to the
    /// app so it can count rows Postgres already counted while finding them.
    func summary(forArtist artistID: UUID) async throws -> Catalog.ArtistRadioSummary {
        let client = try SupabaseService.requireClient()
        return try await client
            .rpc("artist_radio_summary", params: ArtistParams(pArtistID: artistID.uuidString))
            .execute()
            .value
    }

    /// Every broadcast this artist turned up in — show, date, what was played,
    /// and where in the episode.
    func appearances(
        forArtist artistID: UUID,
        limit: Int = 50
    ) async throws -> [Catalog.ArtistRadioAppearance] {
        let client = try SupabaseService.requireClient()
        return try await client
            .rpc("artist_radio_appearances",
                 params: ArtistPageParams(pArtistID: artistID.uuidString, pLimit: limit))
            .execute()
            .value
    }

    /// The radio-derived edges touching an artist: the programmes that play
    /// them, and the artists they get played beside.
    ///
    /// Each one arrives with the count it was derived from, so a page can say
    /// why it is showing something rather than showing a score.
    func relations(
        forArtist artistID: UUID,
        limit: Int = 24
    ) async throws -> [Catalog.RadioRelation] {
        let client = try SupabaseService.requireClient()
        return try await client
            .rpc("artist_radio_relations",
                 params: ArtistPageParams(pArtistID: artistID.uuidString, pLimit: limit))
            .execute()
            .value
    }

    /// §10. What radio knows about a label.
    func summary(forLabel labelID: UUID) async throws -> Catalog.LabelRadioSummary {
        let client = try SupabaseService.requireClient()
        return try await client
            .rpc("label_radio_summary", params: LabelParams(pLabelID: labelID.uuidString))
            .execute()
            .value
    }

    /// An episode's tracklist as Indigo holds it, with the artist resolved
    /// where it could be — so every line is a way into DIG rather than text.
    func tracklist(forEpisode episodeID: UUID) async throws -> [Catalog.EpisodeTrack] {
        let client = try SupabaseService.requireClient()
        return try await client
            .rpc("episode_tracklist", params: EpisodeParams(pEpisodeID: episodeID.uuidString))
            .execute()
            .value
    }

    // MARK: - Ingestion

    /// Asks the backend to read an NTS broadcast and keep what it played.
    ///
    /// The app already has this payload when it renders an episode, and sends
    /// only the identity anyway: ingestion writes to the shared graph, and a
    /// tracklist posted by whoever holds the publishable key is not evidence
    /// of anything. The function fetches its own copy.
    func ingestNTSEpisode(show: String, episode: String) async throws {
        let client = try SupabaseService.requireClient()
        try await client.functions.invoke(
            "catalog-refresh",
            options: FunctionInvokeOptions(
                body: IngestRequest(
                    provider: "nts",
                    resourceType: "episode",
                    resourceID: Self.ntsEpisodeResourceID(show: show, episode: episode),
                    ttlSeconds: Int(Self.episodeLifetime)
                )
            )
        )
    }

    /// How a broadcast names itself to the backend.
    ///
    /// NTS's identity for one is genuinely two slugs, so this is the one
    /// resource id in Indigo that contains a slash — and the Edge Function's
    /// allow-list only accepts it for `nts`, with exactly one separator. The
    /// two are pinned together by RadioIngestionTests.
    static func ntsEpisodeResourceID(show: String, episode: String) -> String {
        "\(show)/\(episode)"
    }

    /// Fills in the programme an episode belongs to. Ingesting a broadcast
    /// creates a shell for its show under the alias; this is what gives it a
    /// title and a picture.
    func ingestNTSShow(alias: String) async throws {
        let client = try SupabaseService.requireClient()
        try await client.functions.invoke(
            "catalog-refresh",
            options: FunctionInvokeOptions(
                body: IngestRequest(
                    provider: "nts",
                    resourceType: "show",
                    resourceID: alias,
                    ttlSeconds: Int(MetadataRepository.Lifetime.artist)
                )
            )
        )
    }

    /// Ingestion is a side effect of browsing, never the reason a screen
    /// waits. Failures are the backend's business — an episode that did not
    /// get recorded is picked up the next time somebody opens it.
    func ingestNTSEpisodeInBackground(show: String, episode: String) {
        guard SupabaseService.isConfigured else { return }
        Task.detached(priority: .background) {
            try? await ingestNTSEpisode(show: show, episode: episode)
        }
    }

    func ingestNTSShowInBackground(alias: String) {
        guard SupabaseService.isConfigured else { return }
        Task.detached(priority: .background) {
            try? await ingestNTSShow(alias: alias)
            // Ingesting a residency queues its recent broadcasts. Nothing
            // schedules that queue on its own, so browsing is what turns it
            // over — a few episodes each time somebody opens a show, rather
            // than a tracklist only when somebody opens that exact episode.
            try? await drainEnrichmentQueue()
        }
    }

    /// Asks the backend to work through a batch of queued enrichment.
    ///
    /// Safe to call from anywhere and at any time: claiming is
    /// `for update skip locked`, and the queue can only hold work the backend
    /// put there — the app is not able to enqueue, so this cannot be turned
    /// into a way to make Indigo fetch something of the caller's choosing.
    func drainEnrichmentQueue(limit: Int = 6) async throws {
        let client = try SupabaseService.requireClient()
        try await client.functions.invoke(
            "enrichment-worker",
            options: FunctionInvokeOptions(body: DrainRequest(limit: limit))
        )
    }

    // MARK: - Plumbing

    private func first<Row: Decodable & Sendable>(
        _ type: Row.Type,
        in table: String,
        provider: String,
        externalID: String
    ) async throws -> Row? {
        let client = try SupabaseService.requireClient()
        let rows: [Row] = try await client
            .from(table)
            .select()
            .eq("provider", value: provider)
            .eq("external_id", value: externalID)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    private struct ArtistParams: Encodable, Sendable {
        let pArtistID: String
        enum CodingKeys: String, CodingKey { case pArtistID = "p_artist_id" }
    }

    private struct ArtistPageParams: Encodable, Sendable {
        let pArtistID: String
        let pLimit: Int
        enum CodingKeys: String, CodingKey {
            case pArtistID = "p_artist_id"
            case pLimit = "p_limit"
        }
    }

    private struct EpisodeParams: Encodable, Sendable {
        let pEpisodeID: String
        enum CodingKeys: String, CodingKey { case pEpisodeID = "p_episode_id" }
    }

    private struct LabelParams: Encodable, Sendable {
        let pLabelID: String
        enum CodingKeys: String, CodingKey { case pLabelID = "p_label_id" }
    }

    private struct DrainRequest: Encodable, Sendable {
        let limit: Int
    }

    private struct IngestRequest: Encodable, Sendable {
        let provider: String
        let resourceType: String
        let resourceID: String
        let ttlSeconds: Int

        enum CodingKeys: String, CodingKey {
            case provider
            case resourceType = "resource_type"
            case resourceID = "resource_id"
            case ttlSeconds = "ttl_seconds"
        }
    }
}
