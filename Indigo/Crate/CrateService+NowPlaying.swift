//
//  CrateService+NowPlaying.swift
//  Indigo
//
//  Crating whatever is currently playing, from the player bar. The bar only
//  ever holds a MediaItem, so this is where a provider-independent playing
//  thing turns back into something the crate can keep.
//

import Foundation
import SwiftData

extension CrateService {
    /// Local playback crates the music; everything else crates the broadcast.
    ///
    /// Until identification lands, a live stream has no track to keep — the
    /// honest thing to crate is the show, which is also what the listener
    /// means by "save this" while a DJ set is on.
    func isCrated(nowPlaying item: MediaItem) -> Bool {
        if item.kind == .track, let recording = existingRecording(forLocalPath: item.id) {
            return contains(recording: recording)
        }
        return contains(broadcast: item.id, providerID: item.sourceID)
    }

    func toggle(nowPlaying item: MediaItem, showTitle: String? = nil) {
        if item.kind == .track {
            toggleLocalTrack(item)
            return
        }
        if let existing = self.item(forBroadcast: item.id, providerID: item.sourceID) {
            remove(existing)
            return
        }
        add(
            broadcast: item.id,
            providerID: item.sourceID,
            title: showTitle ?? item.title,
            subtitle: subtitle(for: item, showTitle: showTitle),
            artworkURL: item.remoteArtworkURL,
            playbackURL: item.playbackURL,
            embedProvider: item.embedProvider,
            isLiveStream: item.isLive,
            genres: item.genres
        )
    }

    /// A live station's headline is the show that's on air, so the crated
    /// entry keeps the station as its subtitle rather than losing it.
    private func subtitle(for item: MediaItem, showTitle: String?) -> String? {
        if showTitle != nil, item.isLive { return item.title }
        return [item.subtitle, item.detail]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .first
    }

    private func toggleLocalTrack(_ item: MediaItem) {
        let path = item.id
        guard let track = try? fetchTrack(path: path) else {
            notice = "That file is no longer in your library."
            return
        }
        do {
            let recording = try RecordingStore(context: context).recording(for: track)
            toggle(recording: recording)
        } catch {
            notice = "Couldn't crate \(item.title). \(error.localizedDescription)"
        }
    }

    func existingRecording(forLocalPath path: String) -> Recording? {
        var descriptor = FetchDescriptor<RecordingSource>(
            predicate: #Predicate { $0.identifier == path }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.recording
    }

    private func fetchTrack(path: String) throws -> Track? {
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.path == path })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
