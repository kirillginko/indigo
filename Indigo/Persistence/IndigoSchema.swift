//
//  IndigoSchema.swift
//  Indigo
//
//  The store's schema, named and versioned.
//
//  Until now the schema was an unversioned list, so a model change that
//  SwiftData could not reconcile on its own failed the open, and the answer to
//  a failed open was to delete the store. That is acceptable for the caches in
//  it and not for the crate. A versioned schema and a migration plan turn
//  "the shape changed" into a stage that runs, instead of a store that is
//  thrown away.
//
//  V1 is the shape every install had before the crate stopped pointing at a
//  `Recording`. Only `CrateItem` differs between V1 and V2, so V1 carries its
//  own frozen copy of that one class and shares every other model with V2.
//
//  V2 adds the snapshot a crated recording keeps of itself (see `CrateItem`),
//  and renames the relationship to `legacyRecording`. The relationship stays
//  until the store is split in two, because a store holding the crate cannot
//  also hold a relationship into the catalogue; until then nothing reads it
//  except the one-time backfill and the migration that follows.
//

import Foundation
import SwiftData

nonisolated enum IndigoSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Track.self,
            Recording.self,
            MediaAppearance.self,
            RecordingSource.self,
            CrateItem.self,
            Artist.self,
            MusicLabel.self,
            RecordingMetadata.self,
            DiscogsArtist.self,
            DiscogsReleaseRecord.self,
            BandcampRelease.self,
            BandcampArtistIndex.self,
            DigVisit.self,
            DigStep.self,
            ListeningEvent.self,
            ExploreOffersRecord.self,
            ArtistPortrait.self,
            StoredEdge.self,
            GraphSnapshot.self
        ]
    }

    /// `CrateItem` as it was in V1. Never edited: it is the shape on disk.
    @Model
    nonisolated final class CrateItem {
        @Attribute(.unique) var id: UUID
        var kindRaw: String
        var addedAt: Date
        var recording: Recording?
        var providerID: String?
        var showID: String?
        var showTitle: String?
        var showSubtitle: String?
        var artworkURLString: String?
        var playbackURLString: String?
        var embedProviderRaw: String?
        var isLiveStream: Bool = false
        var genreTagsRaw: String = ""

        init(recording: Recording) {
            self.id = UUID()
            self.kindRaw = CrateItemKind.recording.rawValue
            self.addedAt = Date()
            self.recording = recording
        }
    }
}

nonisolated enum IndigoSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Track.self,
            Recording.self,
            MediaAppearance.self,
            RecordingSource.self,
            CrateItem.self,
            Artist.self,
            MusicLabel.self,
            RecordingMetadata.self,
            DiscogsArtist.self,
            DiscogsReleaseRecord.self,
            BandcampRelease.self,
            BandcampArtistIndex.self,
            DigVisit.self,
            DigStep.self,
            ListeningEvent.self,
            ExploreOffersRecord.self,
            ArtistPortrait.self,
            StoredEdge.self,
            GraphSnapshot.self
        ]
    }
}

nonisolated enum IndigoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [IndigoSchemaV1.self, IndigoSchemaV2.self] }

    /// Additive: eight optional or defaulted fields on `CrateItem`, and one
    /// rename. The values for the new fields are filled by
    /// `CrateSnapshot.backfill`, which can be interrupted and resumed, rather
    /// than inside the stage.
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: IndigoSchemaV1.self, toVersion: IndigoSchemaV2.self)]
    }
}
