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
//  V1 is the shape every existing install already has, so there is nothing to
//  migrate yet and no stage. The first change to any model below adds V2 here,
//  with a stage, and copies the old shape of whatever changed into V1 as a
//  nested type, since V1 names the live classes only while they have not moved.
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
}

nonisolated enum IndigoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [IndigoSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
