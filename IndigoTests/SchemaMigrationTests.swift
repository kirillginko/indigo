import XCTest
import SwiftData
@testable import Indigo

final class SchemaMigrationTests: XCTestCase {
    /// Phase 1 shipped a store containing only Track. Phase 2 adds four
    /// entities to the same store; if that isn't a lightweight migration the
    /// container's recovery path wipes the listener's library index on first
    /// launch — and, once the crate has anything in it, real data.
    func testPhase1StoreOpensUnderThePhase2Schema() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("indigo-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")

        // Write a Phase 1 store, then let its container go before reopening —
        // two live containers on one store file abort inside Core Data.
        try autoreleasepool {
            let oldSchema = Schema([Track.self])
            let oldContainer = try ModelContainer(
                for: oldSchema,
                configurations: ModelConfiguration(schema: oldSchema, url: storeURL)
            )
            let oldContext = ModelContext(oldContainer)
            oldContext.insert(Track(
                path: "/Music/Autechre/Bike.flac", relativePath: "Autechre/Bike.flac",
                title: "Bike", artist: "Autechre", albumArtist: "Autechre", album: "Tri Repetae",
                genre: "Electronic", trackNumber: 4, discNumber: 1, year: 1995, duration: 477,
                fileModified: Date(), fileSize: 1024, artworkKey: nil, scanGeneration: 1
            ))
            try oldContext.save()
        }

        // Reopen it with the shipping Phase 2 schema.
        let newContainer = try ModelContainer(
            for: Persistence.schema,
            configurations: ModelConfiguration(schema: Persistence.schema, url: storeURL)
        )
        let newContext = ModelContext(newContainer)

        XCTAssertEqual(try newContext.fetchCount(FetchDescriptor<Track>()), 1,
                       "The indexed library must survive the Phase 2 schema")
        XCTAssertEqual(try newContext.fetchCount(FetchDescriptor<CrateItem>()), 0)

        // And the new entities are usable in the migrated store. Built by
        // hand rather than through CrateService: a short-lived main-actor
        // @Observable released inside a test method aborts in the test host.
        let recording = try RecordingStore(context: newContext).upsert(title: "Bike", artistName: "Autechre")
        newContext.insert(CrateItem(recording: recording))
        try newContext.save()
        XCTAssertEqual(try newContext.fetchCount(FetchDescriptor<CrateItem>()), 1)
        XCTAssertEqual(try newContext.fetchCount(FetchDescriptor<Recording>()), 1)
    }

    /// The remembered EXPLORE answer adds an entity to a schema that is on
    /// people's machines with their crate in it — the same hazard as the
    /// listening log below, and worth the same check.
    func testAStoreWithoutTheRememberedOffersOpensWithThemAndKeepsTheCrate() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("indigo-offers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")

        // Everything the shipping schema has, minus the new record.
        let previous = Schema([
            Track.self, Recording.self, MediaAppearance.self, RecordingSource.self,
            CrateItem.self, Artist.self, MusicLabel.self, RecordingMetadata.self,
            DiscogsArtist.self, DiscogsReleaseRecord.self, BandcampRelease.self,
            BandcampArtistIndex.self, DigVisit.self, DigStep.self, ListeningEvent.self,
            ArtistPortrait.self, StoredEdge.self, GraphSnapshot.self
        ])
        try autoreleasepool {
            let container = try ModelContainer(
                for: previous,
                configurations: ModelConfiguration(schema: previous, url: storeURL)
            )
            let context = ModelContext(container)
            let recording = try RecordingStore(context: context)
                .upsert(title: "Vernal Equinox", artistName: "Jon Hassell")
            context.insert(CrateItem(recording: recording))
            try context.save()
        }

        let container = try ModelContainer(
            for: Persistence.schema,
            configurations: ModelConfiguration(schema: Persistence.schema, url: storeURL)
        )
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CrateItem>()), 1,
                       "The crate must survive the remembered answer being added")

        // And the round trip works in the migrated store.
        let store = ExploreOffersStore(context: context)
        XCTAssertNil(store.load())
        var offers = ExploreOffers()
        offers.next = [ExploreSuggestion(
            node: .artist("Tirzah"), reason: "Credited together", via: "Dean Blunt",
            kind: .collaborator, corroboration: 2, score: 1.1
        )]
        offers.movingToward = ExploreOffers.SceneOffer(
            city: "New York", title: "NEW YORK", sound: "JAZZ", size: "19 artists"
        )
        store.save(offers, crateRevision: 7)

        let read = try XCTUnwrap(store.load())
        XCTAssertEqual(read.crateRevision, 7)
        XCTAssertEqual(read.offers.next.first?.node.title, "Tirzah")
        XCTAssertEqual(read.offers.next.first?.corroboration, 2)
        XCTAssertEqual(read.offers.movingToward?.sound, "JAZZ")
    }

    /// The listening log added an entity to a schema that is already on
    /// people's machines with their crate in it. If adding one is not
    /// lightweight, `Persistence` falls through to `destroyStore()` and the
    /// crate goes with it — which is a far worse failure than the feature
    /// simply not working.
    func testAStoreWithoutTheListeningLogOpensWithItAndKeepsTheCrate() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("indigo-listening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")

        let recordingID = try autoreleasepool { () -> UUID in
            // Everything the shipping schema had before the log was added.
            // Spelled out rather than derived, so that this stays a test of a
            // specific migration rather than of whatever the schema is today.
            let previous = Schema([
                Track.self, Recording.self, MediaAppearance.self, RecordingSource.self,
                CrateItem.self, Artist.self, MusicLabel.self, RecordingMetadata.self,
                DiscogsArtist.self, DiscogsReleaseRecord.self, BandcampRelease.self,
                BandcampArtistIndex.self, DigVisit.self, DigStep.self,
                ArtistPortrait.self, StoredEdge.self, GraphSnapshot.self
            ])
            let container = try ModelContainer(
                for: previous,
                configurations: ModelConfiguration(schema: previous, url: storeURL)
            )
            let context = ModelContext(container)
            let recording = try RecordingStore(context: context)
                .upsert(title: "Vernal Equinox", artistName: "Jon Hassell")
            context.insert(CrateItem(recording: recording))
            try context.save()
            return recording.id
        }

        let container = try ModelContainer(
            for: Persistence.schema,
            configurations: ModelConfiguration(schema: Persistence.schema, url: storeURL)
        )
        let context = ModelContext(container)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CrateItem>()), 1,
                       "The crate must survive the listening log being added")
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Recording>()).first?.id, recordingID
        )

        // And the log works in the migrated store.
        let log = ListeningLog(context: context)
        XCTAssertNotNil(log.record(.artist("Jon Hassell"), action: .played, seconds: 900))
        XCTAssertEqual(log.all().count, 1)
    }
}
