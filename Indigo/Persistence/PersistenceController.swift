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
    /// The listener's old combined store, and the archive it becomes. Holds
    /// everything, including what they made. Never deleted, and never opened
    /// by SwiftData with a schema that leaves anything out.
    case legacy
    /// Holds only what can be fetched or rebuilt again.
    case cache

    var mayBeDestroyed: Bool { self == .cache }

    /// The models that are the listener's own. A store holding any one of them
    /// is `userData`; this list is the only place that is decided.
    static var userOwnedModels: [any PersistentModel.Type] {
        [CrateItem.self, ListeningEvent.self, DigVisit.self, DigStep.self, DigCounter.self]
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
    /// A plain sentence for the listener, when the cause is one the app knows
    /// and not an error SwiftData reported.
    var explanation: String? = nil

    var errorDescription: String? {
        "The store at \(url.path) could not be opened: \(reason)"
    }
}

/// Whether `UserData` mirrors to the listener's private CloudKit database.
///
/// Off unless a caller says otherwise, so that a test, the move from the old
/// store, or a rehearsal never syncs by accident: with the iCloud entitlement
/// signed in, anything that is not told is a risk. Only the launch path
/// (`Persistence.makeContainer`) asks for `.privateDatabase`, and only for the
/// store the listener made. `Local` is never mirrored.
nonisolated enum UserDataSync: Equatable {
    case off
    case privateDatabase

    static let containerID = "iCloud.com.oblaststudio.Indigo"

    /// A launch argument that turns it off for one run -- to open the store
    /// without mirroring while something is looked into.
    static let disableArgument = "-INDIGO_USERDATA_SYNC_OFF"

    static func forLaunch(arguments: [String]) -> UserDataSync {
        arguments.contains(disableArgument) ? .off : .privateDatabase
    }

    var database: ModelConfiguration.CloudKitDatabase {
        switch self {
        case .off: return .none
        case .privateDatabase: return .private(Self.containerID)
        }
    }
}

enum Persistence {
    /// The current version of the store's schema; see `IndigoSchema.swift`.
    static let schema = Schema(versionedSchema: IndigoSchemaCurrent.self)

    /// Where the three stores live; see `StoreLayout`.
    static let layout = StoreLayout.standard

    /// The old combined store. Kept as a name for the one place tests compare
    /// it with SwiftData's own default: it is the file `layout.legacy` names.
    static let storeURL: URL = ModelConfiguration(schema: schema).url

    static let container: ModelContainer = makeContainer()

    /// Set when the listener's data could not be opened and the session is
    /// running unsaved. Read through `openFailure`, which makes sure the
    /// container has been asked for first.
    private nonisolated(unsafe) static var failure: StoreOpenFailure?

    static var openFailure: StoreOpenFailure? {
        _ = container
        return failure
    }

    /// Whether what the listener makes can be written down. False while their
    /// data has failed to open and the session is running unsaved: the crate,
    /// the listening log and the dig history refuse their writes rather than
    /// keep rows that vanish at quit.
    ///
    /// Not routed through `container`, so it can be read from any actor. The
    /// container is asked for at launch, before anything can write, so by the
    /// time it matters the failure has been recorded.
    nonisolated static var userDataWritable: Bool { failure == nil }

    nonisolated static let userDataUnavailableNotice =
        "Your library couldn't be opened, so nothing can be saved to your crate or history right now."

    /// Whether this process is a test host rather than the app somebody is
    /// using.
    ///
    /// The XCTest host *is* Indigo, with the listener's real container, so
    /// anything the app does at launch a test run does to their data. One-shot
    /// repairs are gated on this. `Trace` reads the same variable to decide
    /// where to write.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || isUITesting
    }

    /// The launch argument every UI test passes. A UI test launches the app as
    /// its own process, which has no XCTest variable in its environment and
    /// used to open the listener's real store: the first full run of the suite
    /// migrated and backfilled it. With this argument the process counts as a
    /// test, and a test's store is in memory.
    nonisolated static let uiTestingArgument = "-INDIGO_UI_TESTING"

    nonisolated static func isUITesting(arguments: [String]) -> Bool {
        arguments.contains(uiTestingArgument)
    }

    static var isUITesting: Bool {
        isUITesting(arguments: ProcessInfo.processInfo.arguments)
    }

    // MARK: - The container

    private static func makeContainer() -> ModelContainer {
        // A test run never opens the listener's stores. The XCTest host *is*
        // Indigo, and a UI test launches it as a child process; either one
        // opened the real store, migrated it, and wrote to it. Tests that
        // need a store make their own, in memory or on a temporary disk.
        if isRunningTests {
            guard let container = try? makeSplitContainer(userData: nil, local: nil) else {
                fatalError("Unable to create an in-memory container for testing")
            }
            return container
        }

        let sync = UserDataSync.forLaunch(arguments: ProcessInfo.processInfo.arguments)
        let opened = SplitLaunch.open(layout: layout, sync: sync)
        failure = opened.failure
        if opened.syncing { MirroringMonitor.start() }
        if let failed = opened.failure {
            Trace.note("store: \(failed.errorDescription ?? "unknown"); running unsaved")
        }
        return opened.container
    }

    /// One container over two stores. `userData` and `local` are file URLs, or
    /// nil for a store in memory. The schema is the whole thing and each store
    /// is told which models are its own, so that nothing is ever opened with a
    /// schema that leaves a model out.
    ///
    /// `sync` applies to `UserData` alone, and only to one on disk: a store in
    /// memory has nothing to mirror, and `Local` is never mirrored.
    nonisolated static func makeSplitContainer(
        userData: URL?, local: URL?, migrationPlan: (any SchemaMigrationPlan.Type)? = IndigoMigrationPlan.self,
        sync: UserDataSync = .off
    ) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: IndigoSchemaCurrent.self),
            migrationPlan: migrationPlan,
            configurations: splitConfigurations(userData: userData, local: local, sync: sync))
    }

    /// The two configurations. The one place that decides which store mirrors:
    /// `UserData`, when it is on disk and `sync` asks, and nothing else.
    nonisolated static func splitConfigurations(
        userData: URL?, local: URL?, sync: UserDataSync
    ) -> [ModelConfiguration] {
        func configuration(
            _ name: String, _ models: [any PersistentModel.Type], _ url: URL?,
            _ cloudKit: ModelConfiguration.CloudKitDatabase
        ) -> ModelConfiguration {
            let schema = Schema(models)
            if let url {
                return ModelConfiguration(name, schema: schema, url: url, cloudKitDatabase: cloudKit)
            }
            return ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        return [
            configuration("UserData", IndigoSchemaCurrent.userDataModels, userData, sync.database),
            configuration("Local", IndigoSchemaCurrent.localModels, local, .none)
        ]
    }

    /// Opens `UserData.store` and `Local.store`, creating them if they are new.
    /// If `Local` is what will not open it is thrown away and made again, since
    /// it holds nothing that cannot be fetched; if `UserData` will not open,
    /// nothing is touched and the failure is thrown.
    ///
    /// If mirroring is what will not open, the listener's data is still theirs
    /// to use: it is opened again without mirroring, and that is noted. A sync
    /// that cannot start must never be what stops the crate being written to.
    nonisolated static func openSplitStores(layout: StoreLayout, sync: UserDataSync = .off) throws -> ModelContainer {
        try openSplitStoresReporting(layout: layout, sync: sync).container
    }

    nonisolated static func openSplitStoresReporting(
        layout: StoreLayout, sync: UserDataSync = .off
    ) throws -> (container: ModelContainer, syncing: Bool) {
        if sync != .off {
            do {
                return (try openSplitStoresUnsynced(layout: layout, sync: sync), true)
            } catch {
                Trace.note("sync: could not open UserData with mirroring (\(error)); opening it without")
            }
        }
        return (try openSplitStoresUnsynced(layout: layout, sync: .off), false)
    }

    nonisolated private static func openSplitStoresUnsynced(layout: StoreLayout, sync: UserDataSync) throws -> ModelContainer {
        // A store from before counter components owes its counts to them. Noted
        // before it is opened -- opening migrates it, and then it can no longer
        // tell -- and paid once it is. See `CounterBaseline`.
        CounterBaseline.prepare(layout: layout)
        let container = try openSplitStoresOnce(layout: layout, sync: sync)
        do {
            try CounterBaseline.complete(layout: layout, context: ModelContext(container))
        } catch {
            throw StoreOpenFailure(
                role: .userData, url: layout.userData, reason: "the counts could not be moved into components: \(error)")
        }
        return container
    }

    nonisolated private static func openSplitStoresOnce(layout: StoreLayout, sync: UserDataSync) throws -> ModelContainer {
        do {
            return try makeSplitContainer(userData: layout.userData, local: layout.local, sync: sync)
        } catch {
            // Is it the cache? Open the listener's data alone, beside a cache in
            // memory: if that works, the cache was the problem.
            guard (try? makeSplitContainer(userData: layout.userData, local: nil)) != nil else {
                throw StoreOpenFailure(role: .userData, url: layout.userData, reason: "\(error)")
            }
            destroyCache(at: layout.local, layout: layout)
            do {
                return try makeSplitContainer(userData: layout.userData, local: layout.local, sync: sync)
            } catch {
                throw StoreOpenFailure(role: .cache, url: layout.local, reason: "\(error)")
            }
        }
    }

    /// Opens one store at `url`. A `.cache` store that will not open is deleted
    /// and made again; anything else is never touched, and the failure is thrown
    /// for the caller to show.
    nonisolated static func openStore(
        role: StoreRole,
        schema: Schema,
        migrationPlan: (any SchemaMigrationPlan.Type)? = IndigoMigrationPlan.self,
        at url: URL
    ) throws -> ModelContainer {
        func open() throws -> ModelContainer {
            let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
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

    /// The only deletion of a store the app does. It refuses anything the layout
    /// does not call a cache, so a path that is wrong costs nothing.
    nonisolated static func destroyCache(at url: URL, layout: StoreLayout) {
        guard layout.role(of: url).mayBeDestroyed else { return }
        destroyStore(at: url)
    }
}
