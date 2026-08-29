//
//  Relationship.swift
//  Indigo
//
//  Why two things are connected. The spec is blunt about this: never
//  "YOU MAY ALSO LIKE". A connection Indigo can't explain is one it shouldn't
//  show, so the reason travels with the edge rather than being reconstructed
//  for display.
//

import Foundation

nonisolated enum RelationshipKind: String, Hashable, Sendable {
    case sharedLabel
    case sharedStyle
    case aliasOrProject
    case sharedBroadcast
    case sharedCollection
    case sameEra
    case sameArtist
    case appearsOnRelease
    case collaborator
    case playedInShow
    case inYourLibrary
    case inYourCrate
}

nonisolated enum RelationshipSource: String, Hashable, Sendable {
    /// Asserted by MusicBrainz.
    case musicBrainz
    /// Asserted by Discogs artist membership or group data.
    case discogs
    /// Observed in the listener's own files.
    case library
    /// Observed on air.
    case radio
    /// The listener said so by crating it.
    case crate

    var label: String {
        switch self {
        case .musicBrainz: "MusicBrainz"
        case .discogs: "Discogs"
        case .library: "Your library"
        case .radio: "Radio"
        case .crate: "Your crate"
        }
    }
}

/// One explained edge. `detail` is the sentence shown under
/// "WHY THIS CONNECTION?" — written at construction, where the evidence is,
/// not guessed at in a view.
nonisolated struct Relationship: Identifiable, Hashable, Sendable {
    let kind: RelationshipKind
    let source: RelationshipSource
    let detail: String
    /// 0…1. A shared label is a fact; a name match is a guess.
    let confidence: Double

    var id: String { "\(kind.rawValue)|\(detail)" }
}

/// An artist reached from somewhere else, carrying the reasons it was reached.
nonisolated struct RelatedArtist: Identifiable, Hashable, Sendable {
    let name: String
    let mbid: String?
    let reasons: [Relationship]

    var id: String { mbid ?? name }

    /// Strongest evidence first, so the list is ordered by how well Indigo can
    /// justify it rather than alphabetically.
    var weight: Double { reasons.reduce(0) { $0 + $1.confidence } }
}
