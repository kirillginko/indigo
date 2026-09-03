//
//  CatalogDiscogsGateway.swift
//  Indigo
//
//  Every Discogs request the app makes, routed through Indigo's backend.
//
//  The point is not speed — a warm Postgres read beats Discogs, but invoking
//  the Edge Function does not. The point is that Indigo's Discogs credential
//  stops shipping inside the app, where anyone could read it out of the
//  bundle, and lives server-side instead.
//
//  So the order matters: read the shared cache directly, which is the fast
//  path, and only invoke the function when nobody has asked for this yet.
//

import Foundation

nonisolated struct CatalogDiscogsGateway: Sendable {
    static let shared = CatalogDiscogsGateway()

    private let repository: MetadataRepository
    let isEnabled: Bool

    init(
        repository: MetadataRepository = .shared,
        isEnabled: Bool = CatalogDiscogsGateway.isEnabledByDefault
    ) {
        self.repository = repository
        self.isEnabled = isEnabled
    }

    /// Off under XCTest, for the reason DiscogsConfiguration is: the fixture
    /// tests drive DiscogsClient with a stub transport, and those must not
    /// quietly become live calls.
    static var isEnabledByDefault: Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return false
        }
        return SupabaseService.isConfigured
    }

    private static let provider = "discogs"

    /// A catalogue entry describes a record that was pressed; it does not
    /// change. A search describes what the catalogue currently contains, and
    /// it does — a new record filed under a label should not take a season to
    /// appear.
    static func lifetime(forPath path: String) -> TimeInterval {
        path.hasPrefix("database/search") ? 7 * 86_400 : MetadataRepository.Lifetime.release
    }

    func get<Payload: Decodable & Sendable>(
        _ type: Payload.Type,
        path: String,
        query: [URLQueryItem]
    ) async throws -> Payload {
        guard isEnabled else { throw SupabaseError.notConfigured }

        let hit = try? await repository.cached(
            Payload.self, provider: Self.provider, path: path, query: query)
        if let hit, hit.isFresh { return hit.value }

        do {
            return try await repository.fetch(
                Payload.self,
                provider: Self.provider,
                path: path,
                query: query,
                lifetime: Self.lifetime(forPath: path)
            )
        } catch {
            // Stale beats nothing: what we already hold still describes the
            // record, and DIG is enrichment rather than the point of the page.
            if let hit { return hit.value }
            throw error
        }
    }
}
