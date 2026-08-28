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
                case .noodsFilter: NoodsFilterView()
                case .noodsResidents: NoodsResidentsView()
                case .noodsCollections: NoodsCollectionsView()
                case .lotStation: LotStationView()
                case .lotIndex: LotIndexView()
                case .lotShows: LotShowsView()
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
