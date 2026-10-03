//
//  CrateSnapshot.swift
//  Indigo
//
//  A crated recording, kept on the crate row instead of as a pointer at a
//  `Recording`. Three things live here:
//
//    * `CrateSnapshot`, the values taken from a `Recording` when it is crated.
//    * `CrateRecordings`, which finds -- or makes -- this device's own
//      `Recording` for a row, by `matchKey` or `unknownCode`.
//
//  Rows crated before the snapshot existed were given one by a backfill that
//  read the relationship they used to carry. That relationship is gone from the
//  model; the one-time move of the listener's data into the synced store does
//  the same work from a frozen copy of the old shape (see `UserDataMigrator`).
//

import Foundation
import SwiftData

nonisolated struct CrateSnapshot: Equatable {
    var matchKey = ""
    var unknownCode: String?
    var title: String?
    var artistName: String?
    var albumTitle: String?
    var identificationStatusRaw: String?
    var artworkURLString: String?
    var playbackURLString: String?
    var embedProviderRaw: String?
    var providerID: String?
    var showID: String?
    var showTitle: String?
    var stationName: String?
    var broadcastOffsetSeconds: Double?

    /// What names one recording across devices: its match key, the code for
    /// music nobody named, or both for a placeholder -- "Unreleased" by the same
    /// artist at two points in a show shares a key and is two recordings, told
    /// apart by the code its position gave it. Empty only when neither exists.
    static func identity(matchKey: String, unknownCode: String?) -> String {
        RecordingIdentity.key(matchKey: matchKey, unknownCode: unknownCode)
    }

    var identity: String { Self.identity(matchKey: matchKey, unknownCode: unknownCode) }

    // MARK: Capturing

    /// Reads a snapshot off a recording and what hangs from it.
    ///
    /// `context` is only for the sleeve: the recording's metadata row is where
    /// a cover that was resolved later lives, and a row crated before that
    /// resolution would otherwise show a placeholder.
    static func capture(_ recording: Recording, context: ModelContext? = nil) -> CrateSnapshot {
        // A placeholder that predates its own code gets one before it is
        // copied, or its row would share an identity with its twins.
        if let context { RecordingStore(context: context).ensurePortableCode(recording) }
        var snapshot = CrateSnapshot()
        snapshot.matchKey = recording.matchKey
        snapshot.unknownCode = recording.unknownCode
        snapshot.title = recording.title.flatMap { $0.isEmpty ? nil : $0 }
        snapshot.artistName = recording.artistName.flatMap { $0.isEmpty ? nil : $0 }
        snapshot.albumTitle = recording.albumTitle.flatMap { $0.isEmpty ? nil : $0 }
        snapshot.identificationStatusRaw = recording.identificationStatusRaw

        // The link that plays it. A recording has at most one in practice;
        // the earliest wins if it ever has more.
        let link = recording.sources
            .filter { $0.kind == .streamingLink }
            .min { $0.addedAt < $1.addedAt }
        if let link, let url = URL(string: link.identifier) {
            snapshot.playbackURLString = link.identifier
            snapshot.embedProviderRaw = StreamingLinkSource.provider(for: link, url: url)?.rawValue
                ?? link.providerID
        }

        // Where it was heard.
        if let appearance = recording.firstAppearance {
            snapshot.providerID = appearance.providerID
            snapshot.showID = appearance.showID
            snapshot.showTitle = appearance.showTitle
            snapshot.stationName = appearance.stationName
            snapshot.broadcastOffsetSeconds = appearance.offsetSeconds
        } else if let broadcast = recording.sources.first(where: { $0.kind == .broadcastAppearance }) {
            snapshot.providerID = broadcast.providerID
            snapshot.showID = broadcast.identifier
            snapshot.broadcastOffsetSeconds = broadcast.offsetSeconds
        } else if recording.sources.contains(where: { $0.kind == .localFile }) {
            // `MediaAppearance` files a library track under "local", and a row
            // that was kept from the library reads "Local Library".
            snapshot.providerID = "local"
        }

        if let context {
            let id = recording.id
            var descriptor = FetchDescriptor<RecordingMetadata>(
                predicate: #Predicate { $0.recordingID == id })
            descriptor.fetchLimit = 1
            snapshot.artworkURLString = (try? context.fetch(descriptor))?.first?.artworkURLString
        }
        return snapshot
    }

    /// Writes the snapshot onto a row. A row's own picture and genres are
    /// never replaced: what the listener kept wins over what was found.
    func apply(to item: CrateItem) {
        item.matchKey = matchKey
        item.unknownCode = unknownCode
        item.title = title
        item.artistName = artistName
        item.albumTitle = albumTitle
        item.identificationStatusRaw = identificationStatusRaw
        item.providerID = providerID
        item.showID = showID
        item.showTitle = showTitle
        item.stationName = stationName
        item.broadcastOffsetSeconds = broadcastOffsetSeconds
        if item.playbackURLString == nil { item.playbackURLString = playbackURLString }
        if item.embedProviderRaw == nil { item.embedProviderRaw = embedProviderRaw }
        if item.artworkURL == nil, let artworkURLString { item.artworkURLString = artworkURLString }
    }
}

// MARK: - Finding this device's recording

/// Resolves a crate row to the `Recording` this device holds for it.
///
/// Two ways in, on purpose. `recording(for:)` only looks, and is safe from a
/// view or a batch. `resolve(_:)` makes the recording if the device has none --
/// which is what a new device has for every row until something opens it --
/// and is for actions and background work.
nonisolated struct CrateRecordings {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func recording(for item: CrateItem) -> Recording? {
        guard item.kind == .recording, item.hasRecordingSnapshot else { return nil }
        return recording(matchKey: item.matchKey, unknownCode: item.unknownCode)
    }

    func recording(matchKey: String, unknownCode: String?) -> Recording? {
        RecordingStore(context: context).recording(
            identity: RecordingIdentity(matchKey: matchKey, unknownCode: unknownCode))
    }

    /// The crate row for a recording: by its match key, or by its code when
    /// nobody named it.
    func crateItem(for recording: Recording) -> CrateItem? {
        let identity = RecordingIdentity(recording)
        guard !identity.isEmpty else { return nil }
        return UserDataDedupe.survivor(
            ofCrate: UserDataDedupe(context: context).rows(forCrateKey: .recording(identity)))
    }

    /// One fetch for a whole crate, keyed by the row's id.
    func recordings(for items: [CrateItem]) -> [UUID: Recording] {
        let wanted = items.filter { $0.kind == .recording && $0.hasRecordingSnapshot }
        guard !wanted.isEmpty else { return [:] }
        let keys = Array(Set(wanted.map(\.matchKey).filter { !$0.isEmpty }))
        var found: [Recording] = []
        if !keys.isEmpty {
            found += (try? context.fetch(FetchDescriptor<Recording>(
                predicate: #Predicate { keys.contains($0.matchKey) }))) ?? []
        }
        if wanted.contains(where: { $0.matchKey.isEmpty }) {
            // Unnamed music is rare, so these are matched after the fetch
            // rather than inside a predicate the store has to translate.
            found += (try? context.fetch(FetchDescriptor<Recording>(
                predicate: #Predicate { $0.matchKey == "" }))) ?? []
        }
        var byIdentity: [String: Recording] = [:]
        for recording in found {
            let identity = RecordingIdentity(recording).key
            byIdentity[identity] = byIdentity[identity] ?? recording
        }
        var result: [UUID: Recording] = [:]
        for item in wanted { result[item.id] = byIdentity[item.recordingIdentity] }
        return result
    }

    /// This device's recording for the row, made from the snapshot if it has
    /// none. The ways to play it come with it, so its own page works.
    @discardableResult
    func resolve(_ item: CrateItem) -> Recording? {
        guard item.kind == .recording, item.hasRecordingSnapshot else { return nil }
        if let found = recording(for: item) { return found }

        let status = item.identificationStatusRaw.flatMap(IdentificationStatus.init(rawValue:)) ?? .unknown
        let recording: Recording
        if item.matchKey.isEmpty {
            recording = Recording(
                title: item.title, artistName: item.artistName, albumTitle: item.albumTitle,
                status: status, unknownCode: item.unknownCode)
            context.insert(recording)
        } else {
            guard let made = try? RecordingStore(context: context).upsert(
                title: item.title, artistName: item.artistName,
                albumTitle: item.albumTitle, status: status)
            else { return nil }
            recording = made
        }

        if let urlString = item.playbackURLString,
           !recording.sources.contains(where: { $0.kind == .streamingLink && $0.identifier == urlString }) {
            let link = RecordingSource(
                kind: .streamingLink, identifier: urlString, providerID: item.embedProviderRaw)
            context.insert(link)
            link.recording = recording
        }
        if let provider = item.providerID, provider != "local", let showID = item.showID,
           !recording.sources.contains(where: { $0.kind == .broadcastAppearance && $0.identifier == showID }) {
            let source = RecordingSource(
                kind: .broadcastAppearance, identifier: showID, providerID: provider,
                offsetSeconds: item.broadcastOffsetSeconds)
            context.insert(source)
            source.recording = recording
        }
        return recording
    }
}
