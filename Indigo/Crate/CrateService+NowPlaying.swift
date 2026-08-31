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
    func isCrated(nowPlaying item: MediaItem, liveShow: RadioShow? = nil) -> Bool {
        if item.kind == .track, item.embedProvider != nil {
            return isCrated(listening: item.playbackURL)
        }
        if item.kind == .track, let recording = existingRecording(forLocalPath: item.id) {
            return contains(recording: recording)
        }
        return contains(broadcast: broadcastID(for: item, liveShow: liveShow), providerID: item.sourceID)
    }

    func toggle(nowPlaying item: MediaItem, liveShow: RadioShow? = nil) {
        if item.kind == .track {
            // A track playing through somebody's player is not a file, and
            // looking it up by path finds nothing — which is why the button
            // did nothing at all for anything played out of DIG.
            if let provider = item.embedProvider {
                toggle(
                    listening: item.playbackURL,
                    title: item.title,
                    artist: item.subtitle,
                    release: item.detail,
                    artworkURL: item.remoteArtworkURL,
                    provider: provider
                )
                return
            }
            toggleLocalTrack(item)
            return
        }
        let broadcastID = broadcastID(for: item, liveShow: liveShow)
        if let existing = self.item(forBroadcast: broadcastID, providerID: item.sourceID) {
            remove(existing)
            return
        }
        let isArchivedNTS = item.isLive && broadcastID.hasPrefix("nts.episode.")
        add(
            broadcast: broadcastID,
            providerID: item.sourceID,
            title: liveShow?.title ?? item.title,
            subtitle: subtitle(for: item, liveShow: liveShow),
            artworkURL: liveShow?.artworkURL ?? item.remoteArtworkURL,
            // A station stream is never the archive source. The crate page
            // resolves the exact episode's published SoundCloud/Mixcloud URL.
            playbackURL: isArchivedNTS ? nil : item.playbackURL,
            embedProvider: isArchivedNTS ? nil : item.embedProvider,
            isLiveStream: isArchivedNTS ? false : item.isLive,
            genres: (liveShow?.genres ?? []) + (liveShow?.moods ?? item.genres)
        )
    }

    private func broadcastID(for item: MediaItem, liveShow: RadioShow?) -> String {
        if item.isLive, item.sourceID == NTSProvider.providerID,
           let detailID = liveShow?.detailID, NTSEpisodeRef.decode(detailID) != nil {
            return "nts.episode.\(detailID)"
        }
        return item.id
    }

    /// A live station's headline is the show that's on air, so the crated
    /// entry keeps the station as its subtitle rather than losing it.
    private func subtitle(for item: MediaItem, liveShow: RadioShow?) -> String? {
        if liveShow != nil, item.isLive { return item.title }
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
