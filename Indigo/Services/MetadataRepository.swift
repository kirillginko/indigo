//
//  MetadataRepository.swift
//  Indigo
//
//  The generic provider cache. Lets Indigo hold a provider's response before
//  anyone has written a normalizer for it, so a screen stops waiting on
//  Discogs long before the shared graph is fully modelled.
//
//  Reads come straight from Postgres. Writes do not: the app ships a
//  publishable key with read-only policies, so refreshing the cache is the
//  Edge Function's job (see supabase/functions/catalog-refresh).
//

import Foundation
import Supabase

/// A cache hit and how much to trust it.
///
/// Staleness is reported rather than enforced because an expired payload still
/// beats an empty screen. Callers render what they have and let a refresh land
/// underneath — the pattern Indigo already uses for its own metadata cache.
nonisolated struct CachedPayload<Value: Sendable>: Sendable {
    let value: Value
    let fetchedAt: Date
    let expiresAt: Date?

    var isFresh: Bool {
        guard let expiresAt else { return true }
        return expiresAt > Date()
    }
}

nonisolated struct MetadataRepository: Sendable {
    static let shared = MetadataRepository()

    /// Suggested lifetimes. Identifiers barely move; live radio is worthless a
    /// minute later. Callers pass these when asking the backend to refresh.
    nonisolated enum Lifetime {
        static let artist: TimeInterval = 30 * 86_400
        static let label: TimeInterval = 30 * 86_400
        static let release: TimeInterval = 60 * 86_400
        static let identifier: TimeInterval = 365 * 86_400
        static let archivedShow: TimeInterval = 365 * 86_400
        static let liveShow: TimeInterval = 60
    }

    private struct CacheRow: Decodable {
        let payload: AnyJSON
        let fetchedAt: Date
        let expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case payload
            case fetchedAt = "fetched_at"
            case expiresAt = "expires_at"
        }
    }

    /// The cached payload for a provider resource, fresh or not, or nil on a
    /// true miss.
    func cached<Payload: Decodable & Sendable>(
        _ type: Payload.Type,
        provider: String,
        resourceType: String,
        resourceID: String
    ) async throws -> CachedPayload<Payload>? {
        let client = try SupabaseService.requireClient()

        let rows: [CacheRow] = try await client
            .from("metadata_cache")
            .select("payload,fetched_at,expires_at")
            .eq("provider", value: provider)
            .eq("resource_type", value: resourceType)
            .eq("resource_id", value: resourceID)
            .limit(1)
            .execute()
            .value

        guard let row = rows.first else { return nil }

        let data = try AnyJSON.encoder.encode(row.payload)
        let value = try AnyJSON.decoder.decode(Payload.self, from: data)
        return CachedPayload(value: value, fetchedAt: row.fetchedAt, expiresAt: row.expiresAt)
    }

    /// Asks the backend to fetch this resource upstream and store the result.
    ///
    /// Returns the freshly normalized payload so a cache miss is one round
    /// trip rather than a write followed by a re-read.
    @discardableResult
    func refresh<Payload: Decodable & Sendable>(
        _ type: Payload.Type,
        provider: String,
        resourceType: String,
        resourceID: String,
        lifetime: TimeInterval
    ) async throws -> Payload {
        let client = try SupabaseService.requireClient()

        let request = RefreshRequest(
            provider: provider,
            resourceType: resourceType,
            resourceID: resourceID,
            ttlSeconds: Int(lifetime)
        )

        return try await client.functions.invoke(
            "catalog-refresh",
            options: FunctionInvokeOptions(body: request)
        )
    }

    // MARK: - Provider paths
    //
    // Searches have no id to key on, so they are cached under the request
    // itself. The key is built raw rather than percent-encoded: the Edge
    // Function has to produce the identical string, and URLSearchParams and
    // URLComponents disagree about spaces. Encoding is the URL's business,
    // not the key's. CatalogPathKeyTests pins the two together.
    static func cacheKey(path: String, query: [URLQueryItem]) -> String {
        let pairs = query
            .map { ($0.name, $0.value ?? "") }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
        return pairs.isEmpty ? path : "\(path)?\(pairs.joined(separator: "&"))"
    }

    /// The cached response for a provider path, fresh or not, or nil on a miss.
    func cached<Payload: Decodable & Sendable>(
        _ type: Payload.Type,
        provider: String,
        path: String,
        query: [URLQueryItem]
    ) async throws -> CachedPayload<Payload>? {
        try await cached(
            type,
            provider: provider,
            resourceType: path,
            resourceID: Self.cacheKey(path: path, query: query)
        )
    }

    /// Asks the backend to fetch a provider path upstream, with its own
    /// credential, and store what comes back.
    func fetch<Payload: Decodable & Sendable>(
        _ type: Payload.Type,
        provider: String,
        path: String,
        query: [URLQueryItem],
        lifetime: TimeInterval
    ) async throws -> Payload {
        let client = try SupabaseService.requireClient()

        let request = PathRequest(
            provider: provider,
            path: path,
            query: Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first }),
            ttlSeconds: Int(lifetime),
            // Every caller of this reaches it by missing `cached(path:query:)`
            // first, and that read is the same one the function would repeat.
            skipCacheRead: true
        )

        return try await client.functions.invoke(
            "catalog-refresh",
            options: FunctionInvokeOptions(body: request)
        )
    }

    private struct PathRequest: Encodable, Sendable {
        let provider: String
        let path: String
        let query: [String: String]
        let ttlSeconds: Int
        let skipCacheRead: Bool

        enum CodingKeys: String, CodingKey {
            case provider, path, query
            case ttlSeconds = "ttl_seconds"
            case skipCacheRead = "skip_cache_read"
        }
    }

    private struct RefreshRequest: Encodable, Sendable {
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
