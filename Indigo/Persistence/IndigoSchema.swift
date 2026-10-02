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
//  A model that changes is frozen in every version before the change, and every
//  version that has not seen the change lists the frozen copy, not the live
//  class. A version that lists a live class drifts when the class does, and a
//  store written by the shipped shape then no longer matches it. That happened
//  once, found by opening a copy of a real store; `SchemaFixtureTests` opens
//  stores written under each version so it cannot go unnoticed again.
//
//  V1 is the shape every install had before the crate stopped pointing at a
//  `Recording`. Only `CrateItem` differs between V1 and V2, so V1 carries its
//  own frozen copy of that one class and shares every other model with V2.
//
//  V6 removes the bridge fields (`CrateItem.legacyRecording` and the local
//  recording id on events and visits), which existed only to carry the old local
//  representation to the portable one. With them gone nothing in the four synced
//  models points at anything else, and V6 is what a split store can hold.
//
//  V5 is the shape a synced store can hold: no unique constraints, and every
//  property optional or defaulted. A property gets a default only where an
//  empty value means something harmless -- an empty history, no time -- and
//  stays optional where absence means something. `legacyRecording` is still
//  here, and is the one thing that stops `CrateItem` being final: a relationship
//  cannot cross the split into a synced store and the catalogue, so step 7
//  removes it with the split.
//
//  V4 gives a dig visit and a dig step an id of their own, the stable part of
//  deciding which of two rows for the same node survives a merge.
//
//  V3 stops persisting a local `Recording.id` in the listening log and the dig
//  history. What recording an encounter was with is the node's key, which
//  `RecordingIdentity` makes the same on every device.
//
//  V2 adds the snapshot a crated recording keeps of itself (see `CrateItem`),
//  and renames the relationship to `legacyRecording`. The relationship stays
//  until the store is split in two, because a store holding the crate cannot
//  also hold a relationship into the catalogue; until then nothing reads it
//  except the one-time backfill and the migration that follows.
//

import Foundation
import SwiftData

/// The `Recording` family as it was through V5, frozen.
///
/// The old versions of `CrateItem` point at a `Recording`, and a model that
/// points at another is pulled into any schema that holds the other, whether or
/// not it was asked for. So if those old versions pointed at the live class, the
/// local store's schema would quietly gain an entity called `CrateItem` -- the
/// old one -- beside the real one in the synced store, and the pair would not
/// open. They point at these instead, which no current schema contains.
nonisolated enum IndigoLegacy {
    @Model
    nonisolated final class Recording {
        @Attribute(.unique) var id: UUID
        var title: String?
        var artistName: String?
        var albumTitle: String?
        var musicBrainzRecordingID: String?
        var isrc: String?
        var identificationStatusRaw: String
        var matchKey: String
        var unknownCode: String?
        var durationSeconds: Double?
        var createdAt: Date
        var updatedAt: Date

        @Relationship(deleteRule: .cascade, inverse: \MediaAppearance.recording)
        var appearances: [MediaAppearance] = []

        @Relationship(deleteRule: .cascade, inverse: \RecordingSource.recording)
        var sources: [RecordingSource] = []

        init(id: UUID = UUID(), title: String? = nil, artistName: String? = nil, matchKey: String = "") {
            self.id = id
            self.title = title
            self.artistName = artistName
            self.identificationStatusRaw = "identified"
            self.matchKey = matchKey
            self.createdAt = Date()
            self.updatedAt = Date()
        }
    }

    @Model
    nonisolated final class MediaAppearance {
        @Attribute(.unique) var id: UUID
        var providerID: String
        var stationID: String?
        var stationName: String?
        var showTitle: String?
        var showID: String?
        var artworkURLString: String?
        var heardAt: Date
        var offsetSeconds: Double?
        var endedAt: Date?
        var isLive: Bool
        var confidence: Double?
        var identificationMethodRaw: String
        var originalMetadata: String?
        var recording: Recording?

        init(id: UUID = UUID(), providerID: String = "nts") {
            self.id = id
            self.providerID = providerID
            self.heardAt = Date()
            self.isLive = false
            self.identificationMethodRaw = "providerTracklist"
        }
    }

    @Model
    nonisolated final class RecordingSource {
        @Attribute(.unique) var id: UUID
        var kindRaw: String
        var identifier: String
        var providerID: String?
        var offsetSeconds: Double?
        var addedAt: Date
        var recording: Recording?

        init(id: UUID = UUID(), kindRaw: String = "streamingLink", identifier: String) {
            self.id = id
            self.kindRaw = kindRaw
            self.identifier = identifier
            self.addedAt = Date()
        }
    }
}

nonisolated enum IndigoSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Track.self,
            IndigoLegacy.Recording.self,
            IndigoLegacy.MediaAppearance.self,
            IndigoLegacy.RecordingSource.self,
            CrateItem.self,
            Artist.self,
            MusicLabel.self,
            RecordingMetadata.self,
            DiscogsArtist.self,
            DiscogsReleaseRecord.self,
            BandcampRelease.self,
            BandcampArtistIndex.self,
            IndigoSchemaV2.DigVisit.self,
            IndigoSchemaV3.DigStep.self,
            IndigoSchemaV2.ListeningEvent.self,
            ExploreOffersRecord.self,
            ArtistPortrait.self,
            IndigoSchemaV2.StoredEdge.self,
            GraphSnapshot.self
        ]
    }

    /// `CrateItem` as it was in V1. Never edited: it is the shape on disk.
    @Model
    nonisolated final class CrateItem {
        @Attribute(.unique) var id: UUID
        var kindRaw: String
        var addedAt: Date
        var recording: IndigoLegacy.Recording?
        var providerID: String?
        var showID: String?
        var showTitle: String?
        var showSubtitle: String?
        var artworkURLString: String?
        var playbackURLString: String?
        var embedProviderRaw: String?
        var isLiveStream: Bool = false
        var genreTagsRaw: String = ""

        init(recording: IndigoLegacy.Recording) {
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
            IndigoLegacy.Recording.self,
            IndigoLegacy.MediaAppearance.self,
            IndigoLegacy.RecordingSource.self,
            IndigoSchemaV4.CrateItem.self,
            Artist.self,
            MusicLabel.self,
            RecordingMetadata.self,
            DiscogsArtist.self,
            DiscogsReleaseRecord.self,
            BandcampRelease.self,
            BandcampArtistIndex.self,
            DigVisit.self,
            IndigoSchemaV3.DigStep.self,
            ListeningEvent.self,
            ExploreOffersRecord.self,
            ArtistPortrait.self,
            StoredEdge.self,
            GraphSnapshot.self
        ]
    }

    /// `ListeningEvent` as it was in V2, with the recording id under its old
    /// name. Never edited: it is the shape on disk.
    @Model
    nonisolated final class ListeningEvent {
        @Attribute(.unique) var id: UUID
        var at: Date
        var actionRaw: String
        var nodeID: String
        var nodeKindRaw: String
        var nodeKey: String
        var title: String
        var subtitle: String?
        var mbid: String?
        var discogsID: Int?
        var recordingID: UUID?
        var providerID: String?
        var handle: String?
        var sourceProviderID: String?
        var sourceShowID: String?
        var sourceShowTitle: String?
        var seconds: Double
        var completion: Double
        var tags: [String]

        init(nodeKind: String, nodeKey: String, title: String, recordingID: UUID?) {
            self.id = UUID()
            self.at = Date()
            self.actionRaw = "played"
            self.nodeID = "\(nodeKind):\(nodeKey)"
            self.nodeKindRaw = nodeKind
            self.nodeKey = nodeKey
            self.title = title
            self.recordingID = recordingID
            self.seconds = 0
            self.completion = 0
            self.tags = []
        }
    }

    /// `DigVisit` as it was in V2.
    @Model
    nonisolated final class DigVisit {
        @Attribute(.unique) var nodeID: String
        var kindRaw: String
        var title: String
        var subtitle: String?
        var visits: Int
        var firstVisitedAt: Date
        var lastVisitedAt: Date
        var mbid: String?
        var discogsID: Int?
        var recordingID: UUID?
        var providerID: String?
        var handle: String?

        init(kind: String, key: String, title: String, visits: Int, recordingID: UUID?) {
            self.nodeID = "\(kind):\(key)"
            self.kindRaw = kind
            self.title = title
            self.visits = visits
            self.firstVisitedAt = Date()
            self.lastVisitedAt = Date()
            self.recordingID = recordingID
        }
    }

    /// `StoredEdge` as it was in V2, with the destination's recording id.
    @Model
    nonisolated final class StoredEdge {
        @Attribute(.unique) var id: String
        var fromID: String
        var kindRaw: String
        var sourceRaw: String
        var reason: String
        var confidence: Double
        var occurrences: Int
        var toID: String
        var toKindRaw: String
        var toKey: String
        var toTitle: String
        var toSubtitle: String?
        var toMBID: String?
        var toDiscogsID: Int?
        var toRecordingID: UUID?
        var toProviderID: String?
        var toHandle: String?
        var toArtworkURLString: String?

        init(id: String, toKey: String, toRecordingID: UUID?) {
            self.id = id
            self.fromID = "artist:x"
            self.kindRaw = "playedAlongside"
            self.sourceRaw = "radio"
            self.reason = ""
            self.confidence = 0.5
            self.occurrences = 1
            self.toID = "recording:\(toKey)"
            self.toKindRaw = "recording"
            self.toKey = toKey
            self.toTitle = toKey
            self.toRecordingID = toRecordingID
        }
    }
}

nonisolated enum IndigoSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Track.self,
            IndigoLegacy.Recording.self,
            IndigoLegacy.MediaAppearance.self,
            IndigoLegacy.RecordingSource.self,
            IndigoSchemaV4.CrateItem.self,
            Artist.self,
            MusicLabel.self,
            RecordingMetadata.self,
            DiscogsArtist.self,
            DiscogsReleaseRecord.self,
            BandcampRelease.self,
            BandcampArtistIndex.self,
            DigVisit.self,
            DigStep.self,
            IndigoSchemaV4.ListeningEvent.self,
            ExploreOffersRecord.self,
            ArtistPortrait.self,
            StoredEdge.self,
            GraphSnapshot.self
        ]
    }

    /// `DigVisit` as it was in V3: no id of its own.
    @Model
    nonisolated final class DigVisit {
        @Attribute(.unique) var nodeID: String
        var kindRaw: String
        var title: String
        var subtitle: String?
        var visits: Int
        var firstVisitedAt: Date
        var lastVisitedAt: Date
        var mbid: String?
        var discogsID: Int?
        @Attribute(originalName: "recordingID") var legacyRecordingID: UUID?
        var providerID: String?
        var handle: String?

        init(kind: String, key: String, title: String, visits: Int) {
            self.nodeID = "\(kind):\(key)"
            self.kindRaw = kind
            self.title = title
            self.visits = visits
            self.firstVisitedAt = Date()
            self.lastVisitedAt = Date()
        }
    }

    /// `DigStep` as it was in V3.
    @Model
    nonisolated final class DigStep {
        @Attribute(.unique) var identity: String
        var fromNodeID: String
        var toNodeID: String
        var count: Int
        var lastAt: Date

        init(from: String, to: String, count: Int) {
            self.identity = "\(from)→\(to)"
            self.fromNodeID = from
            self.toNodeID = to
            self.count = count
            self.lastAt = Date()
        }
    }
}

nonisolated enum IndigoSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Track.self,
            IndigoLegacy.Recording.self,
            IndigoLegacy.MediaAppearance.self,
            IndigoLegacy.RecordingSource.self,
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

    /// `CrateItem` as it was in V2 through V4: a unique id and no defaults.
    @Model
    nonisolated final class CrateItem {
        @Attribute(.unique) var id: UUID
        var kindRaw: String
        var addedAt: Date
        var matchKey: String = ""
        var unknownCode: String?
        var title: String?
        var artistName: String?
        var albumTitle: String?
        var identificationStatusRaw: String?
        var stationName: String?
        var broadcastOffsetSeconds: Double?
        @Relationship(originalName: "recording") var legacyRecording: IndigoLegacy.Recording?
        var providerID: String?
        var showID: String?
        var showTitle: String?
        var showSubtitle: String?
        var artworkURLString: String?
        var playbackURLString: String?
        var embedProviderRaw: String?
        var isLiveStream: Bool = false
        var genreTagsRaw: String = ""

        init(id: UUID = UUID(), kindRaw: String = "recording", addedAt: Date = Date()) {
            self.id = id
            self.kindRaw = kindRaw
            self.addedAt = addedAt
        }
    }

    /// `ListeningEvent` as it was in V3 and V4: a unique id and no defaults.
    @Model
    nonisolated final class ListeningEvent {
        @Attribute(.unique) var id: UUID
        var at: Date
        var actionRaw: String
        var nodeID: String
        var nodeKindRaw: String
        var nodeKey: String
        var title: String
        var subtitle: String?
        var mbid: String?
        var discogsID: Int?
        @Attribute(originalName: "recordingID") var legacyRecordingID: UUID?
        var providerID: String?
        var handle: String?
        var sourceProviderID: String?
        var sourceShowID: String?
        var sourceShowTitle: String?
        var seconds: Double
        var completion: Double
        var tags: [String]

        init(id: UUID = UUID(), nodeKey: String, seconds: Double = 0) {
            self.id = id
            self.at = Date()
            self.actionRaw = "played"
            self.nodeID = "artist:\(nodeKey)"
            self.nodeKindRaw = "artist"
            self.nodeKey = nodeKey
            self.title = nodeKey
            self.seconds = seconds
            self.completion = 0
            self.tags = []
        }
    }

    /// `DigVisit` as it was in V4: an id, and no defaults.
    @Model
    nonisolated final class DigVisit {
        var id: UUID?
        var nodeID: String
        var kindRaw: String
        var title: String
        var subtitle: String?
        var visits: Int
        var firstVisitedAt: Date
        var lastVisitedAt: Date
        var mbid: String?
        var discogsID: Int?
        @Attribute(originalName: "recordingID") var legacyRecordingID: UUID?
        var providerID: String?
        var handle: String?

        init(nodeID: String, visits: Int) {
            self.id = UUID()
            self.nodeID = nodeID
            self.kindRaw = "artist"
            self.title = nodeID
            self.visits = visits
            self.firstVisitedAt = Date()
            self.lastVisitedAt = Date()
        }
    }

    /// `DigStep` as it was in V4.
    @Model
    nonisolated final class DigStep {
        var id: UUID?
        var identity: String
        var fromNodeID: String
        var toNodeID: String
        var count: Int
        var lastAt: Date

        init(identity: String, count: Int) {
            self.id = UUID()
            self.identity = identity
            self.fromNodeID = "a"
            self.toNodeID = "b"
            self.count = count
            self.lastAt = Date()
        }
    }
}

nonisolated enum IndigoSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Track.self,
            IndigoLegacy.Recording.self,
            IndigoLegacy.MediaAppearance.self,
            IndigoLegacy.RecordingSource.self,
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

    /// `CrateItem` as it was in V5: defaulted, not unique, and still holding the
    /// relationship to the `Recording` it was crated from. It exists so the
    /// listener's old store can be read once, by `LegacyStore`, and moved.
    @Model
    nonisolated final class CrateItem {
        var id: UUID = UUID()
        var kindRaw: String = "recording"
        var addedAt: Date = Date.distantPast
        var matchKey: String = ""
        var unknownCode: String?
        var title: String?
        var artistName: String?
        var albumTitle: String?
        var identificationStatusRaw: String?
        var stationName: String?
        var broadcastOffsetSeconds: Double?
        @Relationship(originalName: "recording") var legacyRecording: IndigoLegacy.Recording?
        var providerID: String?
        var showID: String?
        var showTitle: String?
        var showSubtitle: String?
        var artworkURLString: String?
        var playbackURLString: String?
        var embedProviderRaw: String?
        var isLiveStream: Bool = false
        var genreTagsRaw: String = ""

        init(id: UUID = UUID(), kindRaw: String = "recording", addedAt: Date = Date()) {
            self.id = id
            self.kindRaw = kindRaw
            self.addedAt = addedAt
        }
    }

    /// `ListeningEvent` as it was in V5, with the local recording id.
    @Model
    nonisolated final class ListeningEvent {
        var id: UUID = UUID()
        var at: Date = Date.distantPast
        var actionRaw: String = "played"
        var nodeID: String = ""
        var nodeKindRaw: String = "artist"
        var nodeKey: String = ""
        var title: String = ""
        var subtitle: String?
        var mbid: String?
        var discogsID: Int?
        @Attribute(originalName: "recordingID") var legacyRecordingID: UUID?
        var providerID: String?
        var handle: String?
        var sourceProviderID: String?
        var sourceShowID: String?
        var sourceShowTitle: String?
        var seconds: Double = 0
        var completion: Double = 0
        var tags: [String] = []

        init(id: UUID = UUID(), nodeKind: String = "artist", nodeKey: String, title: String = "",
             legacyRecordingID: UUID? = nil, seconds: Double = 0, at: Date = Date()) {
            self.id = id
            self.at = at
            self.nodeID = "\(nodeKind):\(nodeKey)"
            self.nodeKindRaw = nodeKind
            self.nodeKey = nodeKey
            self.title = title
            self.legacyRecordingID = legacyRecordingID
            self.seconds = seconds
        }
    }

    /// `DigVisit` as it was in V5, with the local recording id.
    @Model
    nonisolated final class DigVisit {
        var id: UUID?
        var nodeID: String = ""
        var kindRaw: String = "artist"
        var title: String = ""
        var subtitle: String?
        var visits: Int = 0
        var firstVisitedAt: Date = Date.distantFuture
        var lastVisitedAt: Date = Date.distantPast
        var mbid: String?
        var discogsID: Int?
        @Attribute(originalName: "recordingID") var legacyRecordingID: UUID?
        var providerID: String?
        var handle: String?

        init(id: UUID? = UUID(), nodeKind: String = "artist", nodeKey: String, title: String = "",
             visits: Int = 0, legacyRecordingID: UUID? = nil) {
            self.id = id
            self.nodeID = "\(nodeKind):\(nodeKey)"
            self.kindRaw = nodeKind
            self.title = title
            self.visits = visits
            self.legacyRecordingID = legacyRecordingID
        }
    }
}

nonisolated enum IndigoSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

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

    /// What belongs in the synced store, and what stays on the device. A model
    /// is in exactly one, and nothing in one points at anything in the other.
    static let userDataModelNames: Set<String> = ["CrateItem", "ListeningEvent", "DigVisit", "DigStep"]

    static var userDataModels: [any PersistentModel.Type] {
        models.filter { userDataModelNames.contains(String(describing: $0)) }
    }

    static var localModels: [any PersistentModel.Type] {
        models.filter { !userDataModelNames.contains(String(describing: $0)) }
    }
}

nonisolated enum IndigoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [IndigoSchemaV1.self, IndigoSchemaV2.self, IndigoSchemaV3.self, IndigoSchemaV4.self, IndigoSchemaV5.self, IndigoSchemaV6.self] }

    /// V1 -> V2 is additive: eight optional or defaulted fields on `CrateItem`,
    /// and one rename. V2 -> V3 renames the recording id on `ListeningEvent` and
    /// `DigVisit` to `legacyRecordingID` and drops `StoredEdge.toRecordingID`.
    /// The values are filled and rewritten by `CrateSnapshot.backfill` and
    /// `IdentityBackfill`, which can be interrupted and resumed, rather than
    /// inside a stage.
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: IndigoSchemaV1.self, toVersion: IndigoSchemaV2.self),
            .lightweight(fromVersion: IndigoSchemaV2.self, toVersion: IndigoSchemaV3.self),
            .lightweight(fromVersion: IndigoSchemaV3.self, toVersion: IndigoSchemaV4.self),
            .lightweight(fromVersion: IndigoSchemaV4.self, toVersion: IndigoSchemaV5.self),
            .lightweight(fromVersion: IndigoSchemaV5.self, toVersion: IndigoSchemaV6.self)
        ]
    }
}

/// The same plan, stopping at V5: how a copy of the listener's old store is
/// brought to the last shape that still held the bridge fields, so that it can
/// be read. Never pointed at the old store itself.
nonisolated enum IndigoLegacyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [IndigoSchemaV1.self, IndigoSchemaV2.self, IndigoSchemaV3.self, IndigoSchemaV4.self, IndigoSchemaV5.self]
    }
    static var stages: [MigrationStage] { Array(IndigoMigrationPlan.stages.prefix(4)) }
}
