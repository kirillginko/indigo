//
//  CashmereShowsView.swift
//  Indigo
//
//  Cashmere's shows. The station files them as categories, so the directory is
//  small enough to hold whole and search honestly.
//

import SwiftUI

struct CashmereShowsView: View {
    @Environment(AppState.self) private var appState
    @Environment(CashmereBrowseStore.self) private var browse

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
        .task {
            async let shows: Void = browse.loadShowsIfNeeded()
            async let archive: Void = browse.loadArchiveIfNeeded()
            _ = await (shows, archive)
        }
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.shows.isEmpty, browse.showsPhase.isLoading {
            LoadingPane(label: "Loading shows")
        } else if browse.shows.isEmpty, let error = browse.showsPhase.error {
            EmptyStateView(headline: "Cashmere unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadShows() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: "No shows found",
                message: "Cashmere has no show matching “\(query)”."
            ) {
                EmptyView()
            }
        } else {
            ScrollView {
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(visible) { show in
                        CashmereShowTile(
                            show: show,
                            open: { appState.open(.cashmereShow(slug: show.slug)) },
                            artworkURL: artwork(for: show)
                        )
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
            .scrollIndicators(.visible)
        }
    }

    /// A category carries no picture of its own, so the grid borrows one from
    /// whichever of its episodes is already in hand.
    private func artwork(for show: CashmereShow) -> URL? {
        browse.episodes(ofShow: show.slug).first?.artworkURL
            ?? browse.episodes.first { $0.showSlug == show.slug }?.artworkURL
    }

    private var visible: [CashmereShow] {
        guard isSearching else { return browse.shows }
        return browse.shows.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var subtitle: String {
        if isSearching {
            let count = visible.count
            return "\(count) \(count == 1 ? "show" : "shows") matching “\(query)”"
        }
        return browse.shows.isEmpty ? "Cashmere Radio shows" : "\(browse.shows.count) shows"
    }
}
