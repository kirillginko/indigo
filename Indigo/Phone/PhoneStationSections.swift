//
//  PhoneStationSections.swift
//  Indigo
//
//  The rest of a station on the phone: every section the Mac lists under it
//  -- Latest, Archive, Episodes, Podcasts, Index, Discover; Mixtapes, Moods,
//  Residents, Collections, Curators -- linked from the station's page and
//  set out as the phone's pages are. A feed of broadcasts is a list of the
//  show pages' rows, newest first, reading on as its end comes into view; a
//  set of things to open is a grid of square cards, two to a row.
//
//  Each section still reads its station's own store; off the phone each has
//  its own page.
//

import SwiftUI

/// A section a station's page links to.
struct PhoneStationSection: Identifiable, Hashable {
    let title: String
    let route: Route
    var id: Route { route }

    /// What the Mac lists under the station, past its Shows.
    static func of(providerID: String) -> [PhoneStationSection] {
        switch providerID {
        case NTSProvider.providerID: [.init(title: "Latest", route: .ntsLatest), .init(title: "Mixtapes", route: .ntsMixtapes)]
        case KioskProvider.providerID: [.init(title: "Moods", route: .kioskMoods)]
        case NoodsProvider.providerID: [.init(title: "Discover", route: .noodsShows), .init(title: "Residents", route: .noodsResidents),
                                        .init(title: "Collections", route: .noodsCollections)]
        case LotProvider.providerID: [.init(title: "The Index", route: .lotIndex)]
        case DublabProvider.providerID: [.init(title: "Archive", route: .dublabArchive)]
        case AlharaProvider.providerID: [.init(title: "Archive", route: .alharaArchive)]
        case CashmereProvider.providerID: [.init(title: "Archive", route: .cashmereArchive)]
        case LYLProvider.providerID: [.init(title: "Archive", route: .lylArchive)]
        case IdaProvider.providerID: [.init(title: "Episodes", route: .idaEpisodes)]
        case Radio80000Provider.providerID: [.init(title: "Latest", route: .radio80000Latest)]
        case PanikProvider.providerID: [.init(title: "Podcasts", route: .panikPodcasts)]
        case RovrProvider.providerID: [.init(title: "Archive", route: .rovrArchive), .init(title: "Curators", route: .rovrCurators)]
        case N10ASProvider.providerID: [.init(title: "Archive", route: .n10asArchive)]
        default: []
        }
    }

    static let routes: Set<Route> = [
        .ntsLatest, .ntsMixtapes, .kioskMoods, .noodsShows, .noodsResidents, .noodsCollections, .lotIndex,
        .dublabArchive, .alharaArchive, .cashmereArchive, .lylArchive, .idaEpisodes, .radio80000Latest,
        .panikPodcasts, .rovrArchive, .rovrCurators, .n10asArchive
    ]
}

/// One square card in a section's grid.
struct PhoneGridCard: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let imageURL: URL?
    let open: () -> Void
}

struct PhoneStationSectionPage: View {
    let route: Route

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(NTSBrowseStore.self) private var nts
    @Environment(KioskBrowseStore.self) private var kiosk
    @Environment(NoodsBrowseStore.self) private var noods
    @Environment(LotBrowseStore.self) private var lot
    @Environment(DublabBrowseStore.self) private var dublab
    @Environment(AlharaBrowseStore.self) private var alhara
    @Environment(CashmereBrowseStore.self) private var cashmere
    @Environment(LYLBrowseStore.self) private var lyl
    @Environment(IdaBrowseStore.self) private var ida
    @Environment(Radio80000BrowseStore.self) private var radio80000
    @Environment(PanikBrowseStore.self) private var panik
    @Environment(RovrBrowseStore.self) private var rovr
    @Environment(N10ASBrowseStore.self) private var n10as

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                content
            }
        }
        .foregroundStyle(.white)
        .task(id: route) { await load() }
    }

    // MARK: Frame

    /// Back to the station, and where you are: the station over the section.
    private var header: some View {
        HStack(spacing: 12) {
            Button { appState.select(PhoneFeeds.shared.lastStationRoute ?? .live) } label: { PhoneBackGlyph() }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to the station")
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                ChipFlow { Chip(text: route.stationName, tone: .lead, size: 11, uppercase: true) }
                ChipFlow { Chip(text: route.sectionTitle, size: 16) }
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: 46, height: 46)
        }
        .padding(.horizontal, PhoneLayout.margin)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .ntsMixtapes, .kioskMoods, .noodsResidents, .noodsCollections, .rovrCurators:
            grid(cards)
        default:
            list(episodes)
        }
    }

    private func list(_ rows: [PhoneEpisode]) -> some View {
        LazyVStack(spacing: 0) {
            if rows.isEmpty {
                note
            }
            ForEach(rows) { PhoneEpisodeRow(episode: $0) }
            if !rows.isEmpty, hasMore {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .task(id: rows.count) { await loadMore() }
            }
        }
    }

    private func grid(_ cards: [PhoneGridCard]) -> some View {
        VStack(spacing: 0) {
            if cards.isEmpty { note }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(cards) { card in
                    Button(action: card.open) {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                GeometryReader { proxy in
                                    ArtworkView(remoteURL: card.imageURL, side: proxy.size.width,
                                                glyphScale: 0.26, placeholder: .mosaic)
                                }
                            }
                            .clipped()
                            .overlay(alignment: .bottomLeading) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Chip(text: card.title, size: 12).lineLimit(2)
                                    if let subtitle = card.subtitle, !subtitle.isEmpty {
                                        Chip(text: subtitle, tone: .lead, size: 10).lineLimit(1)
                                    }
                                }
                                .padding(6)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(card.title)
                }
            }
        }
    }

    private var note: some View {
        Text("Loading…")
            .font(Typeface.mono(12))
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
    }

    // MARK: What each section lists

    private var episodes: [PhoneEpisode] {
        switch route {
        case .ntsLatest:
            return nts.feed(.recentlyAdded).items.map { e in
                let current = player.isCurrent("nts.episode.\(e.id)")
                return PhoneEpisode.nts(e, browse: nts, PhoneRowContext(player: player, appState: appState))
            }
        case .noodsShows:
            let shows = noods.feed(.featured).items
            return shows.map { s in
                PhoneEpisode.noods(s, in: shows, PhoneRowContext(player: player, appState: appState))
            }
        case .lotIndex:
            let list = lot.episodes
            return list.map { e in
                PhoneEpisode.lot(e, in: list, browse: lot, PhoneRowContext(player: player, appState: appState))
            }
        case .dublabArchive:
            let list = dublab.broadcasts
            return list.map { b in
                PhoneEpisode.dublab(b, in: list, browse: dublab, PhoneRowContext(player: player, appState: appState))
            }
        case .alharaArchive:
            let list = alhara.shows
            return list.map { s in
                PhoneEpisode.alhara(s, in: list, browse: alhara, PhoneRowContext(player: player, appState: appState))
            }
        case .cashmereArchive:
            let list = cashmere.episodes
            return list.map { e in
                PhoneEpisode.cashmere(e, in: list, browse: cashmere, PhoneRowContext(player: player, appState: appState))
            }
        case .lylArchive:
            let list = lyl.episodes
            return list.map { e in
                PhoneEpisode.lyl(e, in: list, browse: lyl, PhoneRowContext(player: player, appState: appState))
            }
        case .idaEpisodes:
            let list = ida.episodes
            return list.map { e in
                PhoneEpisode.ida(e, in: list, browse: ida, PhoneRowContext(player: player, appState: appState))
            }
        case .radio80000Latest:
            let list = radio80000.latest
            return list.map { e in
                PhoneEpisode.radio80000(e, in: list, browse: radio80000, PhoneRowContext(player: player, appState: appState))
            }
        case .panikPodcasts:
            let list = panik.podcasts
            return list.map { e in
                PhoneEpisode.panik(e, in: list, browse: panik, PhoneRowContext(player: player, appState: appState))
            }
        case .rovrArchive:
            let list = rovr.broadcasts
            return list.map { b in
                PhoneEpisode.rovr(b, in: list, browse: rovr, PhoneRowContext(player: player, appState: appState))
            }
        case .n10asArchive:
            let list = n10as.archive
            return list.map { e in
                PhoneEpisode.n10as(e, in: list, browse: n10as, PhoneRowContext(player: player, appState: appState))
            }
        default:
            return []
        }
    }

    private var cards: [PhoneGridCard] {
        switch route {
        case .ntsMixtapes:
            return nts.mixtapes.items.map { m in
                PhoneGridCard(id: m.id, title: m.title, subtitle: m.subtitle, imageURL: m.artworkURL) {
                    appState.open(.ntsMixtape(alias: m.alias))
                }
            }
        case .kioskMoods:
            return kiosk.moods.map { m in
                PhoneGridCard(id: m.id, title: m.title, subtitle: "\(m.episodes.count) shows", imageURL: m.artworkURL) {
                    appState.open(.kioskMood(id: m.id))
                }
            }
        case .noodsResidents:
            return (noods.promotedResidents + noods.residents).reduce(into: [NoodsResidentRef]()) { all, r in
                if !all.contains(where: { $0.path == r.path }) { all.append(r) }
            }.map { r in
                PhoneGridCard(id: r.path, title: r.name, imageURL: r.artworkURL) {
                    appState.open(.noodsResident(path: r.path))
                }
            }
        case .noodsCollections:
            return noods.collections.map { c in
                PhoneGridCard(id: c.path, title: c.title, subtitle: c.kind, imageURL: c.artworkURL) {
                    appState.open(.noodsCollection(path: c.path))
                }
            }
        case .rovrCurators:
            return rovr.curators.map { c in
                PhoneGridCard(id: c.id, title: c.name, subtitle: c.flag, imageURL: c.thumbnailURL ?? c.imageURL) {
                    appState.open(.rovrCurator(id: c.documentID))
                }
            }
        default:
            return []
        }
    }

    // MARK: Loading

    private var hasMore: Bool {
        switch route {
        case .ntsLatest: nts.feed(.recentlyAdded).hasMore
        case .noodsShows: noods.feed(.featured).hasMore
        case .lotIndex: lot.canLoadMore
        case .dublabArchive: dublab.canLoadMore
        case .alharaArchive: alhara.canLoadMore
        case .cashmereArchive: cashmere.canLoadMore
        case .lylArchive: lyl.canLoadMore
        case .idaEpisodes: ida.canLoadMore
        case .radio80000Latest: radio80000.canLoadMore
        case .rovrArchive: rovr.canLoadMore
        case .n10asArchive: n10as.canLoadMore
        default: false
        }
    }

    /// In a task of its own, so leaving the page halfway does not mark the
    /// list as loaded with nothing in it.
    private func load() async {
        await Task { await fetch() }.value
    }

    private func fetch() async {
        switch route {
        case .ntsLatest: await nts.loadFeedIfNeeded(.recentlyAdded)
        case .ntsMixtapes: await nts.loadMixtapesIfNeeded()
        case .kioskMoods: await kiosk.loadMoodsIfNeeded()
        case .noodsShows: await noods.loadFeedIfNeeded(.featured)
        case .noodsResidents: await noods.loadResidentsIfNeeded()
        case .noodsCollections: await noods.loadCollectionsIfNeeded()
        case .lotIndex: await lot.loadIndexIfNeeded()
        case .dublabArchive: await dublab.loadArchiveIfNeeded()
        case .alharaArchive: await alhara.loadIfNeeded()
        case .cashmereArchive: await cashmere.loadArchiveIfNeeded()
        case .lylArchive: await lyl.loadArchiveIfNeeded()
        case .idaEpisodes: await ida.loadArchiveIfNeeded()
        case .radio80000Latest: await radio80000.loadLatestIfNeeded()
        case .panikPodcasts: await panik.loadPodcastsIfNeeded()
        case .rovrArchive: await rovr.loadArchiveIfNeeded()
        case .rovrCurators: await rovr.loadCuratorsIfNeeded()
        case .n10asArchive: await n10as.loadArchiveIfNeeded()
        default: break
        }
    }

    private func loadMore() async {
        switch route {
        case .ntsLatest: await nts.loadMore(.recentlyAdded)
        case .noodsShows: await noods.loadMore(.featured)
        case .lotIndex: await lot.loadMore()
        case .dublabArchive: await dublab.loadMore()
        case .alharaArchive: await alhara.loadMore()
        case .cashmereArchive: await cashmere.loadMore()
        case .lylArchive: await lyl.loadMore()
        case .idaEpisodes: await ida.loadMore()
        case .radio80000Latest: await radio80000.loadMore()
        case .rovrArchive: await rovr.loadMore()
        case .n10asArchive: await n10as.loadMore()
        default: break
        }
    }
}

extension Route {
    /// The station a section belongs to, for the phone's section header.
    var stationName: String {
        switch self {
        case .ntsLatest, .ntsMixtapes: "NTS"
        case .kioskMoods: "Kiosk Radio"
        case .noodsShows, .noodsResidents, .noodsCollections: "Noods Radio"
        case .lotIndex: "The Lot Radio"
        case .dublabArchive: "dublab"
        case .alharaArchive: "Radio alHara"
        case .cashmereArchive: "Cashmere Radio"
        case .lylArchive: "LYL Radio"
        case .idaEpisodes: "IDA Radio"
        case .radio80000Latest: "Radio 80000"
        case .panikPodcasts: "Radio Panik"
        case .rovrArchive, .rovrCurators: "ROVR"
        case .n10asArchive: "n10.as"
        default: ""
        }
    }
}

extension NTSBrowseStore {
    /// Plays an episode from a list. Lists hold no audio: the episode is read
    /// first, as its own page would, then played; with no audio, its page
    /// opens instead.
    func play(_ episode: NTSEpisodeSummary, isCurrent: Bool, player: PlaybackCoordinator, appState: AppState) {
        if isCurrent {
            player.toggle()
            return
        }
        Task {
            await loadDetailIfNeeded(show: episode.showAlias, episode: episode.episodeAlias)
            if let item = detail(show: episode.showAlias, episode: episode.episodeAlias)?.mediaItem() {
                player.playEpisode(item)
            } else {
                appState.open(.ntsEpisode(show: episode.showAlias, episode: episode.episodeAlias))
            }
        }
    }
}
