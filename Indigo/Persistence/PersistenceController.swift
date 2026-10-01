//
//  PersistenceController.swift
//  Indigo
//
//  A single SwiftData container for the whole app.
//
//  What happens to a store that cannot be opened depends on what is in it, and
//  that is decided by which models it holds, never by which error came back.
//  A store of caches is rebuilt. A store holding anything the listener made --
//  the crate, their listening history, their dig history -- is never deleted:
//  the app opens an unsaved in-memory store for the session, leaves the files
//  exactly where they are, and says so.
//
//  This used to delete `default.store` on any failure. That store holds the
//  crate.
//

import Foundation
import SwiftData

/// Whether a store may be thrown away when it will not open.
nonisolated enum StoreRole: Equatable {
    /// Holds something the listener made. Never deleted.
    case userData
    /// Holds only what can be fetched or rebuilt again.
    case cache

    var mayBeDestroyed: Bool { self == .cache }

    /// The models that are the listener's own. A store holding any one of them
    /// is `userData`; this list is the only place that is decided.
    static var userOwnedModels: [any PersistentModel.Type] {
        [CrateItem.self, ListeningEvent.self, DigVisit.self, DigStep.self]
    }

    static func role(holding models: [any PersistentModel.Type]) -> StoreRole {
        let owned = Set(userOwnedModels.map { ObjectIdentifier($0) })
        return models.contains { owned.contains(ObjectIdentifier($0)) } ? .userData : .cache
    }
}

/// A store that would not open and was left alone.
nonisolated struct StoreOpenFailure: Error, LocalizedError, Equatable {
    let role: StoreRole
    let url: URL
    let reason: String

    var errorDescription: String? {
        "The store at \(url.path) could not be opened: \(reason)"
    }
}

enum Persistence {
    /// The current version of the store's schema; see `IndigoSchema.swift`.
    static let schema = Schema(versionedSchema: IndigoSchemaV1.self)

    /// Where the store the app has always used lives. Read from SwiftData's own
    /// default rather than rebuilt from a path, so it can never point at a
    /// different file from the one an existing install wrote.
    static let storeURL: URL = ModelConfiguration(schema: schema).url

    /// Everything is in one store until the split into `UserData` and `Local`,
    /// so it holds the crate and is `userData`.
    static let storeRole = StoreRole.role(holding: IndigoSchemaV1.models)

    static let container: ModelContainer = makeContainer()

    /// Set when the store on disk could not be opened and the session is
    /// running unsaved. Read through `openFailure`, which makes sure the
    /// container has been asked for first.
    private nonisolated(unsafe) static var failure: StoreOpenFailure?

    static var openFailure: StoreOpenFailure? {
        _ = container
        return failure
    }

    /// Whether this process is a test host rather than the app somebody is
    /// using.
    ///
    /// The XCTest host *is* Indigo, with the listener's real container, so
    /// anything the app does at launch a test run does to their data. One-shot
    /// repairs are gated on this. `Trace` reads the same variable to decide
    /// where to write.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func makeContainer() -> ModelContainer {
        do {
            return try openStore(role: storeRole, schema: schema, at: storeURL)
        } catch let failed as StoreOpenFailure {
            failure = failed
            Trace.note("store: \(failed.errorDescription ?? "could not be opened"); running unsaved")
        } catch {
            failure = StoreOpenFailure(role: storeRole, url: storeURL, reason: "\(error)")
        }
        // The files stay exactly as they are. This session runs in memory so
        // the app still launches, and nothing it does is written anywhere.
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let fallback = try? ModelContainer(for: schema, configurations: memory) else {
            fatalError("Unable to create a SwiftData container")
        }
        return fallback
    }

    /// Opens the store at `url`. A `.cache` store that will not open is deleted
    /// and made again; a `.userData` store is never touched, and the failure is
    /// thrown for the caller to show.
    nonisolated static func openStore(
        role: StoreRole,
        schema: Schema,
        migrationPlan: (any SchemaMigrationPlan.Type)? = IndigoMigrationPlan.self,
        at url: URL
    ) throws -> ModelContainer {
        func open() throws -> ModelContainer {
            let configuration = ModelConfiguration(schema: schema, url: url)
            return try ModelContainer(
                for: schema, migrationPlan: migrationPlan, configurations: configuration)
        }
        do {
            return try open()
        } catch {
            guard role.mayBeDestroyed else {
                throw StoreOpenFailure(role: role, url: url, reason: "\(error)")
            }
            destroyStore(at: url)
            do {
                return try open()
            } catch {
                throw StoreOpenFailure(role: role, url: url, reason: "\(error)")
            }
        }
    }

    /// Removes one store's files, and only those. Reached only for `.cache`.
    nonisolated private static func destroyStore(at url: URL) {
        let fileManager = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
