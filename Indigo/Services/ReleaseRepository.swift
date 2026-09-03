//
//  ReleaseRepository.swift
//  Indigo
//
//  Releases, and the label-page query the md's DIG example is built around:
//  one round trip instead of a Discogs call followed by a MusicBrainz call
//  followed by a wait.
//

import Foundation
import Supabase

nonisolated struct ReleaseRepository: Sendable {
    static let shared = ReleaseRepository()

    func release(id: UUID) async throws -> Catalog.Release? {
        try await CatalogLookup.entity(Catalog.Release.self, in: CatalogLookup.Table.releases, id: id)
    }

    func release(externalID: String, provider: String) async throws -> Catalog.Release? {
        try await CatalogLookup.entity(
            Catalog.Release.self,
            in: CatalogLookup.Table.releases,
            externalID: externalID,
            provider: provider,
            entityType: .release
        )
    }

    /// A label's catalogue, newest first. Nulls last, because a release with no
    /// year is an incomplete record rather than the most recent thing on the
    /// label — and Postgres sorts nulls first on a descending order by default.
    func releases(onLabel labelID: UUID, limit: Int = 100) async throws -> [Catalog.Release] {
        let client = try SupabaseService.requireClient()
        return try await client
            .from(CatalogLookup.Table.releases)
            .select()
            .eq("label_id", value: labelID.uuidString)
            .order("release_year", ascending: false, nullsFirst: false)
            .limit(limit)
            .execute()
            .value
    }

    func releases(byArtist artistID: UUID, limit: Int = 100) async throws -> [Catalog.Release] {
        let client = try SupabaseService.requireClient()
        return try await client
            .from(CatalogLookup.Table.releases)
            .select()
            .eq("artist_id", value: artistID.uuidString)
            .order("release_year", ascending: false, nullsFirst: false)
            .limit(limit)
            .execute()
            .value
    }

    /// Catalogue numbers are how a record identifies itself when nothing else
    /// agrees — the one string printed on the sleeve.
    func releases(catalogNumber: String, limit: Int = 25) async throws -> [Catalog.Release] {
        let trimmed = catalogNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let client = try SupabaseService.requireClient()
        return try await client
            .from(CatalogLookup.Table.releases)
            .select()
            .eq("catalog_number", value: trimmed)
            .limit(limit)
            .execute()
            .value
    }
}
