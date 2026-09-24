//
//  KeptShow.swift
//  Indigo
//
//  Where a show kept off the air opens.
//
//  Crating while a station is on air keeps a show that has no page yet: the
//  broadcast may not be posted for days, and some stations never name it at
//  all. So there is a ladder — the broadcast if it was named, the show if only
//  that was, and the station's shows if neither.
//
//  Here rather than in a view because three places climb it: the crate, the
//  For You page's crate block, and its radio shows. Twice now a fix made in
//  one of them left the others opening the wrong page, and the second time it
//  was a page reporting a broadcast nobody had ever named.
//

import Foundation

/// A rung of the ladder. The two are not interchangeable: a page stacks on
/// top of wherever the listener is, a section replaces it.
nonisolated enum KeptShowDestination: Equatable {
    case page(DetailPage)
    case section(Route)
}

enum KeptShow {
    /// The station catalogues the ladder can search. Passed rather than
    /// reached for, because each page already holds them from its environment.
    @MainActor
    struct Stations {
        let nts: NTSBrowseStore
        let lot: LotBrowseStore
        let dublab: DublabBrowseStore
        let radio80000: Radio80000BrowseStore
        let n10as: N10ASBrowseStore
    }

    /// Where this crate row should open.
    ///
    /// The broadcast if the row names one. A show kept on air names only its
    /// billing, so its station is searched for the broadcast posted since —
    /// and the row is pointed at it, so the search happens once — and failing
    /// that for a page the show does have: its show page, or on dublab, which
    /// publishes none, its DJ's. Only a station with nothing to search falls
    /// back to its directory, which replaces the page rather than stacking on
    /// it, so it is the last rung and never the first.
    @MainActor
    static func destination(
        for item: CrateItem,
        stations: Stations,
        crate: CrateService
    ) async -> KeptShowDestination? {
        if let showID = item.showID, let providerID = item.providerID,
           let page = BroadcastSource.destination(showID: showID, providerID: providerID) {
            return .page(page)
        }
        guard item.isLiveShowSnapshot || item.isLegacyNTSLiveRow else {
            // Not a show at all: a station kept while nothing was on air is
            // the station, and opens it. Without this the row simply did
            // nothing when pressed.
            guard item.isLiveStream, let providerID = item.providerID else { return nil }
            return BroadcastSource.route(providerID: providerID, stationID: item.showID)
                .map { .section($0) }
        }
        let title = item.displayTitle
        switch item.providerID {
        case NTSProvider.providerID:
            let found = await stations.nts.keptShow(matching: title, near: item.addedAt)
            if let ref = found.episode {
                await stations.nts.loadDetailIfNeeded(show: ref.show, episode: ref.episode)
                let media = stations.nts.detail(show: ref.show, episode: ref.episode)?.mediaItem()
                crate.migrateLegacyNTSBroadcast(item, ref: ref, media: media)
                return .page(.ntsEpisode(show: ref.show, episode: ref.episode))
            }
            if let show = found.show { return .page(.ntsShow(alias: show)) }
        case LotProvider.providerID:
            if let ref = await stations.lot.archivedEpisode(matching: title, near: item.addedAt) {
                await stations.lot.loadEpisodeIfNeeded(ref: ref)
                crate.migrateLotLiveBroadcast(item, ref: ref, media: stations.lot.episode(ref: ref)?.mediaItem())
                return .page(.lotEpisode(show: ref.show, episode: ref.episode))
            }
            // The residency: where the broadcast will appear once posted.
            let residency = LibraryKey.normalize(LotScheduleEntry.residency(in: title))
            await stations.lot.loadShowsIfNeeded()
            if let show = stations.lot.shows.first(where: { LibraryKey.normalize($0.name) == residency }) {
                return .page(.lotShow(slug: show.slug))
            }
        case DublabProvider.providerID:
            let found = await stations.dublab.keptBroadcast(matching: title, near: item.addedAt)
            if let slug = found.broadcast {
                crate.remember(showID: "\(DublabProvider.providerID).broadcast.\(slug)", for: item)
                return .page(.dublabBroadcast(slug: slug))
            }
            if let dj = found.dj { return .page(.dublabDJ(slug: dj)) }
        case Radio80000Provider.providerID:
            if let page = await stations.radio80000.showDestination(named: title),
               case .radio80000Show(let slug) = page {
                // Kept, so the catalogue is searched once for this row rather
                // than on every press. See `CrateService.remember`.
                crate.remember(showID: "\(Radio80000Provider.providerID).show.\(slug)", for: item)
                return .page(page)
            }
        case N10ASProvider.providerID:
            if let page = await stations.n10as.showDestination(named: title),
               case .n10asShow(let slug) = page {
                crate.remember(showID: "\(N10ASProvider.providerID).show.\(slug)", for: item)
                return .page(page)
            }
        default:
            break
        }
        return BroadcastSource.showsRoute(for: item.providerID).map { .section($0) }
    }

    /// Gives kept shows with no picture the one on the page they open.
    ///
    /// A show kept while Radio 80000 or n10.as had it on air stores what the
    /// schedule said, which carries no image — but the show page the row
    /// opens has one. Climbs the same ladder, so the row takes the picture of
    /// exactly the page it leads to. Anything left without one draws the
    /// mosaic.
    @MainActor
    static func fillMissingArtwork(crate: CrateService, stations: Stations) async {
        let searched: Set<String?> = [Radio80000Provider.providerID, N10ASProvider.providerID]
        for item in crate.items()
        where item.kind == .broadcast && item.artworkURL == nil && searched.contains(item.providerID) {
            if Task.isCancelled { return }
            let image: URL?
            switch await destination(for: item, stations: stations, crate: crate) {
            case .page(.radio80000Show(let slug)):
                await stations.radio80000.loadShowsIfNeeded()
                image = stations.radio80000.show(slug: slug).flatMap { $0.imageURL ?? $0.thumbnailURL }
            case .page(.n10asShow(let slug)):
                await stations.n10as.loadShowsIfNeeded()
                image = stations.n10as.show(slug: slug)?.imageURL
            default:
                image = nil
            }
            if let image { crate.fillArtwork(image, for: item) }
        }
    }

    /// The same ladder for a graph node.
    ///
    /// EXPLORE offers shows as nodes rather than crate rows, and a node whose
    /// handle names a station rather than a broadcast has nowhere of its own
    /// to go — a card that does nothing when it is pressed, which in a thing
    /// built on "no dead ends" is the worst kind of gap, because it looks
    /// like a link.
    @MainActor
    static func destination(for node: MusicNode, stations: Stations) async -> KeptShowDestination? {
        if let page = node.destination { return .page(page) }
        guard node.kind == .broadcast, let providerID = node.providerID else { return nil }
        if providerID == Radio80000Provider.providerID,
           let page = await stations.radio80000.showDestination(named: node.title) {
            return .page(page)
        }
        if providerID == N10ASProvider.providerID,
           let page = await stations.n10as.showDestination(named: node.title) {
            return .page(page)
        }
        return BroadcastSource.showsRoute(for: providerID).map { .section($0) }
    }
}
