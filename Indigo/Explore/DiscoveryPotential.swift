//
//  DiscoveryPotential.swift
//  Indigo
//
//  Whether an artist leads anywhere, in a few numbers, without walking their
//  neighbourhood.
//
//  Ranking For You musician-first asks one question of every candidate: is
//  there somewhere to go from them? Walking each candidate's graph to answer
//  it cost a second even warm. This answers it from what is already held:
//
//  - **A catalogue bundle** (`CataloguePilot`), summarised here: the verified
//    musicians it names, the releases behind them, and whether everyone it
//    names is technical. Worked out on the device from the bundle as
//    published -- the bundles themselves are not rebuilt or republished.
//  - **A stored graph answer** (`StoredEdge`), when the candidate's page was
//    already worked out under the current rules: its musician routes counted
//    from one indexed read.
//  - Otherwise nothing, which the ranking treats as neutral.
//
//  Technical contributors are kept as a list, not counted as musicians: they
//  can be the step between two musicians (`DigRouteMeasurement` counts them
//  so when they are specific), never the destination.
//

import Foundation
import SwiftData

nonisolated struct DiscoveryPotential: Codable, Equatable, Sendable {
    /// The rules this was worked out by. Changing them changes the number.
    static let currentVersion = 1

    var version = DiscoveryPotential.currentVersion
    /// Distinct musicians the documents connect them to by Discogs id: made a
    /// record together, played, sang, wrote or produced on one.
    var musicians: Int
    /// Distinct releases those connections rest on.
    var supportingReleases: Int
    /// Technical contributors named, by Discogs id: possible steps, not routes.
    var technical: [Int]
    /// Everyone named is technical: a page that would lead only to engineers.
    var technicalOnly: Bool { musicians == 0 && !technical.isEmpty }

    /// The summary of one bundle, by the musician-first rules.
    static func of(_ bundle: ArtistBundle) -> DiscoveryPotential {
        let own = bundle.artist.discogsID
        var musicians = Set<Int>(), technical = Set<Int>(), releases = Set<Int>()
        func person(_ ref: ArtistBundle.Person) -> Int? {
            guard let id = ref.discogsID, id != own, !CataloguePilot.standIns.contains(id) else { return nil }
            return id
        }
        for collaborator in bundle.collaborators {
            guard let id = person(collaborator.artist) else { continue }
            let jobs = collaborator.how.filter { $0 != "joint" && !BundleEdges.appearances.contains($0) }
            if collaborator.how.contains("joint") || jobs.contains(where: { CreditRole.contribution(of: $0).map { $0 != .technical } ?? false }) {
                musicians.insert(id)
                releases.formUnion(collaborator.releases)
            } else if !jobs.isEmpty, jobs.allSatisfy({ CreditRole.contribution(of: $0) == .technical }) {
                technical.insert(id)
            }
        }
        for credit in bundle.credits {
            guard let id = person(credit.artist) else { continue }
            for role in credit.roles where role.kind != nil {
                if CreditRole.contribution(of: role.role) == .technical {
                    technical.insert(id)
                } else {
                    musicians.insert(id)
                    releases.formUnion(role.releases.map(\.id))
                }
            }
        }
        technical.subtract(musicians)
        return DiscoveryPotential(musicians: musicians.count, supportingReleases: releases.count,
                                  technical: technical.sorted())
    }
}

/// How many musician routes lead on from a candidate, from what is held.
nonisolated struct OnwardIndex {
    let context: ModelContext
    /// A held catalogue bundle for an entry, or nil. Replaced in tests.
    var bundle: (Int) -> ArtistBundle? = { id in
        CataloguePilot.shared.isEnabled ? CataloguePilot.shared.bundle(for: id) : nil
    }

    /// Musician routes out of a place, or nil when nothing held says.
    func count(for node: MusicNode) -> Int? {
        guard node.kind == .artist else { return nil }
        if let id = node.discogsID, let held = bundle(id) { return DiscoveryPotential.of(held).musicians }
        for identity in Set([node.id, MusicNode.artist(node.title).id]) {
            if let stored = storedCount(identity) { return stored }
        }
        return nil
    }

    private static let musicianKinds: Set<String> = Set(
        [RelationshipKind.collaborator, .producer, .personnel, .aliasOrProject, .sameRelease, .appearsOnRelease].map(\.rawValue))

    /// From the stored answer, when it was worked out under today's rules.
    private func storedCount(_ identity: String) -> Int? {
        var marker = FetchDescriptor<GraphSnapshot>(predicate: #Predicate { $0.nodeID == identity })
        marker.fetchLimit = 1
        guard let snapshot = (try? context.fetch(marker))?.first,
              snapshot.builderVersion == GraphStore.builderVersion else { return nil }
        var rows = FetchDescriptor<StoredEdge>(predicate: #Predicate { $0.fromID == identity && $0.toKindRaw == "artist" })
        rows.propertiesToFetch = [\.kindRaw, \.toID]
        let edges = (try? context.fetch(rows)) ?? []
        return Set(edges.filter { Self.musicianKinds.contains($0.kindRaw) }.map(\.toID)).count
    }
}
