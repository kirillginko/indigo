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

nonisolated enum RelationshipKind: String, Hashable, Sendable, Codable {
    case sharedLabel
    case sharedStyle
    case aliasOrProject
    case sharedBroadcast
    case sharedCollection
    case sameEra
    case sameArtist
    case appearsOnRelease
    case collaborator
    /// Shaped the record without necessarily playing on it — producer, mixer,
    /// remixer. Kept apart from `personnel` because "who produces this" is one
    /// of the strongest routes through underground music there is.
    case producer
    /// Played, sang, wrote, or engineered. The rest of the sleeve.
    case personnel
    case playedInShow
    case inYourLibrary
    case inYourCrate
    case sameRelease
    case sameAlias
    case playedBySameSelector
    case frequentlyPlayedNearby
    case sameScene
    case sameCity
    case sameUserTrail
    case sharedCratePattern
    case manualRelation
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
    /// Explicitly added by the listener or an editor.
    case manual
    /// Privacy-preserving aggregate discovery paths.
    case trails

    var label: String {
        switch self {
        case .musicBrainz: "MusicBrainz"
        case .discogs: "Discogs"
        case .library: "Your library"
        case .radio: "Radio"
        case .crate: "Your crate"
        case .manual: "Manual"
        case .trails: "Anonymous trails"
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

    var confidenceBand: RelationshipConfidence {
        RelationshipConfidence.band(confidence)
    }
}

/// An artist reached from somewhere else, carrying the reasons it was reached.
nonisolated struct RelatedArtist: Identifiable, Hashable, Sendable {
    let name: String
    let mbid: String?
    let reasons: [Relationship]
    /// The artist's portrait, when a catalogue we have already read supplied
    /// one. A row of names is a list; a row of faces is a shelf.
    var imageURL: URL?
    /// The Discogs entry, when the evidence names one (see `IdentityGraph`):
    /// the page opens by it, so a credit that said "Blunt" opens Dean Blunt.
    var discogsID: Int? = nil
    /// Whether opening them leads somewhere: this device already knows their
    /// records, or a shared catalogue bundle describes them. A row into
    /// another dead end is still shown, after the ones that lead on.
    var leadsOn = false
    /// How many further artists their own catalogue bundle names, when it has
    /// been read: where this row goes next.
    var onward: Int? = nil

    /// Namesakes share a name and nothing else here, so an entry is part of
    /// who the row is.
    var id: String { discogsID.map { "discogs:\($0)" } ?? mbid ?? name }

    /// Strongest evidence first, so the list is ordered by how well Indigo can
    /// justify it rather than alphabetically.
    var weight: Double { ConfidenceMath.combined(reasons.map(\.confidence)) }
}
