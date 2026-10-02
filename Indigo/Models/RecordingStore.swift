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
        // The recording the key names on its own. A coded one is a single moment
        // of a track that shares its key with others ("Unreleased" at six points
        // in a show), and an upsert for the track is not about any one of them.
        return try first(#Predicate<Recording> { $0.matchKey == key && $0.unknownCode == nil })
    }

    /// The recording an identity names on this device, if it has one. Exact:
    /// a key with no code is the recording the key names alone, never one of
    /// the coded placeholders that share it.
    func recording(identity: RecordingIdentity) -> Recording? {
        guard !identity.isEmpty else { return nil }
        let key = identity.matchKey
        let code = identity.unknownCode
        var descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.matchKey == key && $0.unknownCode == code })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
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
            // Filled in rather than left as it was, so a row written before
            // appearances carried a picture gains one the next time the
            // station's tracklist is read. Only when there is none: a station
            // that has since changed its artwork should not overwrite what the
            // listener saw.
            if open.artworkURLString == nil, let found = appearance.artworkURLString {
                open.artworkURLString = found
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

// MARK: - Placeholders

extension RecordingStore {
    /// The code for a placeholder, from where and when it was heard -- the same
    /// inputs `createUnknown` uses, so a recording that is later found to be
    /// the same moment gets the same code, and two devices that read the same
    /// tracklist mint the same one.
    func placeholderCode(for appearance: MediaAppearance) -> String {
        RecordingKey.unknownCode(
            providerID: appearance.providerID,
            showID: appearance.showID,
            heardAt: appearance.heardAt,
            offsetSeconds: appearance.offsetSeconds)
    }

    /// A code for `recording` that nothing else in its key group already uses:
    /// the one its first appearance gives it, or, if that is taken or it has no
    /// appearance, one made from its own id and kept.
    private func uniqueCode(for recording: Recording, taken: Set<String>) -> String {
        var code = recording.firstAppearance.map(placeholderCode(for:))
            ?? RecordingKey.code(from: "local|\(recording.id.uuidString)")
        var salt = 0
        while taken.contains(code) {
            salt += 1
            code = RecordingKey.code(from: "\(code)|\(recording.id.uuidString)|\(salt)")
        }
        return code
    }

    /// Who may carry a code: a placeholder, which is anything short of
    /// identified. An identified recording is the one the key names, and stays
    /// key-only.
    private func mayCarryCode(_ recording: Recording) -> Bool {
        recording.identificationStatus != .identified
    }

    /// Gives a recording that shares its match key with another a code of its
    /// own, if it is a placeholder and has none.
    ///
    /// "Unreleased" by one artist at six points in a show is six recordings
    /// with one key. The key says nothing about which is which, and a crate row
    /// that has to be the same on every device cannot be told apart by an `id`
    /// that exists on one. A recording with a key nobody else shares needs
    /// nothing: the key already names it.
    @discardableResult
    func ensurePortableCode(_ recording: Recording) -> Bool {
        guard recording.unknownCode == nil, !recording.matchKey.isEmpty,
              mayCarryCode(recording) else { return false }
        let key = recording.matchKey
        let group = (try? context.fetch(FetchDescriptor<Recording>(
            predicate: #Predicate { $0.matchKey == key }))) ?? []
        guard group.count > 1 else { return false }
        recording.unknownCode = uniqueCode(
            for: recording, taken: Set(group.compactMap(\.unknownCode)))
        return true
    }

    /// Brings every key group to the invariant: at most one recording names the
    /// key alone, and every placeholder beside it has a code of its own.
    ///
    /// Two things it undoes. A code given to an identified recording that
    /// shared it with a placeholder -- an earlier version of this coded the
    /// aggregate from its first appearance, which is the same moment as one of
    /// the placeholders. And the codes the placeholders still lack.
    @discardableResult
    func repairIdentities() -> (cleared: Int, assigned: Int) {
        let keyed = (try? context.fetch(FetchDescriptor<Recording>(
            predicate: #Predicate { $0.matchKey != "" }))) ?? []
        var cleared = 0
        var assigned = 0
        for group in Dictionary(grouping: keyed, by: \.matchKey).values where group.count > 1 {
            for member in group where member.identificationStatus == .identified {
                guard let code = member.unknownCode,
                      group.contains(where: { $0 !== member && $0.unknownCode == code })
                else { continue }
                member.unknownCode = nil
                cleared += 1
            }
            var taken = Set(group.compactMap(\.unknownCode))
            for member in group where member.unknownCode == nil && mayCarryCode(member) {
                let code = uniqueCode(for: member, taken: taken)
                member.unknownCode = code
                taken.insert(code)
                assigned += 1
            }
        }
        return (cleared, assigned)
    }

    /// `repairIdentities`, reporting only what it gave a code to.
    @discardableResult
    func assignPlaceholderCodes() -> Int { repairIdentities().assigned }

    /// Every identity that more than one recording has. Empty is the invariant:
    /// no two recordings in a store answer to the same `RecordingIdentity`.
    func identityCollisions() -> [String: [Recording]] {
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        var byIdentity: [String: [Recording]] = [:]
        for recording in all {
            let identity = RecordingIdentity(recording)
            if identity.isEmpty { continue }
            byIdentity[identity.key, default: []].append(recording)
        }
        return byIdentity.filter { $0.value.count > 1 }
    }
}
