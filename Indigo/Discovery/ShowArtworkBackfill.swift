//
//  ShowArtworkBackfill.swift
//  Indigo
//
//  Pictures for the shows EXPLORE offers.
//
//  A show on the For You page is worked out from its tracklist — see
//  `ShowSuggestionEngine` — and the only local record of a broadcast is the
//  `MediaAppearance` rows its tracks left behind. Those rows kept no picture
//  until recently, so every show offered drew a placeholder, on a page whose
//  whole argument is "here is something worth putting on".
//
//  `RadioNeighborhoodEngine` now writes the picture when it ingests a
//  tracklist, which covers every show read from here on. This is for the ones
//  already in the store: reading the episode again runs that same ingest, and
//  the merge in `RecordingStore.note(appearance:on:)` fills the picture in
//  behind it. So there is no second write path — only a nudge to re-read.
//
//  Paced, because it is two dozen requests to a station that is doing the
//  listener a favour, and none of it is urgent: the page is already drawn.
//

import Foundation
import SwiftData

@MainActor
enum ShowArtworkBackfill {
    /// How long to leave between episodes. The portrait fill's spacing, for
    /// the same reason: nothing here is being waited on.
    static let spacing = Duration.milliseconds(1500)

    /// Broadcasts whose appearances carry no picture, newest first.
    ///
    /// By show rather than by row: one episode's tracklist is a dozen
    /// appearances and they all gain the picture together.
    nonisolated static func wanting(in context: ModelContext, providerID: String) -> [NTSEpisodeRef] {
        let rows = (try? context.fetch(FetchDescriptor<MediaAppearance>())) ?? []
        var newest: [String: Date] = [:]
        var covered: Set<String> = []
        for row in rows where row.providerID == providerID {
            guard let showID = row.showID, !showID.isEmpty else { continue }
            if row.artworkURLString != nil {
                covered.insert(showID)
                continue
            }
            newest[showID] = max(newest[showID] ?? .distantPast, row.heardAt)
        }
        return newest.keys
            .filter { !covered.contains($0) }
            .compactMap { showID -> (ref: NTSEpisodeRef, at: Date)? in
                guard let ref = NTSEpisodeRef.decode(showID) else { return nil }
                return (ref, newest[showID] ?? .distantPast)
            }
            .sorted { $0.at > $1.at }
            .map(\.ref)
    }

    /// Reads each one again, so the ingest behind it writes the picture.
    ///
    /// Returns how many were asked for. Whether each actually gained one is
    /// the station's business — an episode it has taken down gains nothing,
    /// and is simply not asked about again this session.
    /// How many shows gained a picture, so the caller knows whether anything
    /// downstream needs telling.
    @discardableResult
    static func run(using browse: NTSBrowseStore, context: ModelContext) async -> Int {
        let wanted = wanting(in: context, providerID: NTSProvider.providerID)
        guard !wanted.isEmpty else { return 0 }
        var asked = 0
        for ref in wanted {
            if Task.isCancelled { break }
            await browse.loadDetailIfNeeded(show: ref.show, episode: ref.episode)
            asked += 1
            try? await Task.sleep(for: spacing)
        }
        // Counted by asking the same question again rather than by trusting
        // the loop: a station that has taken an episode down answers, and
        // nothing is written.
        let stillWanting = wanting(in: context, providerID: NTSProvider.providerID).count
        let gained = max(0, wanted.count - stillWanting)
        Trace.note("shows.artwork.backfill asked=\(asked) gained=\(gained)")
        return gained
    }
}
