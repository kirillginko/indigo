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
}
