//
//  SplitLaunch.swift
//  Indigo
//
//  What a launch does, from deciding to having a container: the one place that
//  runs the move, opens the split stores, and retires the old one.
//
//  It never throws. Anything it cannot do ends in a container in memory and an
//  explanation, with no file touched, because a launch that threw would be the
//  app not opening at all.
//

import Foundation
import SwiftData

nonisolated enum SplitLaunch {
    nonisolated struct Opened {
        let container: ModelContainer
        /// Set when the listener's data is not the thing that was opened, and the
        /// session is running unsaved.
        let failure: StoreOpenFailure?
    }

    static func open(layout: StoreLayout, crashAt: SplitMigration.Checkpoint? = nil) -> Opened {
        let store = SplitStateStore(url: layout.sidecar)
        let decision = LaunchDecision.decide(
            layout: layout, state: store.load(), exists: { FileManager.default.fileExists(atPath: $0.path) })
        Trace.note("store: launch decision \(decision)")

        do {
            switch decision {
            case .fresh:
                let container = try Persistence.openSplitStores(layout: layout)
                var state = SplitState(phase: .splitComplete)
                state.fresh = true
                try store.save(state)
                return Opened(container: container, failure: nil)

            case .split:
                let container = try Persistence.openSplitStores(layout: layout)
                recordLaunch(layout: layout, store: store)
                return Opened(container: container, failure: nil)

            case .migrate:
                let container = try SplitMigration(layout: layout, crashAt: crashAt).run()
                return Opened(container: container, failure: nil)

            case .safeMode(let why):
                return unsaved(StoreOpenFailure(role: .userData, url: layout.userData, reason: why, explanation: why))
            }
        } catch let failed as StoreOpenFailure {
            return unsaved(failed)
        } catch {
            var moving = false
            if case .migrate = decision { moving = true }
            let why = moving
                ? "Your library could not be moved to its new format, and nothing has been changed. It will be tried again. (\(error))"
                : "\(error)"
            return unsaved(StoreOpenFailure(role: .legacy, url: layout.legacy, reason: "\(error)", explanation: why))
        }
    }

    private static func unsaved(_ failure: StoreOpenFailure) -> Opened {
        guard let memory = try? Persistence.makeSplitContainer(userData: nil, local: nil) else {
            fatalError("Unable to create a SwiftData container")
        }
        return Opened(container: memory, failure: failure)
    }

    /// Counts a launch on the split stores. The old store is renamed to the
    /// archive only once the split has been marked finalized -- by `finalize`,
    /// which nothing in the app calls -- and never because of how many launches
    /// there have been. Never deletes.
    private static func recordLaunch(layout: StoreLayout, store: SplitStateStore) {
        guard case .valid(var state) = store.load(), state.phase == .splitComplete else { return }
        state.splitLaunches += 1
        if state.finalized, !state.archived { state.archived = retireLegacy(layout: layout) }
        try? store.save(state)
    }

    /// The deliberate act that says the split has proved itself. After it, the
    /// next launch on the split stores renames the old store to the archive.
    @discardableResult
    static func finalize(layout: StoreLayout) -> Bool {
        let store = SplitStateStore(url: layout.sidecar)
        guard case .valid(var state) = store.load(), state.phase == .splitComplete else { return false }
        state.finalized = true
        return (try? store.save(state)) != nil
    }

    /// Renames `default.store` and its log files to the archive, all or none.
    @discardableResult
    static func retireLegacy(layout: StoreLayout) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: layout.legacy.path),
              !fileManager.fileExists(atPath: layout.archive.path) else {
            return !fileManager.fileExists(atPath: layout.legacy.path)
        }
        let pairs = zip(layout.files(of: layout.legacy), layout.files(of: layout.archive))
            .filter { fileManager.fileExists(atPath: $0.0.path) }
        var moved: [(URL, URL)] = []
        for (from, to) in pairs {
            do { try fileManager.moveItem(at: from, to: to); moved.append((from, to)) } catch {
                for (from, to) in moved { try? fileManager.moveItem(at: to, to: from) }
                return false
            }
        }
        return true
    }
}
