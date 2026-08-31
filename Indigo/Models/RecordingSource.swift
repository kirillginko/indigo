//
//  RecordingSource.swift
//  Indigo
//
//  A place a recording can actually be heard. Persisted so a match found once
//  — "this NTS discovery is the FLAC you already own" — doesn't have to be
//  recomputed every time you press play.
//
//  The UI never reads these directly. It asks SourceResolver for a recording
//  and gets back whatever is best right now.
//

import Foundation
import SwiftData

nonisolated enum AudioSourceKind: String, Codable, CaseIterable, Sendable {
    /// A file in the listener's own library. Always preferred.
    case localFile
    /// An archived broadcast that contains this recording.
    case broadcastAppearance
    /// A link that plays this recording directly, through whichever provider's
    /// own player it belongs to. Ranked below the two above: somebody's file
    /// and somebody's radio show are both better than a video of it.
    case streamingLink

    var label: String {
        switch self {
        case .localFile: "Local"
        case .broadcastAppearance: "Broadcast"
        case .streamingLink: "Link"
        }
    }
}

@Model
nonisolated final class RecordingSource {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    /// A file path for `.localFile`; a provider-defined broadcast handle for
    /// `.broadcastAppearance`; the address itself for `.streamingLink`.
    var identifier: String
    /// Which provider the identifier belongs to, for broadcast sources.
    var providerID: String?
    /// Seconds into a broadcast where this recording starts.
    var offsetSeconds: Double?
    var addedAt: Date

    var recording: Recording?

    init(
        id: UUID = UUID(),
        kind: AudioSourceKind,
        identifier: String,
        providerID: String? = nil,
        offsetSeconds: Double? = nil
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.identifier = identifier
        self.providerID = providerID
        self.offsetSeconds = offsetSeconds
        self.addedAt = Date()
    }

    var kind: AudioSourceKind {
        get { AudioSourceKind(rawValue: kindRaw) ?? .broadcastAppearance }
        set { kindRaw = newValue.rawValue }
    }
}
