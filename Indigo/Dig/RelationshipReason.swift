//
//  RelationshipReason.swift
//  Indigo
//
//  WHY THIS?
//
//  Every connection Indigo offers has to answer that question, and the answer
//  has to be the actual evidence rather than a restatement of the conclusion.
//  "Similar artist" is not an answer. "Both release on Ilian Tape" is.
//
//  This is where the several reasons behind one connection are turned into
//  something a person reads: the strongest fact first, the rest behind it,
//  and a band saying how much of it to believe.
//

import Foundation

/// Deliberately `nonisolated`.
///
/// The module defaults to main-actor isolation, so an extension without this
/// belongs to the main actor — and `GraphStore` reads `baseConfidence` on
/// every edge it builds, from inside `DigWorker`, which is not the main actor.
/// Under Swift 5 that is a warning; under Swift 6 it does not build.
nonisolated extension RelationshipKind {
    /// The short technical label shown beside a reason.
    var label: String {
        switch self {
        case .sharedLabel: "SAME LABEL"
        case .sharedStyle: "SAME STYLE"
        case .aliasOrProject: "ALIAS"
        case .sameAlias: "SAME ALIAS"
        case .sharedBroadcast: "SAME SHOW"
        case .sharedCollection: "YOUR LIBRARY"
        case .sameEra: "SAME ERA"
        case .sameArtist: "SAME ARTIST"
        case .appearsOnRelease: "ON RELEASE"
        case .sameRelease: "SAME RELEASE"
        case .collaborator: "COLLABORATOR"
        case .playedInShow: "PLAYED IN"
        case .playedBySameSelector: "SAME SELECTOR"
        case .frequentlyPlayedNearby: "PLAYED NEARBY"
        case .sameScene: "SAME SCENE"
        case .sameCity: "SAME CITY"
        case .sameUserTrail: "SAME TRAIL"
        case .sharedCratePattern: "CRATE PATTERN"
        case .manualRelation: "MANUAL"
        case .inYourLibrary: "YOUR LIBRARY"
        case .inYourCrate: "YOUR CRATE"
        }
    }

    /// What an edge of this kind is worth before any evidence is counted.
    /// A catalogue fact outranks a shared tag, and the listener's own
    /// behaviour outranks a guess about a decade.
    var baseConfidence: Double {
        switch self {
        case .sameAlias, .aliasOrProject: 0.95
        case .sameRelease, .appearsOnRelease, .sameArtist: 0.9
        case .sharedLabel: 0.88
        case .collaborator: 0.86
        case .manualRelation: 0.85
        case .sharedBroadcast, .playedInShow: 0.7
        case .frequentlyPlayedNearby: 0.68
        case .playedBySameSelector: 0.66
        case .sharedCollection: 0.62
        case .sharedCratePattern: 0.55
        case .sameScene: 0.52
        case .sameCity: 0.45
        case .sharedStyle: 0.45
        case .inYourCrate, .inYourLibrary: 0.4
        case .sameUserTrail: 0.38
        case .sameEra: 0.3
        }
    }
}

/// The explanation panel behind one connection, assembled from its edges.
nonisolated struct WhyThis: Sendable {
    /// The single best reason, which is what a compact row shows.
    let headline: String
    /// Everything else that supports it, strongest first.
    let supporting: [Line]
    let confidence: RelationshipConfidence

    nonisolated struct Line: Identifiable, Hashable, Sendable {
        let kind: RelationshipKind
        let text: String
        let source: RelationshipSource
        let band: RelationshipConfidence
        var id: String { "\(kind.rawValue)|\(text)" }
    }

    init?(reasons: [Relationship]) {
        let ordered = reasons.sorted { $0.confidence > $1.confidence }
        guard let best = ordered.first else { return nil }
        headline = best.detail
        supporting = ordered.dropFirst().map {
            Line(kind: $0.kind, text: $0.detail, source: $0.source, band: $0.confidenceBand)
        }
        confidence = RelationshipConfidence.band(ConfidenceMath.combined(ordered.map(\.confidence)))
    }

    init?(edges: [MusicEdge]) {
        self.init(reasons: edges.map(\.relationship))
    }

    /// "Played in 11 of the same shows · Both release on Ilian Tape" — the
    /// one-line form, for a row that has no space to expand.
    func summary(limit: Int = 2) -> String {
        ([headline] + supporting.prefix(max(0, limit - 1)).map(\.text))
            .joined(separator: " · ")
    }
}

nonisolated enum RelationshipReason {
    /// Phrases a count of repeated evidence. Written here so the same fact
    /// never reads as "1 shows" in one place and "one show" in another.
    static func occurrences(_ count: Int, singular: String, plural: String? = nil) -> String {
        let word = count == 1 ? singular : (plural ?? singular + "s")
        return "\(count) \(word)"
    }
}
