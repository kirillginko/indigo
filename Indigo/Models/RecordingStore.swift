//
//  RecordingStore.swift
//  Indigo
//
//  Reads and writes canonical recordings. Everything that learns something
//  about a piece of music — an identification engine, the local indexer, a
//  metadata lookup — comes through here, so there is one place that decides
//  when two claims are about the same recording.
//

import Foundation
import SwiftData

nonisolated struct RecordingStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Lookup

    /// Identity is checked strongest-first: an ISRC or a MusicBrainz ID is a
    /// claim two catalogues can agree on, where normalised text is only ever a
    /// good guess.
    func existing(isrc: String?, musicBrainzRecordingID: String?, artist: String?, title: String?) throws -> Recording? {
        if let isrc, !isrc.isEmpty,
           let hit = try first(#Predicate<Recording> { $0.isrc == isrc }) {
            return hit
        }
        if let musicBrainzRecordingID, !musicBrainzRecordingID.isEmpty,
           let hit = try first(#Predicate<Recording> { $0.musicBrainzRecordingID == musicBrainzRecordingID }) {
            return hit
        }
        let key = RecordingKey.match(artist: artist, title: title)
        // An empty key means "not enough metadata to claim identity". Two
        // unknowns are not the same recording just because neither has a name.
        guard !key.isEmpty else { return nil }
        return try first(#Predicate<Recording> { $0.matchKey == key })
    }

    func recording(id: UUID) throws -> Recording? {
        try first(#Predicate<Recording> { $0.id == id })
    }

    private func first(_ predicate: Predicate<Recording>) throws -> Recording? {
        var descriptor = FetchDescriptor<Recording>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Identified music

    /// Finds the recording this metadata describes, or creates it. Existing
    /// records are enriched rather than replaced.
    @discardableResult
    func upsert(
        title: String?,
        artistName: String?,
        albumTitle: String? = nil,
        musicBrainzRecordingID: String? = nil,
        isrc: String? = nil,
        durationSeconds: Double? = nil,
        status: IdentificationStatus = .identified
    ) throws -> Recording {
        if let found = try existing(
            isrc: isrc,
            musicBrainzRecordingID: musicBrainzRecordingID,
            artist: artistName,
            title: title
        ) {
            found.apply(
                title: title,
                artistName: artistName,
                albumTitle: albumTitle,
                musicBrainzRecordingID: musicBrainzRecordingID,
                isrc: isrc,
                durationSeconds: durationSeconds,
                status: status
            )
            return found
        }

        let recording = Recording(
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            musicBrainzRecordingID: musicBrainzRecordingID,
            isrc: isrc,
            status: status,
            durationSeconds: durationSeconds
        )
        context.insert(recording)
        return recording
    }

    // MARK: - Unknown music

    /// Creates a recording for music that was heard but not named. The code is
    /// derived from the provenance, so re-running identification over the same
    /// moment yields the same UNKNOWN/XXXXX rather than a second one.
    @discardableResult
    func createUnknown(
        providerID: String,
        showID: String?,
        heardAt: Date,
        offsetSeconds: Double?,
        durationSeconds: Double? = nil
    ) throws -> Recording {
        let code = RecordingKey.unknownCode(
            providerID: providerID,
            showID: showID,
            heardAt: heardAt,
            offsetSeconds: offsetSeconds
        )
        if let found = try first(#Predicate<Recording> { $0.unknownCode == code }) {
            return found
        }
        let recording = Recording(status: .unknown, unknownCode: code, durationSeconds: durationSeconds)
        context.insert(recording)
        return recording
    }

    /// Folds an unknown recording into one that turned out to be the same
    /// music. Provenance moves with it — the whole reason to keep unknowns is
    /// that "Ben UFO played this eight months before it had a name" survives
    /// the moment it finally gets one.
    func merge(_ unknown: Recording, into identified: Recording) {
        guard unknown.id != identified.id else { return }

        for appearance in unknown.appearances {
            appearance.recording = identified
        }
        for source in unknown.sources where !identified.sources.contains(where: {
            $0.kindRaw == source.kindRaw && $0.identifier == source.identifier
        }) {
            source.recording = identified
        }
        identified.apply(
            title: unknown.title,
            artistName: unknown.artistName,
            albumTitle: unknown.albumTitle,
            musicBrainzRecordingID: unknown.musicBrainzRecordingID,
            isrc: unknown.isrc,
            durationSeconds: unknown.durationSeconds
        )
        context.delete(unknown)
    }

    // MARK: - Appearances

    /// Attaches provenance to a recording. Live radio re-detects the same
    /// track every few seconds, so an appearance already open on the same
    /// broadcast is extended rather than duplicated.
    @discardableResult
    func note(
        appearance: MediaAppearance,
        on recording: Recording,
        mergeWindow: TimeInterval = 180
    ) -> MediaAppearance {
        if let open = recording.appearances.first(where: {
            $0.providerID == appearance.providerID
                && $0.showID == appearance.showID
                && abs($0.heardAt.timeIntervalSince(appearance.heardAt)) < mergeWindow
        }) {
            open.endedAt = max(appearance.heardAt, open.endedAt ?? appearance.heardAt)
            if open.confidence ?? 0 < appearance.confidence ?? 0 {
                open.confidence = appearance.confidence
            }
            return open
        }
        context.insert(appearance)
        appearance.recording = recording
        recording.updatedAt = Date()
        return appearance
    }

    // MARK: - Local library

    /// The canonical recording behind a local file, created on demand.
    ///
    /// Deliberately lazy: materialising a recording for every file the moment
    /// it is indexed would double a 50k-track library on disk to describe
    /// music the listener has shown no interest in. A local track becomes a
    /// recording when something actually happens to it.
    @discardableResult
    func recording(for track: Track) throws -> Recording {
        // Hoisted out of the predicate: `#Predicate` can't reach through a
        // model reference, only compare against a plain captured value.
        let path = track.path
        if let found = try first(#Predicate<RecordingSource> { $0.identifier == path })?.recording {
            return found
        }

        let recording = try upsert(
            title: track.title,
            artistName: track.artist,
            albumTitle: track.album,
            durationSeconds: track.duration > 0 ? track.duration : nil,
            status: .identified
        )
        link(recording, toLocalFile: track.path)
        return recording
    }

    private func first(_ predicate: Predicate<RecordingSource>) throws -> RecordingSource? {
        var descriptor = FetchDescriptor<RecordingSource>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Records that this music is already on disk. Idempotent.
    func link(_ recording: Recording, toLocalFile path: String) {
        guard !recording.sources.contains(where: {
            $0.kind == .localFile && $0.identifier == path
        }) else { return }
        let source = RecordingSource(kind: .localFile, identifier: path)
        context.insert(source)
        source.recording = recording
        recording.updatedAt = Date()
    }

    /// Records that an archived broadcast contains this music.
    func link(
        _ recording: Recording,
        toBroadcast showID: String,
        providerID: String,
        offsetSeconds: Double? = nil
    ) {
        guard !recording.sources.contains(where: {
            $0.kind == .broadcastAppearance && $0.identifier == showID && $0.providerID == providerID
        }) else { return }
        let source = RecordingSource(
            kind: .broadcastAppearance,
            identifier: showID,
            providerID: providerID,
            offsetSeconds: offsetSeconds
        )
        context.insert(source)
        source.recording = recording
        recording.updatedAt = Date()
    }
}
