//
//  ObscuritySignals.swift
//  Indigo
//
//  How far off the beaten track something is.
//
//  The spec is careful about this and so is this file: **obscurity is not low
//  popularity**, and there is no public "obscurity score". A number here is
//  a ranking input, never a badge. Telling a listener that a record scores
//  0.82 obscure would be both meaningless and slightly insulting to the
//  record.
//
//  What the signals actually measure is how hard something is to arrive at by
//  accident: a small catalogue, a label with six releases, no presence in the
//  listener's library, a white-label marker, an appearance in one specialist
//  show and nowhere else.
//

import Foundation

nonisolated struct ObscuritySignals: Sendable {
    /// How much the artist has put out that we know of. A catalogue of three
    /// is a different proposition from a catalogue of ninety.
    var knownReleases: Int = 0
    /// How big the imprint is. Ilian Tape and Warp are not the same kind of
    /// find.
    var labelCatalogueSize: Int = 0
    /// Times it has turned up on air. This one cuts both ways — see `score`.
    var radioAppearances: Int = 0
    /// Already in the listener's files, so not a discovery.
    var libraryMatches: Int = 0
    /// Already chosen by the listener, so also not a discovery.
    var crateCount: Int = 0
    /// Nobody has named it.
    var isUnidentified: Bool = false
    /// White label, dubplate, test press, promo.
    var releaseKind: ReleaseKind = .unknown
    /// On Bandcamp and in no catalogue. Not a lesser kind of release — often
    /// the opposite: a record that exists only where the artist put it is one
    /// nobody stumbles into through a database.
    var isBandcampOnly: Bool = false
    /// Steps from where the dig started.
    var distance: Int = 0

    /// 0…1, deeper being further from the surface. Internal only.
    ///
    /// Deliberately built out of scarcity rather than of unpopularity: nothing
    /// here asks whether a thing is liked, only how easily it could have been
    /// stumbled into.
    var score: Double {
        var components: [(value: Double, weight: Double)] = []

        // A small body of work is harder to fall over than a large one.
        components.append((scarcity(knownReleases, saturating: 40), 1.0))
        components.append((scarcity(labelCatalogueSize, saturating: 120), 1.2))

        // Radio is the signal that distinguishes obscure from merely absent.
        // Something played on specialist radio and found nowhere else is the
        // deepest thing there is; something played constantly is not.
        components.append((scarcity(radioAppearances, saturating: 24) * 0.6, 0.8))

        // Anything already in the listener's world is by definition not a
        // discovery for them, however obscure it is to everyone else.
        components.append((libraryMatches > 0 ? 0 : 1, 1.4))
        components.append((crateCount > 0 ? 0 : 1, 1.0))

        components.append((releaseKind.deepness, 1.6))
        components.append((isBandcampOnly ? 1 : 0, 1.3))
        // Music nobody could name cannot be arrived at by any other route.
        components.append((isUnidentified ? 1 : 0, 2.0))
        components.append((min(Double(distance) / 5, 1), 0.8))

        let total = components.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        return components.reduce(0) { $0 + $1.value * $1.weight } / total
    }

    /// Fewer is deeper, flattening out once a count stops being informative.
    private func scarcity(_ count: Int, saturating ceiling: Int) -> Double {
        guard count > 0 else { return 1 }
        return 1 - min(Double(count) / Double(ceiling), 1)
    }
}
