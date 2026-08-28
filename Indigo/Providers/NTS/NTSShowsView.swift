//
//  NTSShowsView.swift
//  Indigo
//
//  The A–Z of NTS residencies. Typing here queries the whole catalogue rather
//  than narrowing the twelve-at-a-time page already on screen.
//

import SwiftUI

struct NTSShowsView: View {
    @Environment(AppState.self) private var appState
    @Environment(NTSBrowseStore.self) private var browse
    @State private var selectedGenres: Set<String> = []

    private var query: String {
        appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { query.count >= 2 }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(title: "Shows", subtitle: subtitle) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Search all NTS shows",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: availableGenres, selection: $selectedGenres)
            if !availableGenres.isEmpty { Rule() }

            if isSearching {
                searchResults
            } else {
                browseGrid
            }
        }
        .task { await browse.loadShowsIfNeeded() }
        .onChange(of: appState.searchText) { _, text in
            browse.updateSearch(query: text, scope: .show)
        }
        .onDisappear { browse.updateSearch(query: "", scope: .show) }
    }

    // MARK: Browse

    @ViewBuilder
    private var browseGrid: some View {
        let shows = browse.shows
        let visible = shows.items.filter { GenreTags.matches($0.genres, selection: selectedGenres) }

        if shows.items.isEmpty, shows.isLoading {
            LoadingPane(label: "Loading shows")
        } else if shows.items.isEmpty, let error = shows.error {
            EmptyStateView(headline: "NTS unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadMoreShows() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(headline: "No genre matches", message: "No loaded NTS shows match the selected genres.") {
                Button("Clear Filter") { selectedGenres.removeAll() }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            ScrollView {
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(visible) { show in
                        NTSShowTile(show: show) { appState.open(.ntsShow(alias: show.alias)) }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 22)

                LoadMoreFooter(
                    isLoading: shows.isLoading,
                    hasMore: shows.hasMore,
                    error: shows.error,
                    loadedCount: shows.items.count,
                    total: shows.total
                ) {
                    await browse.loadMoreShows()
                }
            }
            .scrollIndicators(.visible)
        }
    }

    // MARK: Search

    @ViewBuilder
    private var searchResults: some View {
        let results = browse.searchResults
        let shows = results.items.compactMap { $0.asShowSummary() }
        let visible = shows.filter { GenreTags.matches($0.genres, selection: selectedGenres) }

        if shows.isEmpty, results.isLoading {
            LoadingPane(label: "Searching NTS")
        } else if shows.isEmpty, let error = results.error {
            EmptyStateView(headline: "Search failed", message: error) {
                Button("Try Again") { Task { await browse.retrySearch() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if shows.isEmpty, results.hasLoadedOnce {
            EmptyStateView(
                headline: "No shows found",
                message: "NTS has no residency matching “\(query)”. It may still appear in episodes or tracklists."
            ) {
                Button("Search Everything") { appState.searchNTS(query) }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(headline: "No genre matches", message: "No NTS search results match the selected genres.") {
                Button("Clear Filter") { selectedGenres.removeAll() }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            ScrollView {
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(visible) { show in
                        NTSShowTile(show: show) { appState.open(.ntsShow(alias: show.alias)) }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 22)

                LoadMoreFooter(
                    isLoading: results.isLoading,
                    hasMore: results.hasMore,
                    error: results.error,
                    loadedCount: results.items.count,
                    total: results.total
                ) {
                    await browse.loadMoreSearchResults()
                }
            }
            .scrollIndicators(.visible)
        }
    }

    private var subtitle: String {
        if isSearching {
            guard let total = browse.searchResults.total else { return "Searching NTS" }
            return "\(total.formatted(.number)) \(total == 1 ? "show" : "shows") matching “\(query)”"
        }
        guard let total = browse.shows.total, total > 0 else { return "NTS residencies" }
        return "\(browse.shows.items.count.formatted(.number)) of \(total.formatted(.number)) loaded"
    }

    private var availableGenres: [String] {
        let shows = isSearching
            ? browse.searchResults.items.compactMap { $0.asShowSummary() }
            : browse.shows.items
        return GenreTags.available(in: shows.flatMap(\.genres))
    }
}
