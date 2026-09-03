//
//  NowPlayingLink.swift
//  Indigo
//
//  Where the player bar goes when the listener clicks what is playing.
//
//  Lifted out of the view so it can be tested. Every source Indigo can play
//  files its items under its own id prefix, and a prefix that no branch here
//  recognises produces no link at all — the artwork and the title quietly stop
//  being buttons, which reads as an app that has forgotten what it is doing
//  rather than as a gap in a lookup table.
//

import Foundation

nonisolated enum NowPlayingLink: Equatable, Sendable {
    case route(Route)
    case detail(DetailPage)

    /// What the bar should open for `item`.
    ///
    /// - Parameters:
    ///   - localAlbumKey: the album a local file belongs to, looked up by the
    ///     caller because it needs SwiftData.
    ///   - liveNTSEpisode: the episode NTS says is on air, when one is.
    static func destination(
        for item: MediaItem,
        localAlbumKey: @Sendable (String) -> String? = { _ in nil },
        liveNTSEpisode: NTSEpisodeRef? = nil
    ) -> NowPlayingLink? {
        if item.sourceID == Track.sourceID {
            if let key = localAlbumKey(item.id) { return .detail(.album(key)) }
            // A file Indigo is playing but has not indexed still belongs
            // somewhere; the library is the honest answer.
            return .route(.tracks)
        }

        if let link = archived(item) { return link }

        // A live stream has no episode of its own. NTS names what is on air,
        // so it can open the episode; everyone else opens their station.
        if item.sourceID == NTSProvider.providerID, let ref = liveNTSEpisode {
            return .detail(.ntsEpisode(show: ref.show, episode: ref.episode))
        }

        return station(for: item)
    }

    /// A recording with a page of its own.
    private static func archived(_ item: MediaItem) -> NowPlayingLink? {
        func identity(_ prefix: String) -> String? {
            guard item.id.hasPrefix(prefix) else { return nil }
            let value = String(item.id.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }

        if let slug = identity("noods.show.") { return .detail(.noodsShow(path: "shows/\(slug)")) }
        if let value = identity("nts.episode.") {
            if let ref = NTSEpisodeRef.decode(value) {
                return .detail(.ntsEpisode(show: ref.show, episode: ref.episode))
            }
            return .route(.station("2"))
        }
        if let alias = identity("nts.mixtape.") { return .detail(.ntsMixtape(alias: alias)) }
        if let slug = identity("lyl.episode.") { return .detail(.lylEpisode(slug: slug)) }
        if let id = identity("rovr.broadcast.") { return .detail(.rovrBroadcast(id: id)) }
        if let id = identity("panik.episode.") { return .detail(.panikEpisode(id: id)) }
        if let id = identity("radio80000.episode.") { return .detail(.radio80000Episode(id: id)) }
        if let slug = identity("ida.episode.") { return .detail(.idaEpisode(slug: slug)) }
        if let slug = identity("cashmere.episode.") { return .detail(.cashmereEpisode(slug: slug)) }
        if let slug = identity("alhara.show.") { return .detail(.alharaShow(slug: slug)) }
        if let slug = identity("dublab.broadcast.") { return .detail(.dublabBroadcast(slug: slug)) }
        if let slug = identity("kiosk.episode.") { return .detail(.kioskEpisode(slug: slug)) }
        if let value = identity("lot.episode."), let ref = LotEpisodeRef.decode(value) {
            return .detail(.lotEpisode(show: ref.show, episode: ref.episode))
        }
        return nil
    }

    /// The station a live stream belongs to.
    ///
    /// Matched on the source rather than the id, since a stream's id is the
    /// channel's and every station names those differently.
    private static func station(for item: MediaItem) -> NowPlayingLink? {
        switch item.sourceID {
        // NTS runs two channels and files each under its own id, so the
        // stream's own id is the station to return to.
        case NTSProvider.providerID: return .route(.station(item.id))
        case KioskProvider.providerID: return .route(.kioskStation)
        case NoodsProvider.providerID: return .route(.noodsStation)
        case LotProvider.providerID: return .route(.lotStation)
        case DublabProvider.providerID: return .route(.dublabStation)
        case AlharaProvider.providerID: return .route(.alharaStation(item.id))
        case CashmereProvider.providerID: return .route(.cashmereStation)
        case LYLProvider.providerID: return .route(.lylStation)
        case IdaProvider.providerID: return .route(.idaStation(item.id))
        case Radio80000Provider.providerID: return .route(.radio80000Station)
        case PanikProvider.providerID: return .route(.panikStation)
        // ROVR's channel id is the station id, so the bar returns to whichever
        // of them is playing rather than always to the scheduled radio.
        case RovrProvider.providerID: return .route(.rovrStation(item.id))
        default: return nil
        }
    }
}
