//
//  CrateService+Tracklist.swift
//  Indigo
//
//  A tracklist row represents music, not the containing broadcast. Resolve it
//  through the canonical recording store before toggling so the Crate keeps
//  the NTS episode and timestamp where the listener found it.
//

import Foundation

extension CrateService {
    func isCrated(tracklistEntry entry: NTSTracklistEntry, in detail: NTSEpisodeDetail) -> Bool {
        guard let recording = RadioNeighborhoodEngine(context: context)
            .recording(for: entry, in: detail) else { return false }
        return contains(recording: recording)
    }

    @discardableResult
    func toggle(tracklistEntry entry: NTSTracklistEntry, in detail: NTSEpisodeDetail) -> Recording? {
        // Usually the browse store already imported this episode. Ingesting
        // here as well makes the button reliable if the view is previewed or
        // reached through a future route that supplies an uncached detail.
        RadioNeighborhoodEngine(context: context).ingest(detail)
        guard let recording = RadioNeighborhoodEngine(context: context)
            .recording(for: entry, in: detail) else {
            notice = "Couldn't add \(entry.title) to your crate."
            return nil
        }
        let wasCrated = contains(recording: recording)
        toggle(recording: recording)
        return wasCrated ? nil : recording
    }

}
