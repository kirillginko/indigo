//
//  AppState.swift
//  Indigo
//
//  Navigation state. Deliberately not a NavigationStack: the sidebar is the
//  primary axis and detail pages push on top of whichever section is showing,
//  which keeps the breadcrumb honest.
//

import Foundation
import Observation

nonisolated enum Route: Hashable {
    case tracks
    case albums
    case artists
    case station(String)
    case ntsLatest
    case ntsShows
    case ntsMixtapes
    case ntsSearch
    case kioskStation
    case kioskMoods
    case kioskShows
    case noodsStation
    case noodsShows
    case noodsResidents
    case noodsCollections
    case lotStation
    case lotIndex
    case lotShows
    case dublabStation
    case dublabArchive
    case dublabDJs
    case alharaStation(String)
    case alharaArchive
    case cashmereStation
    case cashmereArchive
    case cashmereShows
    case lylStation
    case lylArchive
    case lylShows
    case crate
    case dig

    var sectionTitle: String {
        switch self {
        case .tracks: "Tracks"
        case .albums: "Albums"
        case .artists: "Artists"
        case .station: "Radio"
        case .ntsLatest: "Latest"
        case .ntsShows: "Shows"
        case .ntsMixtapes: "Mixtapes"
        case .ntsSearch: "Search"
        case .kioskStation: "Kiosk Radio"
        case .kioskMoods: "Moods"
        case .kioskShows: "Shows"
        case .noodsStation: "Noods Radio"
        case .noodsShows: "Discover"
        case .noodsResidents: "Residents"
        case .noodsCollections: "Collections"
        case .lotStation: "The Lot Radio"
        case .lotIndex: "The Index"
        case .lotShows: "Shows"
        case .dublabStation: "dublab"
        case .dublabArchive: "Archive"
        case .dublabDJs: "DJs"
        case .alharaStation: "Radio alHara"
        case .alharaArchive: "Archive"
        case .cashmereStation: "Cashmere Radio"
        case .cashmereArchive: "Archive"
        case .cashmereShows: "Shows"
        case .lylStation: "LYL Radio"
        case .lylArchive: "Archive"
        case .lylShows: "Shows"
        case .crate: "Crate"
        case .dig: "Dig"
        }
    }
}

nonisolated enum DetailPage: Hashable {
    case album(String)
    case artist(String)
    case ntsShow(alias: String)
    case ntsEpisode(show: String, episode: String)
    case ntsMixtape(alias: String)
    case kioskMood(id: String)
    case kioskEpisode(slug: String)
    case digArtist(mbid: String?, name: String)
    case digLabel(mbid: String, name: String)
    case digDiscogsLabel(name: String)
    case digRelease(id: Int, title: String)
    /// A record named only in an artist's own listing, with no catalogue
    /// entry to open. It still has a page.
    case digReleaseNamed(title: String, artist: String)
    /// One piece of music: where it was heard, and what was heard beside it.
    case digRecording(id: UUID, title: String)
    /// A catalogue number, treated as somewhere you can go.
    case digCatalog(number: String)
    /// A place and a stretch of time.
    case digScene(city: String)
    case noodsShow(path: String)
    case noodsResident(path: String)
    case noodsCollection(path: String)
    case lotEpisode(show: String, episode: String)
    case lotShow(slug: String)
    case dublabBroadcast(slug: String)
    case dublabDJ(slug: String)
    case alharaShow(slug: String)
    case cashmereEpisode(slug: String)
    case cashmereShow(slug: String)
    case lylEpisode(slug: String)
    case lylShow(slug: String)
}

@Observable
final class AppState {
    private(set) var route: Route = .tracks
    /// Detail pages stacked on top of the current route. NTS browsing goes two
    /// deep (show → episode), so this is a stack rather than a single slot.
    private(set) var path: [DetailPage] = []
    var searchText: String = ""
    /// Bumped by ⌘F; SearchField watches it and takes focus.
    private(set) var searchFocusRequests = 0

    var detail: DetailPage? { path.last }

    /// Where the listener was before this page. The step that got them here,
    /// which is the half of a dig worth remembering.
    var previousDetail: DetailPage? {
        path.count > 1 ? path[path.count - 2] : nil
    }

    func select(_ route: Route) {
        searchText = ""
        path = []
        self.route = route
    }

    /// Jump to NTS search carrying the text the user already typed.
    func searchNTS(_ query: String) {
        path = []
        route = .ntsLatest
        searchText = query
    }

    func open(_ page: DetailPage) {
        path.append(page)
    }

    func popDetail() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func requestSearchFocus() {
        searchFocusRequests += 1
    }

    /// Label for the back button on a detail page.
    var breadcrumbTitle: String {
        guard path.count > 1 else { return route.sectionTitle }
        switch path[path.count - 2] {
        case .album: return "Album"
        case .artist: return "Artist"
        case .ntsShow: return "Show"
        case .ntsEpisode: return "Episode"
        case .ntsMixtape: return "Mixtape"
        case .kioskMood: return "Mood"
        case .kioskEpisode: return "Show"
        case .digArtist: return "Artist"
        case .digLabel: return "Label"
        case .digDiscogsLabel: return "Label"
        case .digRelease: return "Release"
        case .digReleaseNamed: return "Release"
        case .digRecording: return "Track"
        case .digCatalog: return "Catalogue"
        case .digScene: return "Scene"
        case .noodsShow: return "Show"
        case .noodsResident: return "Resident"
        case .noodsCollection: return "Collection"
        case .lotEpisode: return "Broadcast"
        case .lotShow: return "Show"
        case .dublabBroadcast: return "Broadcast"
        case .dublabDJ: return "DJ"
        case .alharaShow: return "Show"
        case .cashmereEpisode: return "Episode"
        case .cashmereShow: return "Show"
        case .lylEpisode: return "Episode"
        case .lylShow: return "Show"
        }
    }
}
