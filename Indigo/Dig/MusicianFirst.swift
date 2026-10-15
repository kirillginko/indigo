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
        return !isEnabled || CreditRole.contribution(of: role) != .technical
    }

    /// A credit edge whose stated job is technical: "Mastered By on X",
    /// "Mixed By on X (A1)". Read from the edge's own words, so it holds for
    /// the device's credits and the catalogue's bundles alike.
    static func isTechnicalCredit(_ edge: MusicEdge) -> Bool {
        guard edge.kind.isCreditBacked, let role = DigRecommender.role(in: edge.reason) else { return false }
        return CreditRole.contribution(of: role) == .technical
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
    /// What sort of part somebody had in a record, for ranking routes. Finer
    /// than `Kind` where it matters to discovery and coarser where it does
    /// not: who played or sang, who made the music up or shaped it, and who
    /// worked the equipment.
    nonisolated enum Contribution: String, Hashable, Sendable, CaseIterable {
        /// Played, sang, conducted, featured, programmed -- on the record.
        case performing
        /// Wrote, composed, arranged, produced, remixed, mixed as a DJ.
        case creative
        /// Engineered, recorded, mixed, mastered, edited, restored.
        case technical

        /// Strongest first: a bassist who also engineered is a bassist.
        var rank: Int {
            switch self {
            case .performing: 0
            case .creative: 1
            case .technical: 2
            }
        }
    }

    /// The jobs that worked the equipment rather than made the music.
    /// "Mix" alone is the mix engineer; a remix or a DJ's mix is not.
    private static let technicalJobs = [
        "engineer", "master", "recorded", "recording", "mixed", "mixing", "edited", "editing",
        "transfer", "restor", "technician", "tape op", "remaster", "lathe", "cut by", "programming [technical",
        // Sleeve and screen work the older list does not name.
        "art direction", "graphic", "styling", "video", "film", "creative direction", "photo"
    ]

    /// What kind of part a credit was, or nil when it is not a musical one.
    /// Read like `kind(of:)`: the strongest of the jobs a role names.
    static func contribution(of role: String?) -> Contribution? {
        guard let role, isMusical(role) else { return nil }
        var best: Contribution?
        for part in role.lowercased().split(separator: ",") {
            let job = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !job.isEmpty, isMusical(String(job)) else { continue }
            let found: Contribution
            // Before production: an executive producer or a supervisor ran
            // the session, not the music.
            if job.contains("executive") || job.contains("supervis") || job.contains("coordinat") {
                found = .technical
            } else if job.contains("remix") || job.contains("dj mix") || job.contains("produc")
                || job.contains("written") || job.contains("compos") || job.contains("lyric")
                || job.contains("songwriter") || job.contains("arrang") {
                found = .creative
            } else if technicalJobs.contains(where: { job.contains($0) }) || job == "mix" {
                found = .technical
            } else {
                found = .performing
            }
            if best == nil || found.rank < (best?.rank ?? .max) { best = found }
        }
        return best
    }
}
