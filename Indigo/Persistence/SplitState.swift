//
//  SplitState.swift
//  Indigo
//
//  Where the move from one store to two has got to, and what each launch does
//  about it.
//
//  The state is a small file beside the stores, written atomically, because
//  it has to be readable when neither store will open. It records how far the
//  move has got and nothing the stores can tell us for themselves: the work
//  at each phase is repeatable, so an interrupted phase is simply done again,
//  and the databases -- not this file -- say whether it is finished.
//
//  Before `splitComplete` the old store is authoritative and the new ones are
//  a work in progress nobody sees. From `splitComplete` on, `UserData` is the
//  truth and the old store is an archive: this launch never goes back to it,
//  because by then it is behind, and a launch that fell back to it would show
//  the listener a crate that no longer matches what they have made, and take
//  writes into it.
//

import Foundation

nonisolated enum SplitPhase: String, Codable, CaseIterable, Sendable {
    /// Nothing done yet.
    case legacy
    /// Building `Local.store` from a copy of the old store.
    case copyingLocal
    /// Moving the listener's own rows into `UserData.store`.
    case migratingUserData
    /// Checking that what arrived is what was there.
    case verifying
    /// Done, and the one-way door is shut.
    case splitComplete
}

nonisolated struct SplitState: Codable, Equatable, Sendable {
    var phase: SplitPhase
    /// The version of this procedure, so a later one can tell what an earlier
    /// one meant.
    var procedure: Int = 1
    /// What the old store held when the move began, and what arrived, by entity.
    var legacyCounts: [String: Int]?
    var migratedCounts: [String: Int]?
    /// Launches that have opened the split stores since `splitComplete`. The
    /// old store is renamed to the archive only after several.
    var splitLaunches: Int = 0
    var archived: Bool = false
    var fresh: Bool = false
    var updatedAt: Date = Date()
}

/// The state file, and what reading it can come back with.
nonisolated struct SplitStateStore: Sendable {
    let url: URL

    nonisolated enum Loaded: Equatable {
        case missing
        case valid(SplitState)
        /// There is a file and it cannot be read. Not the same as missing: a
        /// launch that treated it as missing could start the move again, or
        /// make fresh stores, over a split that had already finished.
        case unreadable
    }

    func load() -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(SplitState.self, from: data) else { return .unreadable }
        return .valid(state)
    }

    /// Written to a temporary file and moved into place, so a launch that is cut
    /// off leaves the previous state or the new one, never half of either.
    func save(_ state: SplitState) throws {
        var state = state
        state.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(state)
        let temporary = url.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}

/// What a launch does, decided from the state file and which files exist, and
/// from nothing else.
nonisolated enum LaunchDecision: Equatable, Sendable {
    /// Nothing exists. Make both stores empty and record the split as complete.
    case fresh
    /// The split is complete. Open `UserData` and `Local`.
    case split
    /// The old store is authoritative; carry the move on from here.
    case migrate(from: SplitPhase)
    /// Something is not as it should be and no choice would be safe to make
    /// silently. The session runs unsaved and says why; nothing is opened
    /// destructively, deleted, or fallen back to.
    case safeMode(String)

    static func decide(
        layout: StoreLayout, state: SplitStateStore.Loaded, exists: (URL) -> Bool
    ) -> LaunchDecision {
        let legacyExists = exists(layout.legacy)
        let userDataExists = exists(layout.userData)

        switch state {
        case .unreadable:
            return .safeMode("The record of the move to the new stores cannot be read.")

        case .valid(let value) where value.phase == .splitComplete:
            // Committed. The old store is behind and is never the answer.
            guard userDataExists else {
                return .safeMode("Your data store is missing, and the old store is an archive that is behind it.")
            }
            return .split

        case .valid(let value):
            guard legacyExists else {
                return .safeMode("The old store is gone partway through moving your data.")
            }
            return .migrate(from: value.phase)

        case .missing:
            if userDataExists {
                // A synced store with no record of how it got there. It may be
                // complete; it may be half a move. Either way it is not ours to
                // guess about.
                return .safeMode("There is a data store but no record of the move that made it.")
            }
            return legacyExists ? .migrate(from: .legacy) : .fresh
        }
    }
}
