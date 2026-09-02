//
//  PanikShowsView.swift
//  Indigo
//
//  Radio Panik's shows — a hundred and twenty-four of them, and the way into
//  the archive proper, since each keeps its own feed.
//
//  The whole directory arrives in one request, so the six headings Panik files
//  its shows under narrow it here rather than at the station.
//

import SwiftUI

struct PanikShowsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PanikBrowseStore.self) private var browse

    @State private var selectedCategories: Set<String> = []

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
            GenreFilterBar(genres: availableCategories, selection: $selectedCategories)
            if !availableCategories.isEmpty { Rule() }
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
            EmptyStateView(headline: "Radio Panik unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadShows() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: "No shows found",
                message: isSearching
                    ? "Nothing matches “\(query)”."
                    : "No shows under the selected headings."
            ) {
                if !selectedCategories.isEmpty {
                    Button("Clear Filter") { selectedCategories.removeAll() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(visible) { show in
                        PanikShowTile(show: show) {
                            appState.open(.panikShow(slug: show.slug))
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

    private var visible: [PanikShow] {
        browse.shows.filter { show in
            guard GenreTags.matches(show.categories, selection: selectedCategories) else {
                return false
            }
            guard isSearching else { return true }
            return [show.title, show.summary ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var availableCategories: [String] {
        GenreTags.available(in: browse.shows.flatMap(\.categories))
    }

    private var subtitle: String {
        if isSearching {
            let count = visible.count
            return "\(count) \(count == 1 ? "show" : "shows") matching “\(query)”"
        }
        guard !browse.shows.isEmpty else { return "Radio Panik shows" }
        let count = visible.count
        return selectedCategories.isEmpty
            ? "\(count) \(count == 1 ? "show" : "shows")"
            : "\(count) of \(browse.shows.count) shows"
    }
}
