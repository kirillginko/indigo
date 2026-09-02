//
//  IdaShowsView.swift
//  Indigo
//
//  IDA's shows — five hundred of them across the two studios. Genre narrows
//  the directory at the station, so the whole of it stays reachable.
//
//  Shows that have finished running are listed alongside the rest. IDA marks
//  four of its five hundred that way, and all four still have their recordings
//  up — so hiding them was a control that cost a row of chrome to filter
//  almost nothing out.
//

import SwiftUI

struct IdaShowsView: View {
    @Environment(AppState.self) private var appState
    @Environment(IdaBrowseStore.self) private var browse

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
                    placeholder: "Search loaded shows",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: browse.genres.map(\.name), selection: genreSelection)
            if !browse.genres.isEmpty { Rule() }
            content
        }
        .task {
            async let directory: Void = browse.loadShowsIfNeeded()
            async let genres: Void = browse.loadGenresIfNeeded()
            _ = await (directory, genres)
        }
    }

    private var genreSelection: Binding<Set<String>> {
        Binding(
            get: { browse.selectedShowGenres },
            set: { browse.setShowGenres($0) }
        )
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.shows.isEmpty, browse.showsPhase.isLoading {
            LoadingPane(label: "Loading shows")
        } else if browse.shows.isEmpty, let error = browse.showsPhase.error {
            EmptyStateView(headline: "IDA unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadShows() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: "No shows found",
                message: isSearching
                    ? "Nothing loaded matches “\(query)”."
                    : "IDA has no shows under that."
            ) {
                if !browse.selectedShowGenres.isEmpty {
                    Button("Clear Filter") { browse.setShowGenres([]) }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(visible) { show in
                        IdaShowTile(show: show) {
                            appState.open(.idaShow(slug: show.slug))
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)

                footer
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 30)
            }
            .scrollIndicators(.visible)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if browse.isLoadingMoreShows {
            Text("Loading more").microLabel(1.4).foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity)
        } else if browse.canLoadMoreShows {
            Button("Load More") { Task { await browse.loadMoreShows() } }
                .buttonStyle(OutlineButtonStyle())
                .frame(maxWidth: .infinity)
        } else {
            Text("End of the directory").microLabel(1.4).foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity)
        }
    }

    private var visible: [IdaShow] {
        guard isSearching else { return browse.shows }
        return browse.shows.filter { show in
            ([show.title, show.artist ?? "", show.summary ?? ""] + show.genres)
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var subtitle: String {
        if isSearching {
            let count = visible.count
            return "\(count) \(count == 1 ? "show" : "shows") matching “\(query)”"
        }
        guard !browse.shows.isEmpty else { return "IDA Radio shows" }
        let count = browse.canLoadMoreShows
            ? "\(visible.count) shows so far"
            : "\(visible.count) shows"
        guard !browse.selectedShowGenres.isEmpty else { return count }
        return "\(count) · \(browse.selectedShowGenres.sorted().joined(separator: ", "))"
    }
}
