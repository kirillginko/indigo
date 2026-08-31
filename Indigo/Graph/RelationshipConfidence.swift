//
//  RelationshipConfidence.swift
//  Indigo
//
//  How much to believe an edge, and what to do when several independent
//  reasons point the same way.
//
//  The old RELATED list summed the confidences of its reasons. That ranks an
//  artist with six thin coincidences above one who shares a label, and it
//  produces "weights" of 3.4 that mean nothing to anybody. Independent
//  evidence combines here instead: each reason removes a share of the
//  remaining doubt, so the total climbs towards certainty without ever
//  reaching it, and a strong reason still beats a pile of weak ones.
//

import Foundation

nonisolated enum RelationshipConfidence: String, Hashable, Sendable, Comparable {
    case low
    case medium
    case high

    /// The word shown under a connection. Three bands, because a percentage
    /// implies a precision none of these sources have.
    var label: String {
        switch self {
        case .high: "HIGH"
        case .medium: "MEDIUM"
        case .low: "LOW"
        }
    }

    static func band(_ value: Double) -> RelationshipConfidence {
        switch value {
        case 0.8...: .high
        case 0.5..<0.8: .medium
        default: .low
        }
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    static func < (lhs: RelationshipConfidence, rhs: RelationshipConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

nonisolated enum ConfidenceMath {
    /// Combines independent evidence. Each reason takes a bite out of what is
    /// left of the doubt: two 0.5 reasons make 0.75, not 1.0, and nothing
    /// ever reaches certainty from accumulation alone.
    static func combined<S: Sequence<Double>>(_ values: S) -> Double {
        let doubt = values.reduce(1.0) { $0 * (1 - clamp($1)) }
        return clamp(1 - doubt)
    }

    /// Repeating the same kind of evidence is worth something, but far less
    /// each time: appearing beside a track in eleven shows is much stronger
    /// than in one and only a little stronger than in eight. Logarithmic
    /// rather than linear, and capped, so a prolific show can't manufacture
    /// certainty by volume alone.
    static func reinforced(_ base: Double, occurrences: Int) -> Double {
        guard occurrences > 1 else { return clamp(base) }
        let growth = log(Double(occurrences)) / log(12)
        return clamp(base + (1 - base) * min(growth, 1) * 0.6)
    }

    static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
