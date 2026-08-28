//
//  NTSLatestView.swift
//  Indigo
//
//  Entry point for browsing the archive: what NTS just added, and what NTS
//  itself is pointing at.
//

import SwiftUI

struct NTSLatestView: View {
    @Environment(AppState.self) private var appState
    @Environment(NTSBrowseStore.self) private var browse
    @State private var selectedGenres: Set<String> = []

    private var query: String { appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { query.count >= 2 }

    var body: some View {
        @Bindable var store = browse
        @Bindable var state = appState
        let feed = browse.feed(browse.selectedFeed)

        VStack(spacing: 0) {
            PageHeader(
                title: "Latest",
                subtitle: "NTS archive"
            ) {
                HStack(spacing: 10) {
                    SegmentedTabs(
                        options: NTSBrowseStore.EpisodeFeed.allCases.map { ($0, $0.title) },
                        selection: $store.selectedFeed
                    )
                    SearchField(
                        text: $state.searchText,
                        placeholder: "NTS shows, episodes, tracks",
                        focusSignal: appState.searchFocusRequests
                    )
                }
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: availableGenres(feed), selection: $selectedGenres)
            if !availableGenres(feed).isEmpty { Rule() }

            if isSearching {
                searchResults
            } else if feed.items.isEmpty, feed.isLoading {
                LoadingPane(label: "Loading episodes")
            } else if feed.items.isEmpty, let error = feed.error {
                EmptyStateView(headline: "NTS unreachable", message: error) {
                    Button("Try Again") {
                        Task { await browse.loadMore(browse.selectedFeed) }
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            } else {
                let visible = feed.items.filter { GenreTags.matches($0.genres + $0.moods, selection: selectedGenres) }
                ScrollView {
                    LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                        ForEach(visible) { episode in
                            NTSEpisodeTile(episode: episode) {
                                appState.open(.ntsEpisode(show: episode.showAlias,
                                                          episode: episode.episodeAlias))
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 22)

                    LoadMoreFooter(
                        isLoading: feed.isLoading,
                        hasMore: feed.hasMore,
                        error: feed.error,
                        loadedCount: feed.items.count,
                        total: feed.total
                    ) {
                        await browse.loadMore(browse.selectedFeed)
                    }
                }
                .scrollIndicators(.visible)
            }
        }
        .task(id: browse.selectedFeed) {
            await browse.loadFeedIfNeeded(browse.selectedFeed)
        }
        .onChange(of: appState.searchText) { _, value in
            browse.updateSearch(query: value, scope: .all)
        }
        .onDisappear { browse.updateSearch(query: "", scope: .all) }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = browse.searchResults
        let visible = results.items.filter {
            GenreTags.matches($0.genres, selection: selectedGenres)
        }
        if results.items.isEmpty, results.isLoading {
            LoadingPane(label: "Searching NTS")
        } else if results.items.isEmpty, let error = results.error {
            EmptyStateView(headline: "Search failed", message: error) {
                Button("Try Again") { Task { await browse.retrySearch() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(headline: "No results", message: "Nothing matches the current search and genre filters.") {
                Button("Clear Filters") {
                    selectedGenres.removeAll()
                    appState.searchText = ""
                }.buttonStyle(OutlineButtonStyle())
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { result in
                        SearchResultRow(result: result) {
                            if let destination = result.destination { appState.open(destination) }
                        }
                        Rule()
                    }
                }
                LoadMoreFooter(
                    isLoading: results.isLoading,
                    hasMore: results.hasMore,
                    error: results.error,
                    loadedCount: results.items.count,
                    total: results.total
                ) { await browse.loadMoreSearchResults() }
            }
            .scrollIndicators(.visible)
        }
    }

    private func availableGenres(_ feed: NTSBrowseStore.Feed<NTSEpisodeSummary>) -> [String] {
        if isSearching { return GenreTags.available(in: browse.searchResults.items.flatMap(\.genres)) }
        return GenreTags.available(in: feed.items.flatMap { $0.genres + $0.moods })
    }
}

/// Shared skeleton for pages waiting on their first response.
struct LoadingPane: View {
    let label: String

    var body: some View {
        VStack(spacing: 16) {
            Text(label)
                .microLabel(1.8)
                .foregroundStyle(Palette.inkFaint)
            ProgressTrack(fraction: 0.35)
                .frame(width: 120)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
