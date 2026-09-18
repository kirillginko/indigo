//
//  N10ASShowsView.swift
//  Indigo
//
//  n10.as's shows — the hundred and forty-seven programmes the station is
//  currently running.
//
//  This is the directory, not the archive: it is what n10.as publishes as its
//  present schedule, and the recordings go back to 2016 under several hundred
//  programmes that have since ended. Those are in the Archive, which is why
//  this page says what it is a list of.
//

import SwiftUI

struct N10ASShowsView: View {
    @Environment(AppState.self) private var appState
    @Environment(N10ASBrowseStore.self) private var browse

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
            EmptyStateView(headline: "n10.as unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadShows() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: "No shows found",
                message: isSearching
                    ? "Nothing in the current schedule matches “\(query)”. A show that has ended its run is still in the Archive."
                    : "No shows under the selected genres."
            ) {
                HStack(spacing: 10) {
                    if !selectedGenres.isEmpty {
                        Button("Clear Filter") { selectedGenres.removeAll() }
                            .buttonStyle(OutlineButtonStyle())
                    }
                    if isSearching {
                        Button("Search the Archive") { appState.select(.n10asArchive) }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(visible) { show in
                        N10ASShowTile(show: show) {
                            appState.open(.n10asShow(slug: show.slug))
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)

                Text("The current schedule — earlier programmes are in the Archive")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 30)
            }
            .scrollIndicators(.visible)
        }
    }

    private var visible: [N10ASShow] {
        browse.shows.filter { show in
            guard GenreTags.matches(show.genres, selection: selectedGenres) else { return false }
            guard isSearching else { return true }
            var haystack = [show.title, show.summary ?? "", show.timeslot ?? ""]
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
        guard !browse.shows.isEmpty else { return "n10.as shows" }
        let count = visible.count
        return selectedGenres.isEmpty
            ? "\(count) \(count == 1 ? "show" : "shows")"
            : "\(count) of \(browse.shows.count) shows"
    }
}
