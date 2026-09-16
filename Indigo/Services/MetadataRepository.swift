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

    /// A row carries its payload inline or says where it went. Discogs releases
    /// moved to Storage in 0036; searches, shelves and NTS stayed inline.
    private struct CacheRow: Decodable {
        let payload: AnyJSON?
        let payloadPath: String?
        let fetchedAt: Date
        let expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case payload
            case payloadPath = "payload_path"
            case fetchedAt = "fetched_at"
            case expiresAt = "expires_at"
        }
    }

    /// `CacheRow` with the id it was keyed on, for the batched read below.
    /// A type nested in a generic function is not allowed, and this one is
    /// read by one.
    private struct KeyedCacheRow: Decodable {
        let resourceID: String
        let payload: AnyJSON?
        let payloadPath: String?
        let fetchedAt: Date

        enum CodingKeys: String, CodingKey {
            case resourceID = "resource_id"
            case payload
            case payloadPath = "payload_path"
            case fetchedAt = "fetched_at"
        }
    }

    // MARK: - Payloads kept in Storage

    /// The bucket 0036 keeps release documents in.
    static let cacheBucket = "catalog-cache"

    /// Reads one stored object by its key. A property so a test can stand in
    /// for the network; the app uses `fetchFromStorage`.
    var fetchStoredObject: @Sendable (String) async throws -> Data = MetadataRepository.fetchFromStorage

    /// The public URL, straight to the CDN: the bucket is public, as the table
    /// it replaced was readable by this key, so there is no signing round trip.
    static func storedObjectURL(forPath path: String) -> URL? {
        guard !path.isEmpty, let base = SupabaseConfiguration.url else { return nil }
        return base
            .appendingPathComponent("storage/v1/object/public")
            .appendingPathComponent(cacheBucket)
            .appendingPathComponent(path)
    }

    @Sendable static func fetchFromStorage(_ path: String) async throws -> Data {
        guard let url = storedObjectURL(forPath: path) else { throw URLError(.badURL) }
        let request = URLRequest(url: url, timeoutInterval: 10)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// The JSON a row stands for, wherever it is kept.
    ///
    /// Nil when there is none to be had — no payload, or an object that will
    /// not load — which every caller already treats as a miss and answers by
    /// fetching again. A missing object is therefore a slower page, never a
    /// broken one.
    func payloadData(inline: AnyJSON?, path: String?) async -> Data? {
        if let inline {
            if case .null = inline {} else { return try? AnyJSON.encoder.encode(inline) }
        }
        guard let path, !path.isEmpty else { return nil }
        return try? await fetchStoredObject(path)
    }

    /// Payloads for many rows, keyed by id, skipping any that cannot be read or
    /// decoded.
    ///
    /// The batched read was one round trip for a whole artist page — the lever
    /// that made the cache worth asking at all — and moving releases to Storage
    /// turns it into one request per release. So those are made in parallel, a
    /// few at a time, and inline rows are decoded without waiting on them.
    func resolve<Payload: Decodable & Sendable>(
        _ type: Payload.Type,
        rows: [(id: String, inline: AnyJSON?, path: String?)],
        concurrency: Int = 8
    ) async -> [String: Payload] {
        var found: [String: Payload] = [:]
        var stored: [(id: String, path: String)] = []
        for row in rows {
            if let inline = row.inline, case .null = inline {
                if let path = row.path { stored.append((row.id, path)) }
            } else if let inline = row.inline {
                if let data = try? AnyJSON.encoder.encode(inline),
                   let value = try? AnyJSON.decoder.decode(Payload.self, from: data) {
                    found[row.id] = value
                }
            } else if let path = row.path {
                stored.append((row.id, path))
            }
        }
        guard !stored.isEmpty else { return found }

        await withTaskGroup(of: (String, Payload?).self) { group in
            var pending = stored.makeIterator()
            func startNext() -> Bool {
                guard let next = pending.next() else { return false }
                group.addTask {
                    guard let data = try? await fetchStoredObject(next.path),
                          let value = try? AnyJSON.decoder.decode(Payload.self, from: data)
                    else { return (next.id, nil) }
                    return (next.id, value)
                }
                return true
            }
            for _ in 0..<max(1, concurrency) where startNext() {}
            while let (id, value) = await group.next() {
                if let value { found[id] = value }
                _ = startNext()
            }
        }
        return found
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
            .select("payload,payload_path,fetched_at,expires_at")
            .eq("provider", value: provider)
            .eq("resource_type", value: resourceType)
            .eq("resource_id", value: resourceID)
            .limit(1)
            .execute()
            .value

        guard let row = rows.first,
              let data = await payloadData(inline: row.payload, path: row.payloadPath)
        else { return nil }

        let value = try AnyJSON.decoder.decode(Payload.self, from: data)
        return CachedPayload(value: value, fetchedAt: row.fetchedAt, expiresAt: row.expiresAt)
    }

    /// The cached payloads for many resources of one type, in one round trip.
    ///
    /// An artist page reads a dozen releases at once, and asked one at a time
    /// that is a dozen round trips to answer a question Postgres can answer in
    /// one. The probe only pays for itself if it costs less than what it
    /// replaces, and twelve probes against eight Discogs requests did not.
    ///
    /// Keyed by `resource_id`, and a resource nobody has cached is simply
    /// absent — the caller reads that as "ask the provider yourself".
    func cached<Payload: Decodable & Sendable>(
        _ type: Payload.Type,
        provider: String,
        resourceType: String,
        resourceIDs: [String],
        fresherThan lifetime: TimeInterval
    ) async throws -> [String: Payload] {
        guard !resourceIDs.isEmpty else { return [:] }
        let client = try SupabaseService.requireClient()

        let rows: [KeyedCacheRow] = try await client
            .from("metadata_cache")
            .select("resource_id,payload,payload_path,fetched_at")
            .eq("provider", value: provider)
            .eq("resource_type", value: resourceType)
            .in("resource_id", values: resourceIDs)
            .execute()
            .value

        let oldest = Date().addingTimeInterval(-lifetime)
        // One row that will not decode, or an object that will not load, is one
        // release read from Discogs instead, not a page that fails.
        return await resolve(
            type,
            rows: rows
                .filter { $0.fetchedAt > oldest }
                .map { (id: $0.resourceID, inline: $0.payload, path: $0.payloadPath) }
        )
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

    /// Names the releases a page wanted and could not find cached.
    ///
    /// The app cannot fill the queue — `enqueue_enrichment_job` is revoked from
    /// the publishable key — so this is the narrow door it is allowed through:
    /// Discogs release ids, and nothing that follows but a fetch of those.
    ///
    /// Failure is silence. A backend that is down or unconfigured means the
    /// cache stays cold, which is exactly where it was a moment ago.
    func requestReleaseCache(ids: [Int]) async {
        guard let client = try? SupabaseService.requireClient(), !ids.isEmpty else { return }

        struct Params: Encodable {
            let pDiscogsIDs: [String]
            enum CodingKeys: String, CodingKey { case pDiscogsIDs = "p_discogs_ids" }
        }

        // Fifty is what `request_release_cache` accepts in a call.
        _ = try? await client
            .rpc("request_release_cache", params: Params(
                pDiscogsIDs: ids.prefix(50).map(String.init)
            ))
            .execute()
    }

    /// Names the shelf a page wanted and could not read.
    ///
    /// The narrow door again: a Discogs artist id, and nothing that follows
    /// but a fetch of that artist's listing. See migration 0027.
    func requestArtistShelf(discogsID id: Int) async {
        guard let client = try? SupabaseService.requireClient() else { return }

        struct Params: Encodable {
            let pDiscogsID: String
            enum CodingKeys: String, CodingKey { case pDiscogsID = "p_discogs_id" }
        }

        _ = try? await client
            .rpc("request_artist_shelf", params: Params(pDiscogsID: String(id)))
            .execute()
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
