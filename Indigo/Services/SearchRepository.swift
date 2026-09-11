//
//  SearchRepository.swift
//  Indigo
//
//  The shared catalogue, asked a question rather than told an identity.
//
//  Every other repository here is a lookup: the caller knows which artist,
//  label or release they mean and wants its row back. This one is the opposite
//  — somebody has typed half a name — so it goes through `search_catalog`,
//  which ranks in Postgres where the indexes are. See migration 0018.
//

import Foundation
import Supabase

nonisolated struct SearchRepository: Sendable {
    static let shared = SearchRepository()

    /// Sent alongside the raw query so the database matches names by the same
    /// rule the rest of Indigo does. Reimplementing `RecordingKey.normalize`
    /// in SQL would be a second definition, free to drift from the first.
    private struct Params: Encodable {
        let pQuery: String
        let pKey: String
        let pLimit: Int

        enum CodingKeys: String, CodingKey {
            case pQuery = "p_query"
            case pKey = "p_key"
            case pLimit = "p_limit"
        }
    }

    /// Nothing shorter is worth a round trip: two characters match a
    /// substantial fraction of any catalogue, and the answer is noise.
    static let shortestQuery = 2

    func search(_ query: String, limit: Int = 8) async throws -> Catalog.SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.shortestQuery else { return .none }

        let client = try SupabaseService.requireClient()
        return try await client
            .rpc("search_catalog", params: Params(
                pQuery: trimmed,
                pKey: RecordingKey.normalize(trimmed),
                pLimit: limit
            ))
            .execute()
            .value
    }
}
