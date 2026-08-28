//
//  NoodsShowsView.swift
//  Indigo
//
//  Discover, and the three feeds behind it. Noods calls its /shows landing
//  page "Discover" — two curated lists — with Featured, Latest and Guests as
//  paged feeds beside it, so the tabs mirror the station's own structure.
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
    @State private var selectedGenres: Set<String> = []

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
            GenreFilterBar(genres: availableGenres, selection: $selectedGenres)
            if !availableGenres.isEmpty { Rule() }

            switch tab {
            case .discover: discover
            case .feed(let feed): feedList(feed)
            }
        }
        .task(id: tab) {
            switch tab {
            case .discover: await browse.loadDiscoverIfNeeded()
            case .feed(let feed): await browse.loadFeedIfNeeded(feed)
            }
        }
    }

    private var subtitle: String {
        switch tab {
        case .discover:
            return "Broadcasting from Bristol"
        case .feed(let feed):
            let count = browse.feed(feed).items.count
            return count > 0 ? "\(count) shows loaded" : feed.title
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
            EmptyStateView(headline: "No matches", message: "No loaded Noods shows match the current search and genres.") {
                Button("Clear Filters") {
                    appState.searchText = ""
                    selectedGenres.removeAll()
                }.buttonStyle(OutlineButtonStyle())
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

    private var currentShows: [NoodsShow] {
        switch tab {
        case .discover: browse.featuredPicks + browse.latestPicks
        case .feed(let feed): browse.feed(feed).items
        }
    }

    private var availableGenres: [String] {
        GenreTags.available(in: currentShows.flatMap(\.genres))
    }

    private func filtered(_ shows: [NoodsShow]) -> [NoodsShow] {
        let query = LibraryKey.normalize(appState.searchText)
        return shows.filter { show in
            GenreTags.matches(show.genres, selection: selectedGenres)
                && (query.isEmpty || [show.title, show.artist, show.subtitle]
                    .compactMap { $0 }
                    .map(LibraryKey.normalize)
                    .contains { $0.contains(query) }
                    || show.genres.map(LibraryKey.normalize).contains { $0.contains(query) })
        }
    }
}
