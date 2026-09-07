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
        // Naming what was on means the row is no longer about the station,
        // and the station's stream is never the archive source: the crate
        // page resolves the broadcast's own published URL. Keeping the live
        // stream here would hand the player a different show under a kept
        // name — see `CrateItem.isLiveShowSnapshot`, which catches the rows
        // written before any of this and the stations that still cannot say
        // what is on.
        let keptOffAir = item.isLive && broadcastID != item.id
        add(
            broadcast: broadcastID,
            providerID: item.sourceID,
            title: liveShow?.title ?? item.title,
            subtitle: subtitle(for: item, liveShow: liveShow),
            artworkURL: liveShow?.artworkURL ?? item.remoteArtworkURL,
            playbackURL: keptOffAir ? nil : item.playbackURL,
            embedProvider: keptOffAir ? nil : item.embedProvider,
            isLiveStream: keptOffAir ? false : item.isLive,
            genres: (liveShow?.genres ?? []) + (liveShow?.moods ?? item.genres)
        )
    }

    /// What was kept: the show that was on, when the station can name it.
    ///
    /// `item.id` is the station, because the station is what the player was
    /// playing. Keeping that is how crating a show came to mean "whatever
    /// this station is broadcasting now" — the one thing nobody meant to
    /// keep. Where a live feed names what is on, that name is kept instead.
    ///
    /// The identifiers are the providers' own, so a show crated off the air
    /// and the same broadcast crated later out of the archive are one row
    /// rather than two: IDA, LYL and ROVR all publish, on air, the very slug
    /// their episode pages are filed under.
    ///
    /// Panik and Cashmere name the *show* rather than the episode, so those
    /// go to a namespace of their own — a show is not one of its broadcasts,
    /// and filing it as one would claim an episode nobody identified.
    private func broadcastID(for item: MediaItem, liveShow: RadioShow?) -> String {
        guard item.isLive, let detailID = liveShow?.detailID, !detailID.isEmpty else {
            return item.id
        }
        switch item.sourceID {
        case NTSProvider.providerID:
            // NTS packs a show and an episode alias into one string, and a
            // detailID that will not decode names neither.
            guard NTSEpisodeRef.decode(detailID) != nil else { return item.id }
            return "nts.episode.\(detailID)"
        case IdaProvider.providerID:
            return "ida.episode.\(detailID)"
        case LYLProvider.providerID:
            return "lyl.episode.\(detailID)"
        case RovrProvider.providerID:
            return "rovr.broadcast.\(detailID)"
        case PanikProvider.providerID:
            return "panik.show.\(detailID)"
        case CashmereProvider.providerID:
            return "cashmere.show.\(detailID)"
        default:
            return item.id
        }
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
