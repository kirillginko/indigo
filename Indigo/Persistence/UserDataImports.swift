//
//  UserDataImports.swift
//  Indigo
//
//  What another device changed, as revisions the views can key on.
//
//  The crate's revision moved only when this process saved, so an import from
//  CloudKit changed the rows and nothing that was worked out from them: EXPLORE
//  went on offering what it had offered before the other device crated
//  something, for up to a quarter of an hour, and the crate's own lists waited
//  for the next local save to re-read. `HistoryObserver` already knows which
//  models an import touched; this turns that into the two numbers those
//  surfaces key on.
//
//  Held here rather than on a store because the first pass runs in the app's
//  `init`, before any store exists to tell -- and an import made while the app
//  was closed is exactly what that pass finds.
//
//  An import arrives in many small passes, and a first one in hundreds. A bump
//  waits until the passes have gone quiet, so one import is one rebuild.
//

import Foundation
import Observation

@MainActor
@Observable
final class UserDataImports {
    static let shared = UserDataImports()

    /// Moves when another device changed the crate.
    private(set) var crateRevision = 0
    /// Moves when another device changed anything EXPLORE reads: the crate,
    /// the listening log, or the dig history its starting points come from.
    private(set) var exploreRevision = 0

    /// The synced models EXPLORE's offers are worked out from.
    /// `DigStep` is not one: the engine never reads it.
    nonisolated static let exploreInputs: Set<String> = ["CrateItem", "ListeningEvent", "DigVisit", "DigCounter"]

    /// How long the passes have to be quiet before a bump, and the most a
    /// steady stream of them can hold one back.
    nonisolated static let quiet: Duration = .milliseconds(1500)
    nonisolated static let longest: Duration = .seconds(10)

    @ObservationIgnored private var pendingCrate = false
    @ObservationIgnored private var pendingExplore = false
    @ObservationIgnored private var firstPending: ContinuousClock.Instant?
    @ObservationIgnored private var flush: Task<Void, Never>?

    /// Called with what a pass found another writer had touched.
    func note(_ entities: Set<String>) {
        let crate = entities.contains("CrateItem")
        let explore = !entities.isDisjoint(with: Self.exploreInputs)
        guard crate || explore else { return }
        pendingCrate = pendingCrate || crate
        pendingExplore = pendingExplore || explore
        let now = ContinuousClock.now
        let first = firstPending ?? now
        firstPending = first
        let wait = min(Self.quiet, max(.zero, first + Self.longest - now))
        flush?.cancel()
        flush = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.apply()
        }
    }

    /// Bumps now, for a test that does not want to wait.
    func apply() {
        flush?.cancel()
        flush = nil
        firstPending = nil
        if pendingCrate { crateRevision &+= 1 }
        if pendingExplore { exploreRevision &+= 1 }
        pendingCrate = false
        pendingExplore = false
    }

    /// Never freed; a main-actor deinit hop would abort if it were.
    nonisolated deinit {}
}
