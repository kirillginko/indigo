//
//  MediaAppearance.swift
//  Indigo
//
//  Provenance. Where a piece of music was heard, when, and how it came to be
//  named — kept for its own sake, because "Skee Mask / Rev8617, first heard on
//  NTS / Moxie, 27 Aug 2026, 01:14:32" is the part a streaming service throws
//  away and the part a digger actually remembers.
//

import Foundation
import SwiftData

/// How a recording came to be identified at this appearance.
nonisolated enum IdentificationMethod: String, Codable, CaseIterable, Sendable {
    /// An acoustic fingerprint engine matched it.
    case acoustic
    /// The broadcaster published a tracklist naming it.
    case providerTracklist
    /// Tags read from a local file.
    case localMetadata
    /// The listener named it by hand.
    case manual
    /// Heard, not named.
    case none

    var label: String {
        switch self {
        case .acoustic: "Acoustic match"
        case .providerTracklist: "Broadcast tracklist"
        case .localMetadata: "File metadata"
        case .manual: "Named by hand"
        case .none: "Unidentified"
        }
    }
}

@Model
nonisolated final class MediaAppearance {
    @Attribute(.unique) var id: UUID

    /// Which provider this was heard through — "nts", "kiosk", "local".
    var providerID: String
    /// Station identity, when the provider has stations ("nts.1").
    var stationID: String?
    var stationName: String?

    /// The broadcast it appeared in.
    var showTitle: String?
    /// Provider-defined handle for that broadcast, so DIG can navigate back
    /// to it — an NTS "show/episode" pair, a Kiosk episode slug.
    var showID: String?

    /// Wall-clock moment it was heard.
    var heardAt: Date
    /// Seconds into the broadcast, when that is knowable. Nil for a live
    /// stream joined partway, which is most of them.
    var offsetSeconds: Double?
    /// Some appearances run for a while; set once the music moves on.
    var endedAt: Date?

    var isLive: Bool
    /// 0…1 where the identifying engine reports one.
    var confidence: Double?
    var identificationMethodRaw: String
    /// Whatever the provider itself claimed was playing, kept verbatim even
    /// when it disagrees with the match — broadcasters mislabel, and the
    /// original claim is evidence.
    var originalMetadata: String?

    var recording: Recording?

    init(
        id: UUID = UUID(),
        providerID: String,
        stationID: String? = nil,
        stationName: String? = nil,
        showTitle: String? = nil,
        showID: String? = nil,
        heardAt: Date = Date(),
        offsetSeconds: Double? = nil,
        endedAt: Date? = nil,
        isLive: Bool,
        confidence: Double? = nil,
        method: IdentificationMethod,
        originalMetadata: String? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.stationID = stationID
        self.stationName = stationName
        self.showTitle = showTitle
        self.showID = showID
        self.heardAt = heardAt
        self.offsetSeconds = offsetSeconds
        self.endedAt = endedAt
        self.isLive = isLive
        self.confidence = confidence
        self.identificationMethodRaw = method.rawValue
        self.originalMetadata = originalMetadata
    }

    var method: IdentificationMethod {
        get { IdentificationMethod(rawValue: identificationMethodRaw) ?? .none }
        set { identificationMethodRaw = newValue.rawValue }
    }

    // MARK: Display

    /// "NTS / Moxie", "Kiosk Radio / Slagwerk", "Local Library".
    var sourceLine: String {
        let left = stationName ?? providerDisplayName
        guard let showTitle, !showTitle.isEmpty else { return left }
        return "\(left) / \(showTitle)"
    }

    var providerDisplayName: String {
        switch providerID {
        case "nts": "NTS"
        case "kiosk": "Kiosk Radio"
        case "local": "Local Library"
        default: providerID.capitalized
        }
    }

    /// "01:14:32" into the broadcast.
    var offsetLabel: String? {
        guard let offsetSeconds, offsetSeconds >= 0 else { return nil }
        let total = Int(offsetSeconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// "27 AUG 2026".
    var dateLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: heardAt).uppercased()
    }

    /// The full provenance block, as the spec renders it.
    var provenanceLines: [String] {
        var lines = [sourceLine, dateLabel]
        if let offsetLabel { lines.append(offsetLabel) }
        return lines
    }
}
