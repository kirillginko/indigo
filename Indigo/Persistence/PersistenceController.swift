//
//  PersistenceController.swift
//  Indigo
//
//  A single SwiftData container for the whole app. A store that cannot be
//  opened is rebuilt rather than crashing the app — the library index is a
//  cache of the user's files, never the source of truth.
//

import Foundation
import SwiftData

enum Persistence {
    static let schema = Schema([
        Track.self,
        Recording.self,
        MediaAppearance.self,
        RecordingSource.self,
        CrateItem.self,
        Artist.self,
        MusicLabel.self,
        RecordingMetadata.self
    ])

    static let container: ModelContainer = makeContainer()

    private static func makeContainer() -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            // Most likely an incompatible store from an earlier build. Discard and retry.
            destroyStore()
            if let rebuilt = try? ModelContainer(for: schema, configurations: configuration) {
                return rebuilt
            }
            // Last resort: run in memory so the app still launches.
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            guard let fallback = try? ModelContainer(for: schema, configurations: memory) else {
                fatalError("Unable to create a SwiftData container")
            }
            return fallback
        }
    }

    private static func destroyStore() {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            try? fileManager.removeItem(at: support.appendingPathComponent(name))
        }
    }
}
