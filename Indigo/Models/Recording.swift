//
//  Recording.swift
//  Indigo
//
//  The canonical music object. A recording is a piece of music, not a row in
//  anyone's catalogue: NTS, Shazam, MusicBrainz, SoundCloud and the local
//  library all contribute identifiers to it, and none of them *is* it.
//
//  A recording nobody could identify is still a recording. That is the whole
//  point — white labels, dubplates and unreleased edits are the music most
//  worth keeping, and they are exactly what a catalogue-keyed model throws
//  away.
//

import Foundation
import SwiftData

nonisolated enum IdentificationStatus: String, Codable, CaseIterable, Sendable {
    /// Matched with confidence — an engine or a catalogue agreed.
    case identified
    /// Matched, but the app isn't certain. Shown with a qualifier.
    case probable
    /// Heard and preserved, not named.
    case unknown

    var label: String {
        switch self {
        case .identified: "Match"
        case .probable: "Probable"
        case .unknown: "Unknown"
        }
    }
}

@Model
nonisolated final class Recording {
    @Attribute(.unique) var id: UUID

    var title: String?
    var artistName: String?
    var albumTitle: String?

    /// External identifiers. Each one is a claim about this recording made by
    /// somebody else; none of them is its identity.
    var musicBrainzRecordingID: String?
    var isrc: String?

    var identificationStatusRaw: String
    /// Normalised artist + title, used to avoid creating a second canonical
    /// recording for music already known. Empty while unidentified.
    var matchKey: String
    /// Short stable handle for unidentified music — the "8F42A" in
    /// UNKNOWN/8F42A. Derived from where and when it was first heard, so it
    /// survives relaunches and never collides with a different discovery.
    var unknownCode: String?

    var durationSeconds: Double?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \MediaAppearance.recording)
    var appearances: [MediaAppearance] = []

    @Relationship(deleteRule: .cascade, inverse: \RecordingSource.recording)
    var sources: [RecordingSource] = []

    init(
        id: UUID = UUID(),
        title: String? = nil,
        artistName: String? = nil,
        albumTitle: String? = nil,
        musicBrainzRecordingID: String? = nil,
        isrc: String? = nil,
        status: IdentificationStatus,
        unknownCode: String? = nil,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.musicBrainzRecordingID = musicBrainzRecordingID
        self.isrc = isrc
        self.identificationStatusRaw = status.rawValue
        self.matchKey = RecordingKey.match(artist: artistName, title: title)
        self.unknownCode = unknownCode
        self.durationSeconds = durationSeconds
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: Derived

    var identificationStatus: IdentificationStatus {
        get { IdentificationStatus(rawValue: identificationStatusRaw) ?? .unknown }
        set { identificationStatusRaw = newValue.rawValue }
    }

    var isIdentified: Bool { identificationStatus != .unknown }

    /// "UNKNOWN/8F42A" for music with no name yet.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "UNKNOWN/\(unknownCode ?? "?????")"
    }

    var displayArtist: String? {
        guard let artistName, !artistName.isEmpty else { return nil }
        return artistName
    }

    /// Where this was first heard — the line that makes a discovery a memory
    /// rather than a row.
    var firstAppearance: MediaAppearance? {
        appearances.min { $0.heardAt < $1.heardAt }
    }

    var latestAppearance: MediaAppearance? {
        appearances.max { $0.heardAt < $1.heardAt }
    }

    // MARK: Mutation

    /// Folds newly learned metadata in without letting a weaker claim
    /// overwrite a stronger one already on the record.
    func apply(
        title: String? = nil,
        artistName: String? = nil,
        albumTitle: String? = nil,
        musicBrainzRecordingID: String? = nil,
        isrc: String? = nil,
        durationSeconds: Double? = nil,
        status: IdentificationStatus? = nil
    ) {
        if let title, !title.isEmpty, self.title?.isEmpty ?? true { self.title = title }
        if let artistName, !artistName.isEmpty, self.artistName?.isEmpty ?? true { self.artistName = artistName }
        if let albumTitle, !albumTitle.isEmpty, self.albumTitle?.isEmpty ?? true { self.albumTitle = albumTitle }
        if let musicBrainzRecordingID, self.musicBrainzRecordingID == nil {
            self.musicBrainzRecordingID = musicBrainzRecordingID
        }
        if let isrc, self.isrc == nil { self.isrc = isrc }
        if let durationSeconds, durationSeconds > 0, self.durationSeconds == nil {
            self.durationSeconds = durationSeconds
        }
        // Identity only ever gets firmer: an unknown can become probable and a
        // probable can become identified, never the reverse.
        if let status, status.confidenceRank > identificationStatus.confidenceRank {
            identificationStatus = status
        }
        matchKey = RecordingKey.match(artist: self.artistName, title: self.title)
        if isIdentified { unknownCode = nil }
        updatedAt = Date()
    }
}

extension IdentificationStatus {
    /// Ordering used when folding a new claim into an existing recording.
    nonisolated var confidenceRank: Int {
        switch self {
        case .unknown: 0
        case .probable: 1
        case .identified: 2
        }
    }
}
