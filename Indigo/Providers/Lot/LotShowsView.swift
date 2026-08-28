//
//  LotShowsView.swift
//  Indigo
//
//  The Lot's residencies. The directory is small enough to hold whole, so
//  searching it is a real search rather than a search of what happens to be
//  on screen.
//

import SwiftUI

struct LotShowsView: View {
    @Environment(AppState.self) private var appState
    @Environment(LotBrowseStore.self) private var browse

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
                    placeholder: "Search residencies",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: availableGenres, selection: $selectedGenres)
            if !availableGenres.isEmpty { Rule() }
            content
        }
        .task { await browse.loadShowsIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.shows.isEmpty, browse.showsPhase.isLoading {
            LoadingPane(label: "Loading shows")
        } else if browse.shows.isEmpty, let error = browse.showsPhase.error {
            EmptyStateView(headline: "The Lot unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadShows() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: "No shows found",
                message: isSearching
                    ? "The Lot has no residency matching “\(query)”."
                    : "No residencies match the selected genres."
            ) {
                if !selectedGenres.isEmpty {
                    Button("Clear Filter") { selectedGenres.removeAll() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(visible) { show in
                        LotShowTile(show: show) {
                            appState.open(.lotShow(slug: show.slug))
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
            .scrollIndicators(.visible)
        }
    }

    private var visible: [LotShow] {
        browse.shows.filter { show in
            guard GenreTags.matches(show.genres.map(\.name), selection: selectedGenres) else { return false }
            guard isSearching else { return true }
            let haystack = [show.name] + show.artists.map(\.name) + show.genres.map(\.name)
            return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var subtitle: String {
        if isSearching {
            let count = visible.count
            return "\(count) \(count == 1 ? "show" : "shows") matching “\(query)”"
        }
        return browse.shows.isEmpty
            ? "The Lot Radio residencies"
            : "\(browse.shows.count) residencies"
    }

    private var availableGenres: [String] {
        GenreTags.available(in: browse.shows.flatMap { $0.genres.map(\.name) })
    }
}
