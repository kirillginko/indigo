//
//  CatalogLookup.swift
//  Indigo
//
//  The three reads every catalogue repository needs: by Indigo UUID, by an
//  upstream provider's id, and by name. Shared so the entity repositories stay
//  thin and one fix to a query reaches all of them.
//

import Foundation
import Supabase

nonisolated enum CatalogLookup {
    /// The `entity_id` half of an `external_ids` row, on its own.
    private struct Pointer: Decodable {
        let entityID: UUID

        enum CodingKeys: String, CodingKey { case entityID = "entity_id" }
    }

    /// Table names as they appear in the migrations.
    enum Table {
        static let artists = "artists"
        static let labels = "labels"
        static let releases = "releases"
        static let recordings = "recordings"
        static let externalIDs = "external_ids"
        static let artwork = "artwork"
        static let radioShows = "radio_shows"
        static let radioEpisodes = "radio_episodes"
        static let radioAppearances = "radio_appearances"
    }

    static func entity<Row: Decodable & Sendable>(
        _ type: Row.Type,
        in table: String,
        id: UUID
    ) async throws -> Row? {
        let client = try SupabaseService.requireClient()
        let rows: [Row] = try await client
            .from(table)
            .select()
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Matches on the same normalized form Indigo uses everywhere else, so a
    /// lookup and a stored row agree about what counts as the same name.
    static func entities<Row: Decodable & Sendable>(
        _ type: Row.Type,
        in table: String,
        named name: String,
        limit: Int = 10
    ) async throws -> [Row] {
        let key = RecordingKey.normalize(name)
        guard !key.isEmpty else { return [] }

        let client = try SupabaseService.requireClient()
        return try await client
            .from(table)
            .select()
            .eq("normalized_name", value: key)
            .limit(limit)
            .execute()
            .value
    }

    /// Resolves an upstream id to the Indigo entity it points at.
    ///
    /// Two queries rather than an embedded join: `external_ids` is polymorphic,
    /// so there is no foreign key for PostgREST to follow.
    static func entity<Row: Decodable & Sendable>(
        _ type: Row.Type,
        in table: String,
        externalID: String,
        provider: String,
        entityType: Catalog.EntityType
    ) async throws -> Row? {
        let client = try SupabaseService.requireClient()

        let pointers: [Pointer] = try await client
            .from(Table.externalIDs)
            .select("entity_id")
            .eq("provider", value: provider)
            .eq("entity_type", value: entityType.rawValue)
            .eq("external_id", value: externalID)
            .limit(1)
            .execute()
            .value

        guard let pointer = pointers.first else { return nil }
        return try await entity(type, in: table, id: pointer.entityID)
    }
}
