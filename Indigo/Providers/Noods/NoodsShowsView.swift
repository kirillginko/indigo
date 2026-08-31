//
//  NoodsShowsView.swift
//  Indigo
//
//  Discover, and the three feeds behind it. Noods calls its /shows landing
//  page "Discover" — two curated lists — with Featured, Latest and Guests as
//  paged feeds beside it, so the tabs mirror the station's own structure.
//
//  Picking genres here asks Noods rather than narrowing what is on screen:
//  the station tags every show, and those tags are the only route into the
//  thousands it does not put on any landing page. Selecting one takes over
//  the page, because at that point the archive is what you are looking at.
//

import SwiftUI

struct NoodsShowsView: View {
    @Environment(AppState.self) private var appState
    @Environment(NoodsBrowseStore.self) private var browse

    /// Discover is the landing page; the rest are feeds.
    private enum Tab: Hashable {
        case discover
        case feed(NoodsFeed)
    }

    @State private var tab: Tab = .discover

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            PageHeader(title: "Noods", subtitle: subtitle) {
                HStack(spacing: 10) {
                    SegmentedTabs(
                        options: [(Tab.discover, "Discover")]
                            + NoodsFeed.allCases.map { (Tab.feed($0), $0.title) },
                        selection: $tab
                    )
                    SearchField(
                        text: $state.searchText,
                        placeholder: "Noods shows, artists, genres",
                        focusSignal: appState.searchFocusRequests
                    )
                }
            }
            Rule(color: Palette.outline)
            genreBar
            Rule()

            if browse.selectedGenres.isEmpty {
                switch tab {
                case .discover: discover
                case .feed(let feed): feedList(feed)
                }
            } else {
                archiveResults
            }
        }
        .task { await browse.loadGenresIfNeeded() }
        .task(id: tab) {
            switch tab {
            case .discover: await browse.loadDiscoverIfNeeded()
            case .feed(let feed): await browse.loadFeedIfNeeded(feed)
            }
        }
    }

    private var subtitle: String {
        if !browse.selectedGenres.isEmpty {
            let tags = browse.selectedGenres.sorted().joined(separator: " · ")
            guard let total = browse.filtered.total, total > 0 else { return tags }
            return "\(total.formatted(.number)) shows · \(tags)"
        }
        switch tab {
        case .discover:
            return "Broadcasting from Bristol"
        case .feed(let feed):
            let count = browse.feed(feed).items.count
            return count > 0 ? "\(count) shows loaded" : feed.title
        }
    }

    // MARK: Genres

    /// Grouped exactly as Noods groups them, and multi-select, because the
    /// archive is only reachable by combining tags.
    ///
    /// The same accordion every other station uses. It was a menu here, which
    /// meant the one control that behaves identically everywhere looked and
    /// opened differently depending on which station you had come from.
    private var genreBar: some View {
        GenreFilterBar(
            groups: browse.genreGroups.map {
                GenreFilterGroup(name: $0.name, genres: $0.genres)
            },
            selection: Binding(
                get: { browse.selectedGenres },
                set: { chosen in
                    // The store owns the selection because choosing a tag asks
                    // Noods rather than narrowing what is on screen, so each
                    // change goes through its own toggle.
                    for genre in chosen.subtracting(browse.selectedGenres) {
                        browse.toggle(genre: genre)
                    }
                    for genre in browse.selectedGenres.subtracting(chosen) {
                        browse.toggle(genre: genre)
                    }
                    if chosen.isEmpty { browse.clearGenres() }
                }
            )
        )
    }

    /// What the station returns for the chosen tags — the archive proper,
    /// rather than the landing page narrowed down.
    @ViewBuilder
    private var archiveResults: some View {
        let state = browse.filtered
        if state.items.isEmpty, state.isLoading {
            LoadingPane(label: "Digging through the archive")
        } else if state.items.isEmpty, let error = state.error {
            EmptyStateView(headline: "Noods unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadMoreFiltered() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if state.items.isEmpty, state.hasLoadedOnce {
            EmptyStateView(
                headline: "No shows",
                message: "Nothing in the Noods archive is tagged with that combination."
            ) {
                Button("Clear") { browse.clearGenres() }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            ScrollView {
                NoodsShowGrid(shows: state.items)
                    .padding(.top, 22)

                LoadMoreFooter(
                    isLoading: state.isLoading,
                    hasMore: state.hasMore,
                    error: state.error,
                    loadedCount: state.items.count,
                    total: state.total
                ) {
                    await browse.loadMoreFiltered()
                }
            }
            .scrollIndicators(.visible)
        }
    }

    // MARK: Discover

    @ViewBuilder
    private var discover: some View {
        if browse.featuredPicks.isEmpty, browse.latestPicks.isEmpty, browse.discoverPhase.isLoading {
            LoadingPane(label: "Loading Noods")
        } else if browse.featuredPicks.isEmpty, browse.latestPicks.isEmpty,
                  let error = browse.discoverPhase.error {
            EmptyStateView(headline: "Noods unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadDiscover() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section("Featured", shows: browse.featuredPicks)
                    section("Latest", shows: browse.latestPicks)
                }
                .padding(.vertical, 22)
            }
            .scrollIndicators(.visible)
        }
    }

    @ViewBuilder
    private func section(_ title: String, shows: [NoodsShow]) -> some View {
        let visible = filtered(shows)
        if !visible.isEmpty {
            HStack {
                Text(title).microLabel(1.8).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(visible.count)").microLabel(1.2).foregroundStyle(Palette.inkFaint)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 12)

            NoodsShowGrid(shows: visible)
                .padding(.bottom, 30)
        }
    }

    // MARK: Feeds

    @ViewBuilder
    private func feedList(_ feed: NoodsFeed) -> some View {
        let state = browse.feed(feed)
        let visible = filtered(state.items)

        if state.items.isEmpty, state.isLoading {
            LoadingPane(label: "Loading \(feed.title.lowercased())")
        } else if state.items.isEmpty, let error = state.error {
            EmptyStateView(headline: "Noods unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadMore(feed) } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if state.items.isEmpty {
            EmptyStateView(
                headline: "Nothing here",
                message: "Noods isn't publishing anything under \(feed.title) right now."
            ) { EmptyView() }
        } else if visible.isEmpty {
            EmptyStateView(headline: "No matches", message: "No loaded Noods shows match “\(appState.searchText)”.") {
                Button("Clear Search") { appState.searchText = "" }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            ScrollView {
                NoodsShowGrid(shows: visible)
                    .padding(.top, 22)

                LoadMoreFooter(
                    isLoading: state.isLoading,
                    hasMore: state.hasMore,
                    error: state.error,
                    loadedCount: state.items.count,
                    total: nil
                ) {
                    await browse.loadMore(feed)
                }
            }
            .scrollIndicators(.visible)
        }
    }

    private func filtered(_ shows: [NoodsShow]) -> [NoodsShow] {
        let query = LibraryKey.normalize(appState.searchText)
        guard !query.isEmpty else { return shows }
        return shows.filter { show in
            [show.title, show.artist, show.subtitle]
                .compactMap { $0 }
                .map(LibraryKey.normalize)
                .contains { $0.contains(query) }
                || show.genres.map(LibraryKey.normalize).contains { $0.contains(query) }
        }
    }
}
