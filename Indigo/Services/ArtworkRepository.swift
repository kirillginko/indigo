//
//  ArtworkRepository.swift
//  Indigo
//
//  Where a picture of a record comes from.
//
//  Prefers Indigo's own cached copy and falls back to the provider's URL,
//  because not every provider licenses re-hosting — a row carrying only an
//  upstream URL is a complete answer, not a half-filled cache entry.
//
//  Distinct from ArtworkStore/RemoteArtworkStore, which fetch and hold images
//  on the device. This only resolves which URL those should be pointed at.
//

import Foundation
import Supabase

nonisolated struct ArtworkRepository: Sendable {
    static let shared = ArtworkRepository()

    enum Size: Sendable {
        case thumbnail
        case medium
        case large

        /// The sizes the cache generates, per the build plan: 128-160, 512, 1200.
        fileprivate func path(in row: Catalog.Artwork) -> String? {
            switch self {
            case .thumbnail: row.thumbnailPath
            case .medium: row.mediumPath
            case .large: row.largePath
            }
        }
    }

    /// A resolved image, and whether it is Indigo's copy or someone else's.
    ///
    /// The distinction is worth keeping: an upstream URL can disappear or
    /// rate-limit, so a caller may reasonably treat it as less durable.
    struct Resolved: Sendable, Hashable {
        let url: URL
        let isCached: Bool
    }

    private static let bucket = "artwork"

    func artwork(for entityType: Catalog.EntityType, id entityID: UUID) async throws -> Catalog.Artwork? {
        let client = try SupabaseService.requireClient()
        let rows: [Catalog.Artwork] = try await client
            .from(CatalogLookup.Table.artwork)
            .select()
            .eq("entity_type", value: entityType.rawValue)
            .eq("entity_id", value: entityID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    func imageURL(
        for entityType: Catalog.EntityType,
        id entityID: UUID,
        size: Size = .medium
    ) async throws -> Resolved? {
        guard let row = try await artwork(for: entityType, id: entityID) else { return nil }
        return resolve(row, size: size)
    }

    /// Falls back through the smaller sizes before giving up on the cache, so a
    /// half-populated row still renders rather than sending the caller upstream.
    func resolve(_ row: Catalog.Artwork, size: Size) -> Resolved? {
        let preferred: [Size] = switch size {
        case .thumbnail: [.thumbnail, .medium, .large]
        case .medium: [.medium, .large, .thumbnail]
        case .large: [.large, .medium, .thumbnail]
        }

        for candidate in preferred {
            if let path = candidate.path(in: row), let url = Self.publicURL(forPath: path) {
                return Resolved(url: url, isCached: true)
            }
        }
        if let path = row.storagePath, let url = Self.publicURL(forPath: path) {
            return Resolved(url: url, isCached: true)
        }
        if let original = row.originalURL, let url = URL(string: original) {
            return Resolved(url: url, isCached: false)
        }
        return nil
    }

    /// The bucket is public, so this needs no signing round trip — the point of
    /// caching artwork is that it appears without one.
    static func publicURL(forPath path: String) -> URL? {
        guard !path.isEmpty, let base = SupabaseConfiguration.url else { return nil }
        return base
            .appendingPathComponent("storage/v1/object/public")
            .appendingPathComponent(bucket)
            .appendingPathComponent(path)
    }
}
