//
//  CombinedArtistRadio.swift
//  Indigo
//
//  One artist's radio record, when the catalogue files them under more than
//  one row.
//
//  NTS publishes no ids, so its tracklists are filed by name, and "Prefuse73"
//  and "Prefuse 73" are two rows: nine plays on one, two on the other. Once
//  Discogs has verified the spellings are one artist (`ArtistIdentityResolver`)
//  the page reads both rows and shows them as one record. Nothing is merged
//  in the catalogue, and every play keeps the name its tracklist credited.
//

import Foundation

extension Catalog {
    struct CombinedArtistRadio: Sendable, Equatable {
        let summary: ArtistRadioSummary
        let appearances: [ArtistRadioAppearance]
        let relations: [RadioRelation]
        /// The rows read, the primary first.
        let artistIDs: [UUID]
    }

    /// What one row of the catalogue holds.
    struct ArtistRadioPart: Sendable, Equatable {
        let summary: ArtistRadioSummary
        let appearances: [ArtistRadioAppearance]
        let relations: [RadioRelation]
    }

    /// Several rows' records as one, the first part being the primary.
    ///
    /// Plays are disjoint between rows — a tracklist line is filed under one
    /// artist — so they add up exactly. Episodes, shows and hosts can be
    /// shared (one show playing both spellings), so they are counted from the
    /// plays themselves when every row's plays were read in full, and added
    /// up otherwise, which can only overcount by the episodes both spellings
    /// were heard in.
    static func combinedRadio(_ parts: [ArtistRadioPart]) -> CombinedArtistRadio? {
        guard let primary = parts.first else { return nil }
        let ids = parts.map(\.summary.artistID)
        let rows = Set(ids)

        var seen = Set<UUID>()
        let plays = parts.flatMap(\.appearances)
            .filter { seen.insert($0.appearanceID).inserted }
            .sorted { lhs, rhs in
                switch (lhs.airedAt, rhs.airedAt) {
                case let (a?, b?) where a != b: return a > b
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    if lhs.episodeID != rhs.episodeID { return lhs.episodeID.uuidString < rhs.episodeID.uuidString }
                    return (lhs.trackIndex ?? 0) < (rhs.trackIndex ?? 0)
                }
            }

        let readInFull = parts.allSatisfy { $0.appearances.count >= $0.summary.appearanceCount }
        let episodes = readInFull ? Set(plays.map(\.episodeID)).count : parts.map(\.summary.episodeCount).reduce(0, +)
        let shows = readInFull ? Set(plays.compactMap(\.showID)).count : parts.map(\.summary.showCount).reduce(0, +)
        let hosts = readInFull ? Set(plays.compactMap(\.hostName)).count : parts.map(\.summary.hostCount).reduce(0, +)

        var topShows: [UUID: ArtistRadioSummary.TopShow] = [:]
        for show in parts.flatMap(\.summary.topShows) {
            if var held = topShows[show.showID] {
                held.appearanceCount += show.appearanceCount
                topShows[show.showID] = held
            } else {
                topShows[show.showID] = show
            }
        }

        // The same edge seen from two rows is one edge with both rows'
        // evidence. An edge from one row to another of the same artist says
        // nothing about who they are played beside, and is dropped.
        var relations: [String: RadioRelation] = [:]
        var order: [String] = []
        for relation in parts.flatMap(\.relations) where !(relation.entityType == "artist" && rows.contains(relation.entityID)) {
            if var held = relations[relation.id] {
                held.evidenceCount += relation.evidenceCount
                held.confidence = [held.confidence, relation.confidence].compactMap { $0 }.max()
                relations[relation.id] = held
            } else {
                relations[relation.id] = relation
                order.append(relation.id)
            }
        }

        var summary = primary.summary
        summary.appearanceCount = parts.map(\.summary.appearanceCount).reduce(0, +)
        summary.episodeCount = episodes
        summary.showCount = shows
        summary.hostCount = hosts
        summary.firstAppearanceAt = parts.compactMap(\.summary.firstAppearanceAt).min()
        summary.latestAppearanceAt = parts.compactMap(\.summary.latestAppearanceAt).max()
        summary.topShows = topShows.values.sorted {
            $0.appearanceCount != $1.appearanceCount
                ? $0.appearanceCount > $1.appearanceCount
                : $0.showID.uuidString < $1.showID.uuidString
        }

        return CombinedArtistRadio(
            summary: summary,
            appearances: plays,
            relations: order.compactMap { relations[$0] }
                .sorted { $0.evidenceCount != $1.evidenceCount ? $0.evidenceCount > $1.evidenceCount : $0.id < $1.id },
            artistIDs: ids
        )
    }
}
