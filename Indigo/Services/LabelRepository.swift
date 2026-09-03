//
//  LabelRepository.swift
//  Indigo
//
//  Labels as the shared graph knows them.
//

import Foundation

nonisolated struct LabelRepository: Sendable {
    static let shared = LabelRepository()

    func label(id: UUID) async throws -> Catalog.Label? {
        try await CatalogLookup.entity(Catalog.Label.self, in: CatalogLookup.Table.labels, id: id)
    }

    func labels(named name: String) async throws -> [Catalog.Label] {
        try await CatalogLookup.entities(
            Catalog.Label.self, in: CatalogLookup.Table.labels, named: name)
    }

    func label(externalID: String, provider: String) async throws -> Catalog.Label? {
        try await CatalogLookup.entity(
            Catalog.Label.self,
            in: CatalogLookup.Table.labels,
            externalID: externalID,
            provider: provider,
            entityType: .label
        )
    }
}
