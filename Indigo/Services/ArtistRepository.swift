//
//  ArtistRepository.swift
//  Indigo
//
//  Artists as the shared graph knows them. The SwiftData `Artist` is the
//  listener's own cached copy and stays separate; this is the networked one.
//

import Foundation

nonisolated struct ArtistRepository: Sendable {
    static let shared = ArtistRepository()

    func artist(id: UUID) async throws -> Catalog.Artist? {
        try await CatalogLookup.entity(Catalog.Artist.self, in: CatalogLookup.Table.artists, id: id)
    }

    /// Names are not identities — two artists can share one — so this returns
    /// every match and leaves the choice to the caller. Prefer the external-id
    /// lookup when an upstream id is in hand.
    func artists(named name: String) async throws -> [Catalog.Artist] {
        guard ArtistName.isRealArtist(name) else { return [] }
        return try await CatalogLookup.entities(
            Catalog.Artist.self, in: CatalogLookup.Table.artists, named: name)
    }

    func artist(externalID: String, provider: String) async throws -> Catalog.Artist? {
        try await CatalogLookup.entity(
            Catalog.Artist.self,
            in: CatalogLookup.Table.artists,
            externalID: externalID,
            provider: provider,
            entityType: .artist
        )
    }
}
