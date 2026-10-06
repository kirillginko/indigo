//
//  PhoneEpisodeRows.swift
//  Indigo
//
//  Every station's broadcast as the phone's row, built here and only here,
//  so a station's rows read the same on its show page, its episode pages'
//  "more from" lists, its sections and its DJs' and curators' pages. Built
//  in forty places, the same station's rows had come to differ: one page
//  titled every row with the show's name, another left off the crate.
//
//  The rule (PHONE-DESIGN.md, "Rows"):
//  - the title is the broadcast's own name;
//  - the line under it is who was on; where a station names nobody, and the
//    list spans shows, it is the show's name instead -- never on the show's
//    own page, where it would only repeat the page;
//  - genres as the station tags them; the date it went out;
//  - play, and the crate, always.
//

import SwiftUI

/// What a row needs from the page it is on.
struct PhoneRowContext {
    let player: PlaybackCoordinator
    let appState: AppState
    /// On a show's own page the show's name is the page's, not the row's.
    var onShowPage = false

    func second(who: String?, show: String?) -> String? {
        if let who, !who.isEmpty { return who }
        return onShowPage ? nil : show
    }
}

extension PhoneEpisode {
    static func ida(_ e: IdaEpisode, in list: [IdaEpisode], browse: IdaBrowseStore, _ c: PhoneRowContext) -> PhoneEpisode {
        PhoneEpisode(
            id: e.id, title: e.title, subtitle: c.second(who: e.subtitle ?? e.showArtist, show: e.showTitle),
            date: e.broadcastAt, genres: e.genres, imageURL: e.thumbnailURL ?? e.imageURL, isPlayable: e.isPlayable,
            isCurrent: IdaPlayback.isCurrent(e, in: c.player), isPlaying: IdaPlayback.isPlaying(e, in: c.player),
            play: { IdaPlayback.toggle(e, within: list, using: c.player) },
            open: { browse.remember([e]); c.appState.open(.idaEpisode(slug: e.slug)) },
            crate: AnyView(IdaCrateButton(episode: e, compact: true)))
    }

    static func lot(_ e: LotEpisode, in list: [LotEpisode], browse: LotBrowseStore, _ c: PhoneRowContext) -> PhoneEpisode {
        PhoneEpisode(
            id: e.id, title: e.title,
            subtitle: c.second(who: e.artists.map(\.name).joined(separator: ", "), show: e.show?.name),
            date: e.airedAt ?? e.startedAt, genres: e.genreNames, imageURL: e.artworkURL ?? e.imageURL,
            isPlayable: e.isPlayable,
            isCurrent: LotPlayback.isCurrent(e, in: c.player), isPlaying: LotPlayback.isPlaying(e, in: c.player),
            play: { LotPlayback.toggle(e, within: list, using: c.player) },
            open: {
                guard let ref = e.ref else { return }
                browse.remember([e])
                c.appState.open(.lotEpisode(show: ref.show, episode: ref.episode))
            },
            crate: AnyView(LotCrateButton(episode: e, compact: true)))
    }

    static func cashmere(_ e: CashmereEpisode, in list: [CashmereEpisode], browse: CashmereBrowseStore, _ c: PhoneRowContext) -> PhoneEpisode {
        PhoneEpisode(
            id: e.id, title: e.title, subtitle: c.second(who: nil, show: e.showName),
            date: e.airedAt, genres: e.genres, imageURL: e.artworkURL, isPlayable: e.isPlayable,
            isCurrent: CashmerePlayback.isCurrent(e, in: c.player), isPlaying: CashmerePlayback.isPlaying(e, in: c.player),
            play: { CashmerePlayback.toggle(e, within: list, using: c.player) },
            open: { browse.remember([e]); c.appState.open(.cashmereEpisode(slug: e.slug)) },
            crate: AnyView(CashmereCrateButton(episode: e, compact: true)))
    }

    static func lyl(_ e: LYLEpisode, in list: [LYLEpisode], browse: LYLBrowseStore, _ c: PhoneRowContext) -> PhoneEpisode {
        PhoneEpisode(
            id: e.id, title: e.title, subtitle: c.second(who: e.artists, show: e.showTitle),
            date: e.broadcastAt, genres: e.styles, imageURL: e.imageURL, isPlayable: e.isPlayable,
            isCurrent: LYLPlayback.isCurrent(e, in: c.player), isPlaying: LYLPlayback.isPlaying(e, in: c.player),
            play: { LYLPlayback.toggle(e, within: list, using: c.player) },
            open: { browse.remember([e]); c.appState.open(.lylEpisode(slug: e.slug)) },
            crate: AnyView(LYLCrateButton(episode: e, compact: true)))
    }

    static func radio80000(_ e: Radio80000Episode, in list: [Radio80000Episode], browse: Radio80000BrowseStore, _ c: PhoneRowContext) -> PhoneEpisode {
        PhoneEpisode(
            id: e.id, title: e.title, subtitle: c.second(who: nil, show: e.showTitle),
            date: e.broadcastAt, genres: e.genres, imageURL: e.artworkURL, isPlayable: e.isPlayable,
            isCurrent: Radio80000Playback.isCurrent(e, in: c.player), isPlaying: Radio80000Playback.isPlaying(e, in: c.player),
            play: { Radio80000Playback.toggle(e, within: list, using: c.player) },
            open: { browse.remember([e]); c.appState.open(.radio80000Episode(id: e.id)) },
            crate: AnyView(Radio80000CrateButton(episode: e, compact: true)))
    }

    static func panik(_ e: PanikEpisode, in list: [PanikEpisode], browse: PanikBrowseStore, _ c: PhoneRowContext) -> PhoneEpisode {
        PhoneEpisode(
            id: e.id, title: e.title, subtitle: c.second(who: nil, show: e.showTitle),
            date: e.publishedAt, imageURL: e.imageURL, isPlayable: e.isPlayable,
            isCurrent: PanikPlayback.isCurrent(e, in: c.player), isPlaying: PanikPlayback.isPlaying(e, in: c.player),
            play: { PanikPlayback.toggle(e, within: list, using: c.player) },
            open: { browse.remember([e]); c.appState.open(.panikEpisode(id: e.id)) },
            crate: AnyView(PanikCrateButton(episode: e, compact: true)))
    }

    static func rovr(_ b: RovrBroadcast, in list: [RovrBroadcast], browse: RovrBrowseStore, _ c: PhoneRowContext) -> PhoneEpisode {
        PhoneEpisode(
            id: b.id, title: b.title, subtitle: c.second(who: b.curatorName, show: b.showTitle),
            date: b.broadcastAt, genres: b.tags, imageURL: b.thumbnailURL ?? b.imageURL, isPlayable: b.isPlayable,
            isCurrent: RovrPlayback.isCurrent(b, in: c.player), isPlaying: RovrPlayback.isPlaying(b, in: c.player),
            play: { RovrPlayback.toggle(b, within: list, using: c.player) },
            open: { browse.remember([b]); c.appState.open(.rovrBroadcast(id: b.documentID)) },
            crate: AnyView(RovrCrateButton(broadcast: b, compact: true)))
    }

    static func n10as(_ e: N10ASEpisode, in list: [N10ASEpisode], browse: N10ASBrowseStore, _ c: PhoneRowContext) -> PhoneEpisode {
        PhoneEpisode(
            id: e.id, title: e.title, subtitle: c.second(who: e.guest, show: e.programme),
            date: e.broadcastAt, genres: e.genres, imageURL: e.artworkURL,
            isCurrent: N10ASPlayback.isCurrent(e, in: c.player), isPlaying: N10ASPlayback.isPlaying(e, in: c.player),
            play: { N10ASPlayback.toggle(e, within: list, using: c.player) },
            open: { browse.remember([e]); c.appState.open(.n10asEpisode(id: e.id)) },
            crate: AnyView(N10ASCrateButton(episode: e, compact: true)))
    }

    static func dublab(_ b: DublabBroadcast, in list: [DublabBroadcast], browse: DublabBrowseStore, _ c: PhoneRowContext) -> PhoneEpisode {
        PhoneEpisode(
            id: b.id, title: b.title, subtitle: c.second(who: b.performer, show: b.showName),
            date: b.airedAt, genres: b.genreNames, imageURL: b.artworkURL, isPlayable: b.isPlayable,
            isCurrent: DublabPlayback.isCurrent(b, in: c.player), isPlaying: DublabPlayback.isPlaying(b, in: c.player),
            play: { DublabPlayback.toggle(b, within: list, using: c.player) },
            open: { browse.remember([b]); c.appState.open(.dublabBroadcast(slug: b.slug)) },
            crate: AnyView(DublabCrateButton(broadcast: b, compact: true)))
    }

    static func alhara(_ s: AlharaShow, in list: [AlharaShow], browse: AlharaBrowseStore, _ c: PhoneRowContext) -> PhoneEpisode {
        PhoneEpisode(
            id: s.id, title: s.title, date: s.publishedAt, genres: s.genres, imageURL: s.artworkURL,
            isCurrent: AlharaPlayback.isCurrent(s, in: c.player), isPlaying: AlharaPlayback.isPlaying(s, in: c.player),
            play: { AlharaPlayback.toggle(s, within: list, using: c.player) },
            open: { browse.remember([s]); c.appState.open(.alharaShow(slug: s.slug)) },
            crate: AnyView(AlharaCrateButton(show: s, compact: true)))
    }

    static func kiosk(_ e: KioskEpisode, in list: [KioskEpisode], _ c: PhoneRowContext) -> PhoneEpisode {
        let current = c.player.isCurrent(e.mediaID)
        return PhoneEpisode(
            id: e.id, title: e.title, date: e.airedAt, genres: e.genres, imageURL: e.artworkURL,
            isPlayable: e.isPlayable, isCurrent: current, isPlaying: current && c.player.isPlaying,
            play: { KioskPlayback.toggle(e, within: list, using: c.player) },
            open: { c.appState.open(.kioskEpisode(slug: e.slug)) },
            crate: AnyView(KioskCrateButton(episode: e, compact: true)))
    }

    static func noods(_ s: NoodsShow, in list: [NoodsShow], _ c: PhoneRowContext) -> PhoneEpisode {
        let item = s.mediaItem()
        return PhoneEpisode(
            id: s.id, title: s.title, subtitle: c.second(who: s.artist, show: nil),
            date: s.airedAt, genres: s.genres, imageURL: s.artworkURL, isPlayable: s.isPlayable,
            isCurrent: NoodsPlayback.isCurrent(s, in: c.player), isPlaying: NoodsPlayback.isPlaying(s, in: c.player),
            play: { NoodsPlayback.toggle(s, within: list, using: c.player) },
            open: { c.appState.open(.noodsShow(path: s.path)) },
            crate: AnyView(BroadcastCrateButton(
                id: item?.id ?? "noods.show.\(s.slug)", providerID: NoodsProvider.providerID,
                title: s.title, subtitle: s.artist, artworkURL: s.artworkURL, item: item, genres: s.genres)))
    }

    /// An NTS list holds no audio; the crate keeps the episode by its id and
    /// finds its audio when it is played (`CrateStreamResolver`).
    static func nts(_ e: NTSEpisodeSummary, browse: NTSBrowseStore, _ c: PhoneRowContext) -> PhoneEpisode {
        let mediaID = "nts.episode.\(e.id)"
        let current = c.player.isCurrent(mediaID)
        return PhoneEpisode(
            id: e.id, title: e.name, date: e.broadcastAt, genres: e.genres, imageURL: e.artworkURL,
            isCurrent: current, isPlaying: current && c.player.isPlaying,
            play: { browse.play(e, isCurrent: current, player: c.player, appState: c.appState) },
            open: { c.appState.open(.ntsEpisode(show: e.showAlias, episode: e.episodeAlias)) },
            crate: AnyView(BroadcastCrateButton(
                id: mediaID, providerID: NTSProvider.providerID, title: e.name, subtitle: e.broadcastLabel,
                artworkURL: e.artworkURL, item: nil, genres: e.genres)))
    }
}

/// The crate's glyph for a broadcast a station has no button of its own for.
struct BroadcastCrateButton: View {
    let id: String
    let providerID: String
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let item: MediaItem?
    var genres: [String] = []

    @Environment(CrateService.self) private var crate

    var body: some View {
        let _ = crate.revision
        CrateGlyphButton(isCrated: crate.contains(broadcast: id, providerID: providerID)) {
            if let existing = crate.item(forBroadcast: id, providerID: providerID) {
                crate.remove(existing)
            } else {
                crate.add(broadcast: id, providerID: providerID, title: title, subtitle: subtitle,
                          artworkURL: artworkURL, playbackURL: item?.playbackURL,
                          embedProvider: item?.embedProvider, genres: genres)
            }
        }
    }
}
