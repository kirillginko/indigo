//
//  RecordsSummary.swift
//  Indigo
//
//  What an artist's own release documents say about them, in a sentence or
//  three, for a page whose Discogs entry has no written profile (two in three
//  of the enriched dead ends; DIG-REMEDIATION-PLAN.md §12). Every clause is a
//  field of the catalogue bundle -- the years, the labels, the styles, who
//  they made records with, how many were credited -- and nothing else: no
//  adjectives, no inference, no generated prose. With fewer than two facts
//  there is nothing worth saying, and nothing is said.
//

import Foundation

nonisolated enum RecordsSummary {
    struct Summary: Equatable, Sendable {
        let text: String
        /// How many release documents it rests on, for the line under it.
        let documents: Int
    }

    static func make(_ bundle: ArtistBundle) -> Summary? {
        var facts = 0
        var sentences: [String] = []

        let labels = bundle.labels
            .filter { !$0.placeholder && !$0.ownName && LabelName.isRealLabel($0.display) }
            .sorted { $0.releases != $1.releases ? $0.releases > $1.releases : $0.display < $1.display }
            .prefix(2).map(\.display)
        var opening = ""
        if let years = bundle.years {
            opening = years.first == years.last ? "Records from \(years.first)" : "Records from \(years.first) to \(years.last)"
            facts += 1
        }
        if !labels.isEmpty {
            opening += (opening.isEmpty ? "Records on " : " on ") + list(labels)
            facts += 1
        }
        if !opening.isEmpty { sentences.append(opening + ".") }

        let own = bundle.artist.discogsID
        let partners = bundle.collaborators
            .filter { $0.how.contains("joint") && $0.artist.discogsID != own }
            .sorted { $0.releases.count != $1.releases.count ? $0.releases.count > $1.releases.count : $0.artist.name < $1.artist.name }
            .map { DiscogsClient.withoutDisambiguator($0.artist.name) }
            .filter { ArtistName.isRealArtist($0) }
        if !partners.isEmpty {
            let named = Array(partners.prefix(2))
            let rest = partners.count - named.count
            sentences.append("Made records with \(list(named))\(rest > 0 ? " and \(rest) more" : "").")
            facts += 1
        }

        let credited = Set(bundle.credits.compactMap(\.artist.discogsID).filter { $0 != own && !CataloguePilot.standIns.contains($0) })
        if !credited.isEmpty {
            sentences.append(credited.count == 1 ? "One other person is credited on them." : "\(credited.count) other people are credited on them.")
            if partners.isEmpty { facts += 1 }
        }

        let styles = bundle.styles.prefix(3).map(\.name)
        if !styles.isEmpty {
            sentences.append("Filed under \(list(styles)).")
            facts += 1
        }

        guard facts >= 2 else { return nil }
        return Summary(text: sentences.joined(separator: " "), documents: bundle.releases.count)
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
