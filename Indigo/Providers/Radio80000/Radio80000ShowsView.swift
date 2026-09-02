//
//  Radio80000ShowsView.swift
//  Indigo
//
//  Radio 80000's shows — a hundred and ninety-three of them, and the way into
//  the archive proper, since each one's back catalogue lives on its own
//  playlists rather than in any flat listing.
//
//  The whole directory arrives in two requests, so genre and search narrow it
//  here rather than at the station.
//

import SwiftUI

struct Radio80000ShowsView: View {
    @Environment(AppState.self) private var appState
    @Environment(Radio80000BrowseStore.self) private var browse

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
                    placeholder: "Search shows",
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
            EmptyStateView(headline: "Radio 80000 unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadShows() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: "No shows found",
                message: isSearching
                    ? "Nothing matches “\(query)”."
                    : "No shows under the selected genres."
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
                        Radio80000ShowTile(show: show) {
                            appState.open(.radio80000Show(slug: show.slug))
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)

                Text("The whole directory")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 30)
            }
            .scrollIndicators(.visible)
        }
    }

    private var visible: [Radio80000Show] {
        browse.shows.filter { show in
            guard GenreTags.matches(show.genres, selection: selectedGenres) else { return false }
            guard isSearching else { return true }
            var haystack = [show.title, show.summary ?? "", show.city ?? ""]
            haystack += show.genres
            return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var availableGenres: [String] {
        GenreTags.available(in: browse.shows.flatMap(\.genres))
    }

    private var subtitle: String {
        if isSearching {
            let count = visible.count
            return "\(count) \(count == 1 ? "show" : "shows") matching “\(query)”"
        }
        guard !browse.shows.isEmpty else { return "Radio 80000 shows" }
        let count = visible.count
        return selectedGenres.isEmpty
            ? "\(count) \(count == 1 ? "show" : "shows")"
            : "\(count) of \(browse.shows.count) shows"
    }
}
