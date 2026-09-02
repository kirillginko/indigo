//
//  RovrShowsView.swift
//  Indigo
//
//  ROVR's shows — the ones still running, of four hundred on the books.
//
//  The roster is small enough to hold whole, so search and filtering happen
//  here. That is the opposite of the archive next door, and deliberately so:
//  narrowing on screen is right when the whole set is on screen.
//

import SwiftUI

struct RovrShowsView: View {
    @Environment(AppState.self) private var appState
    @Environment(RovrBrowseStore.self) private var browse

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
            EmptyStateView(headline: "ROVR unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadShows() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: "No shows found",
                message: "Nothing matches “\(query)”."
            ) {
                Button("Clear Search") { appState.searchText = "" }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            ScrollView {
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(visible) { show in
                        RovrShowTile(show: show) {
                            appState.open(.rovrShow(id: show.documentID))
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)

                Text("Shows still running")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 30)
            }
            .scrollIndicators(.visible)
        }
    }

    private var visible: [RovrShow] {
        guard isSearching else { return browse.shows }
        return browse.shows.filter { show in
            ([show.title, show.summary ?? ""] + show.curators)
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var subtitle: String {
        if isSearching {
            let count = visible.count
            return "\(count) \(count == 1 ? "show" : "shows") matching “\(query)”"
        }
        guard !browse.shows.isEmpty else { return "ROVR shows" }
        return "\(browse.shows.count) shows"
    }
}
