//
//  CrateStreamResolver.swift
//  Indigo
//
//  Finds something to play for a kept show that has no stream of its own.
//
//  A show crated while it was on air, or before its station had posted the
//  recording, is saved with no address — and the crate used to go back and
//  ask only for NTS, and only for rows that also happened to have no genres.
//  Everything else stayed a link to a page with no way to play it, in the
//  crate and in the mini player alike, long after the station had published
//  the audio.
//
//  Asked at the press, and by the crate in the background, so a row plays the
//  moment its station has something to hear.
//

import Foundation

@MainActor
struct CrateStreamResolver {
    let crate: CrateService
    let nts: NTSBrowseStore
    let lot: LotBrowseStore
    let dublab: DublabBrowseStore
    let kiosk: KioskBrowseStore
    let noods: NoodsBrowseStore
    let alhara: AlharaBrowseStore
    let cashmere: CashmereBrowseStore
    let lyl: LYLBrowseStore
    let ida: IdaBrowseStore
    let radio80000: Radio80000BrowseStore
    let n10as: N10ASBrowseStore
    let panik: PanikBrowseStore
    let rovr: RovrBrowseStore

    var stations: KeptShow.Stations {
        KeptShow.Stations(nts: nts, lot: lot, dublab: dublab, radio80000: radio80000, n10as: n10as)
    }

    /// What pressing play on this row should start, or nil when the station
    /// has nothing to hear yet — the caller then opens the row's page.
    ///
    /// A broadcast found this way is written onto the row, so the lookup
    /// happens once. A show that names no broadcast plays its newest episode
    /// and is not rewritten: the row is the show, not that week of it.
    func media(for item: CrateItem) async -> MediaItem? {
        guard item.kind == .broadcast else { return nil }
        if let media = item.broadcastMediaItem() { return media }

        // Kept on air: find the broadcast posted since. The ladder points the
        // row at it when it can, which is what the lookup below then reads.
        if item.isLiveShowSnapshot || item.isLegacyNTSLiveRow {
            _ = await KeptShow.destination(for: item, stations: stations, crate: crate)
            if let media = item.broadcastMediaItem() { return media }
        }

        guard let providerID = item.providerID, let showID = item.showID else { return nil }
        if let media = await episode(providerID: providerID, showID: showID) {
            crate.updateArchivedBroadcast(item, from: media)
            // The crate's own id, so the row knows it is the one playing.
            return item.broadcastMediaItem() ?? media
        }
        return await newestEpisode(providerID: providerID, showID: showID)
    }

    // MARK: - Lookups

    /// The broadcast the row names, from its station. Same handles the crate's
    /// genre pass reads.
    private func episode(providerID: String, showID: String) async -> MediaItem? {
        func suffix(_ prefix: String) -> String? {
            showID.hasPrefix(prefix) ? String(showID.dropFirst(prefix.count)) : nil
        }

        switch providerID {
        case NTSProvider.providerID:
            guard let identity = suffix("nts.episode."),
                  let ref = NTSEpisodeRef.decode(identity) else { return nil }
            await nts.loadDetailIfNeeded(show: ref.show, episode: ref.episode)
            return nts.detail(show: ref.show, episode: ref.episode)?.mediaItem()
        case LotProvider.providerID:
            guard let identity = suffix("lot.episode."),
                  let ref = LotEpisodeRef.decode(identity) else { return nil }
            await lot.loadEpisodeIfNeeded(ref: ref)
            return lot.episode(ref: ref)?.mediaItem()
        case KioskProvider.providerID:
            guard let slug = suffix("kiosk.episode.") else { return nil }
            await kiosk.loadEpisodeDetailIfNeeded(slug: slug)
            return (kiosk.episodeDetail(slug: slug)?.episode ?? kiosk.episode(slug: slug))?.mediaItem()
        case NoodsProvider.providerID:
            guard let slug = suffix("noods.show.") else { return nil }
            let path = "shows/\(slug)"
            await noods.loadShowIfNeeded(path: path)
            return noods.showDetail(path: path)?.show.mediaItem()
        case DublabProvider.providerID:
            guard let slug = suffix("dublab.broadcast.") else { return nil }
            await dublab.loadBroadcastIfNeeded(slug: slug)
            return dublab.broadcast(slug: slug)?.mediaItem()
        case AlharaProvider.providerID:
            guard let slug = suffix("alhara.show.") else { return nil }
            await alhara.loadDetailIfNeeded(slug: slug)
            return alhara.show(slug: slug)?.mediaItem()
        case CashmereProvider.providerID:
            guard let slug = suffix("cashmere.episode.") else { return nil }
            await cashmere.loadDetailIfNeeded(slug: slug)
            return cashmere.episode(slug: slug)?.mediaItem()
        case LYLProvider.providerID:
            guard let slug = suffix("lyl.episode.") else { return nil }
            await lyl.loadDetailIfNeeded(slug: slug)
            return lyl.episode(slug: slug)?.mediaItem()
        case IdaProvider.providerID:
            guard let slug = suffix("ida.episode.") else { return nil }
            await ida.loadDetailIfNeeded(slug: slug)
            return ida.episode(slug: slug)?.mediaItem()
        case Radio80000Provider.providerID:
            guard let id = suffix("radio80000.episode.") else { return nil }
            await radio80000.loadDetailIfNeeded(id: id)
            return radio80000.episode(id: id)?.mediaItem()
        case N10ASProvider.providerID:
            guard let id = suffix("n10as.episode.") else { return nil }
            await n10as.loadDetailIfNeeded(id: id)
            return n10as.episode(id: id)?.mediaItem()
        case PanikProvider.providerID:
            guard let id = suffix("panik.episode.") else { return nil }
            await panik.loadDetailIfNeeded(id: id)
            return panik.episode(id: id)?.mediaItem()
        case RovrProvider.providerID:
            guard let id = suffix("rovr.broadcast.") else { return nil }
            await rovr.loadDetailIfNeeded(id: id)
            return rovr.broadcast(id: id)?.mediaItem()
        default:
            return nil
        }
    }

    /// For a row that is a show rather than a broadcast — the stations whose
    /// schedules name only the show, so that is all a row kept on air holds.
    private func newestEpisode(providerID: String, showID: String) async -> MediaItem? {
        switch providerID {
        case Radio80000Provider.providerID:
            let prefix = "radio80000.show."
            guard showID.hasPrefix(prefix) else { return nil }
            let slug = String(showID.dropFirst(prefix.count))
            await radio80000.loadShowIfNeeded(slug: slug)
            return radio80000.episodes(ofShow: slug)
                .max { ($0.broadcastAt ?? .distantPast) < ($1.broadcastAt ?? .distantPast) }?
                .mediaItem()
        case N10ASProvider.providerID:
            let prefix = "n10as.show."
            guard showID.hasPrefix(prefix) else { return nil }
            let slug = String(showID.dropFirst(prefix.count))
            await n10as.loadShowIfNeeded(slug: slug)
            // Already newest first.
            return n10as.episodes(ofShow: slug).first?.mediaItem()
        default:
            return nil
        }
    }
}
