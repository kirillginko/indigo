//
//  MusicianFirst.swift
//  Indigo
//
//  DIG, musician-first: the switch, and what a credit is for.
//
//  Discogs credits a record's engineers beside its players, and DIG followed
//  them alike, so a route out of a jazz record could lead through the
//  mastering engineer into a page of other people's masters. Behind this
//  switch a credit is sorted by what kind of contribution it was, and the
//  technical ones -- recorded, mixed, mastered, edited by -- stay on the
//  release page and stop being routes. A producer is never technical: in
//  electronic music and hip-hop the producer often made the record.
//
//  Off, nothing changes: `CreditRole.kind(of:)` and every edge are exactly as
//  before. On only in a development build, by launch argument
//  (`-INDIGO_DIG_MUSICIAN_FIRST YES`), or in a test. Never in a release build.
//

import Foundation

nonisolated enum MusicianFirst {
    #if DEBUG
    /// A development build's own switch. Compiled into development builds
    /// only.
    static let switchKey = "INDIGO_DIG_MUSICIAN_FIRST"
    #endif

    /// For tests and measurements: on or off whatever the defaults say.
    nonisolated(unsafe) static var override: Bool?

    static var isEnabled: Bool {
        if let override { return override }
        // Hear next is DIG, and brings DIG's view with it. For You's own
        // experiment does not: it filters in its own ranker.
        if DigRecommendations.isEnabled { return true }
        #if DEBUG
        return UserDefaults.standard.bool(forKey: switchKey)
        #elseif INDIGO_INTERNAL
        return true
        #else
        return false
        #endif
    }

    #if INDIGO_INTERNAL
    /// Written into an internal archive (`SWIFT_ACTIVE_COMPILATION_CONDITIONS`
    /// gains `INDIGO_INTERNAL` on the archive command line only), so
    /// Scripts/release-enrichment-guard.sh can refuse it for the App Store.
    static let internalBuild = "INDIGO_INTERNAL_BUILD: musician-first DIG and Hear next on"
    #endif

    /// Whether a credit leads anywhere under the switch: off, every musical
    /// credit does, as before; on, every one but the technical.
    static func isRoute(_ role: String?) -> Bool {
        guard CreditRole.isMusical(role) else { return false }
        return !isEnabled || ContributorRole.of(credit: role) != .technical
    }

    /// A credit edge whose stated job is technical: "Mastered By on X",
    /// "Mixed By on X (A1)". Read from the edge's own words, so it holds for
    /// the device's credits and the catalogue's bundles alike. See
    /// `ContributorRole.of(edge:)`.
    static func isTechnicalCredit(_ edge: MusicEdge) -> Bool {
        ContributorRole.of(edge: edge) == .technical
    }
}

extension EdgeSet {
    /// What DIG shows of a walk: without technical credits when musician-first
    /// is on, everything otherwise. Only DIG's readers take this view -- the
    /// graph itself, and For You, which reads it, are the same either way.
    var forDIG: EdgeSet {
        guard MusicianFirst.isEnabled else { return self }
        var kept = EdgeSet()
        kept.insert(contentsOf: all.filter { !MusicianFirst.isTechnicalCredit($0) })
        return kept
    }
}

/// For You ranked by `MusicianFirstRanker` instead of `ExploreRanker`: its
/// own development switch (`-INDIGO_FORYOU_MUSICIAN_FIRST YES`); it leaves
/// technical credits out in its own ranking, never by changing the graph.
/// Off, For You is exactly as before, whatever DIG is set to. Never in a
/// release build.
nonisolated enum ForYouMusicianFirst {
    #if DEBUG
    static let switchKey = "INDIGO_FORYOU_MUSICIAN_FIRST"
    #endif

    nonisolated(unsafe) static var override: Bool?

    static var isEnabled: Bool {
        if let override { return override }
        #if DEBUG
        return UserDefaults.standard.bool(forKey: switchKey)
        #else
        return false
        #endif
    }
}

nonisolated extension CreditRole {
    /// What sort of part somebody had in a record, for ranking routes: the
    /// shared taxonomy, `ContributorRole`. Nil only when there is no role.
    static func contribution(of role: String?) -> ContributorRole? {
        ContributorRole.of(credit: role)
    }
}
