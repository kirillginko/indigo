//
//  RootView.swift
//  Indigo
//
//  Fixed sidebar, content column, persistent player bar. The bar spans the
//  full width so the transport never moves when you change section.
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(DigStore.self) private var dig

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: Metrics.sidebarWidth)
                VRule(color: Palette.outline)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            Rule(color: Palette.outline)
            PlayerBarView()
                .frame(height: Metrics.playerBarHeight)
        }
        .indigoDefaultTypography()
        .background(Palette.paper)
        .foregroundStyle(Palette.ink)
        // Parked, not hidden from WebKit: the widget has to remain in the
        // window for archived episodes to keep playing across navigation.
        .overlay(alignment: .bottomLeading) {
            EmbedPlayerSurface(engine: player.embed)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) { noticeOverlay }
        // Owned here because this view outlives every page. Started from a
        // detail page it was cancelled by the first navigation and, thanks to
        // its own start-once guard, never ran again — which is why rows filled
        // in for a few seconds after launch and then stopped.
        .task { await dig.fillPortraitsInBackground() }
        // Debug builds only, and it writes to a file rather than the log —
        // see `MainThreadWatchdog`.
        .task { MainThreadWatchdog.shared.start() }
        #if !os(macOS)
        .fileImporter(
            isPresented: Binding(
                get: { library.isPresentingImporter },
                set: { library.isPresentingImporter = $0 }
            ),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            library.handleImporterResult(result)
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            Palette.paper
            if let detail = appState.detail {
                Group {
                switch detail {
                case .album(let id):
                    AlbumDetailView(albumID: id)
                case .artist(let id):
                    ArtistDetailView(artistID: id)
                case .ntsShow(let alias):
                    NTSShowDetailView(alias: alias)
                case .ntsEpisode(let show, let episode):
                    NTSEpisodeView(showAlias: show, episodeAlias: episode)
                case .ntsMixtape(let alias):
                    NTSMixtapeDetailView(alias: alias)
                case .kioskMood(let id):
                    KioskMoodDetailView(moodID: id)
                case .kioskEpisode(let slug):
                    KioskEpisodeDetailView(episodeSlug: slug)
                case .digArtist(let mbid, let name):
                    ArtistDigView(artistName: name, artistMBID: mbid)
                case .digLabel(let mbid, let name):
                    LabelDigView(labelMBID: mbid, labelName: name)
                case .digDiscogsLabel(let name):
                    DiscogsLabelDigView(labelName: name)
                case .digRelease(let id, let title):
                    DigReleaseView(releaseID: id, fallbackTitle: title)
                case .digReleaseNamed(let title, let artist):
                    DigReleaseView(releaseID: nil, fallbackTitle: title, artistName: artist)
                case .digRecording(let id, let title):
                    RecordingDigView(recordingID: id, fallbackTitle: title)
                case .digCatalog(let number):
                    CatalogDigView(number: number)
                case .digScene(let city):
                    SceneDigView(city: city)
                case .noodsShow(let path):
                    NoodsShowDetailView(showPath: path)
                case .noodsResident(let path):
                    NoodsResidentDetailView(residentPath: path)
                case .noodsCollection(let path):
                    NoodsCollectionDetailView(collectionPath: path)
                case .lotEpisode(let show, let episode):
                    LotEpisodeDetailView(ref: LotEpisodeRef(show: show, episode: episode))
                case .lotShow(let slug):
                    LotShowDetailView(showSlug: slug)
                case .dublabBroadcast(let slug):
                    DublabBroadcastDetailView(slug: slug)
                case .dublabDJ(let slug):
                    DublabDJDetailView(slug: slug)
                case .alharaShow(let slug):
                    AlharaShowDetailView(slug: slug)
                case .cashmereEpisode(let slug):
                    CashmereEpisodeDetailView(slug: slug)
                case .cashmereShow(let slug):
                    CashmereShowDetailView(slug: slug)
                case .lylEpisode(let slug):
                    LYLEpisodeDetailView(slug: slug)
                case .lylShow(let slug):
                    LYLShowDetailView(slug: slug)
                case .idaEpisode(let slug):
                    IdaEpisodeDetailView(slug: slug)
                case .idaShow(let slug):
                    IdaShowDetailView(slug: slug)
                case .radio80000Episode(let id):
                    Radio80000EpisodeDetailView(episodeID: id)
                case .radio80000Show(let slug):
                    Radio80000ShowDetailView(slug: slug)
                case .panikEpisode(let id):
                    PanikEpisodeDetailView(episodeID: id)
                case .panikShow(let slug):
                    PanikShowDetailView(slug: slug)
                case .rovrBroadcast(let id):
                    RovrBroadcastDetailView(broadcastID: id)
                case .rovrShow(let id):
                    RovrShowDetailView(showID: id)
                case .rovrCurator(let id):
                    RovrCuratorDetailView(curatorID: id)
                }
                }
                // A fresh view per page, rather than SwiftUI reusing the last
                // one because it happens to be the same type. Reuse is why
                // artist → artist kept the scroll position of the page you
                // just left, dropping you halfway down a record you had not
                // seen — and why a page's own state, like how deep you had
                // dug, followed you onto the next one.
                .id(detail)
                // One place, rather than a call in every dig view: a page
                // opening is the event, wherever it was opened from.
                .task(id: detail) { dig.remember(detail, from: appState.previousDetail) }
                    .task {
                        // Wired here because both are in scope and neither
                        // should know how to find the other.
                        player.onUnplayableRecording = { [weak dig] url in
                            dig?.markUnplayable(url)
                        }
                    }
            } else {
                switch appState.route {
                case .tracks: TracksView()
                case .albums: AlbumsView()
                case .artists: ArtistsView()
                case .station(let id): NTSStationView(stationID: id)
                case .ntsLatest: NTSLatestView()
                case .ntsShows: NTSShowsView()
                case .ntsMixtapes: NTSMixtapesView()
                case .ntsSearch: NTSSearchView()
                case .kioskStation: KioskStationView()
                case .kioskMoods: KioskMoodsView()
                case .kioskShows: KioskShowsView()
                case .noodsStation: NoodsStationView()
                case .noodsShows: NoodsShowsView()
                case .noodsResidents: NoodsResidentsView()
                case .noodsCollections: NoodsCollectionsView()
                case .lotStation: LotStationView()
                case .lotIndex: LotIndexView()
                case .lotShows: LotShowsView()
                case .dublabStation: DublabStationView()
                case .dublabArchive: DublabArchiveView()
                case .dublabDJs: DublabDJsView()
                case .alharaStation(let id): AlharaStationView(stationID: id)
                case .alharaArchive: AlharaArchiveView()
                case .cashmereStation: CashmereStationView()
                case .cashmereArchive: CashmereArchiveView()
                case .cashmereShows: CashmereShowsView()
                case .lylStation: LYLStationView()
                case .lylArchive: LYLArchiveView()
                case .lylShows: LYLShowsView()
                case .idaStation(let id): IdaStationView(stationID: id)
                case .idaEpisodes: IdaEpisodesView()
                case .idaShows: IdaShowsView()
                case .radio80000Station: Radio80000StationView()
                case .radio80000Latest: Radio80000LatestView()
                case .radio80000Shows: Radio80000ShowsView()
                case .panikStation: PanikStationView()
                case .panikPodcasts: PanikPodcastsView()
                case .panikShows: PanikShowsView()
                case .rovrStation(let id): RovrStationView(stationID: id)
                case .rovrArchive: RovrArchiveView()
                case .rovrShows: RovrShowsView()
                case .rovrCurators: RovrCuratorsView()
                case .explore: ExploreView()
                case .crate: CrateView()
                case .dig: DigView()
                }
            }
        }
    }

    /// Errors surface here — inline, dismissible, never modal.
    @ViewBuilder
    private var noticeOverlay: some View {
        VStack(spacing: 0) {
            if let notice = library.notice {
                NoticeStrip(text: notice) { library.notice = nil }
                Rule(color: Palette.outline)
            }
            if let notice = player.notice {
                NoticeStrip(text: notice) { player.notice = nil }
                Rule(color: Palette.outline)
            }
        }
        .padding(.bottom, Metrics.playerBarHeight)
        .animation(.easeOut(duration: 0.15), value: library.notice)
        .animation(.easeOut(duration: 0.15), value: player.notice)
    }
}
