//
//  CatalogRows.swift
//  Indigo
//
//  The shape of Indigo's shared catalogue as it crosses the wire. These mirror
//  supabase/migrations/0001_core_schema.sql column for column; the local
//  SwiftData models keep their own shape and stay the listener's private copy.
//
//  Namespaced because the app already owns `Artist` and `Recording` as
//  SwiftData models, and the two are not interchangeable.
//

import Foundation

nonisolated enum Catalog {
    /// The entities an external id or an artwork row can point at. Mirrors the
    /// check constraints on `external_ids` and `artwork`.
    enum EntityType: String, Codable, Sendable, CaseIterable {
        case artist
        case label
        case release
        case recording
        case radioShow = "radio_show"
    }

    struct Artist: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var name: String
        var normalizedName: String?
        var country: String?
        var createdAt: Date
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, name, country
            case normalizedName = "normalized_name"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    struct Label: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var name: String
        var normalizedName: String?
        var country: String?
        var createdAt: Date
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, name, country
            case normalizedName = "normalized_name"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    struct Release: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var title: String
        var artistID: UUID?
        var labelID: UUID?
        var catalogNumber: String?
        var releaseYear: Int?
        var releaseType: String?
        var createdAt: Date
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, title
            case artistID = "artist_id"
            case labelID = "label_id"
            case catalogNumber = "catalog_number"
            case releaseYear = "release_year"
            case releaseType = "release_type"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    struct Recording: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var title: String?
        var artistID: UUID?
        var releaseID: UUID?
        var isrc: String?
        var musicbrainzRecordingID: String?
        var identificationStatus: String
        var createdAt: Date
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, title, isrc
            case artistID = "artist_id"
            case releaseID = "release_id"
            case musicbrainzRecordingID = "musicbrainz_recording_id"
            case identificationStatus = "identification_status"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    struct ExternalID: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var entityType: EntityType
        var entityID: UUID
        var provider: String
        var externalID: String
        var sourceURL: String?

        enum CodingKeys: String, CodingKey {
            case id, provider
            case entityType = "entity_type"
            case entityID = "entity_id"
            case externalID = "external_id"
            case sourceURL = "source_url"
        }
    }

    /// Artwork carries both a cached path and the upstream URL, because not
    /// every provider licenses re-hosting. A row with only `originalURL` is
    /// legitimate, not a half-finished cache entry.
    struct Artwork: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var entityType: EntityType
        var entityID: UUID
        var provider: String?
        var originalURL: String?
        var storagePath: String?
        var thumbnailPath: String?
        var mediumPath: String?
        var largePath: String?
        var width: Int?
        var height: Int?
        var fetchedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, provider, width, height
            case entityType = "entity_type"
            case entityID = "entity_id"
            case originalURL = "original_url"
            case storagePath = "storage_path"
            case thumbnailPath = "thumbnail_path"
            case mediumPath = "medium_path"
            case largePath = "large_path"
            case fetchedAt = "fetched_at"
        }
    }
}
