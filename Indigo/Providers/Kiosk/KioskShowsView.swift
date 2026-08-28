//
//  KioskShowsView.swift
//  Indigo
//
//  Kiosk's archive of shows. The browse list is the hundred most recent
//  broadcasts; typing queries the whole archive rather than narrowing them.
//

import SwiftUI

struct KioskShowsView: View {
    @Environment(AppState.self) private var appState
    @Environment(KioskBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player
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
                    placeholder: "Search the Kiosk archive",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: availableGenres, selection: $selectedGenres)
            if !availableGenres.isEmpty { Rule() }

            if isSearching {
                results(
                    episodes: browse.searchResults,
                    phase: browse.searchPhase,
                    loadingLabel: "Searching Kiosk",
                    emptyHeadline: "No shows found",
                    emptyMessage: "Kiosk has nothing in its archive matching “\(query)”.",
                    retry: { await browse.retrySearch() }
                )
            } else {
                results(
                    episodes: browse.library,
                    phase: browse.libraryPhase,
                    loadingLabel: "Loading shows",
                    emptyHeadline: "Nothing to play",
                    emptyMessage: "Kiosk isn't publishing any archived shows right now.",
                    retry: { await browse.loadLibrary() }
                )
            }
        }
        .task { await browse.loadLibraryIfNeeded() }
        .onChange(of: appState.searchText) { _, text in
            browse.updateSearch(query: text)
        }
        .onDisappear { browse.updateSearch(query: "") }
    }

    @ViewBuilder
    private func results(
        episodes: [KioskEpisode],
        phase: KioskBrowseStore.Phase,
        loadingLabel: String,
        emptyHeadline: String,
        emptyMessage: String,
        retry: @escaping () async -> Void
    ) -> some View {
        let visible = episodes.filter { GenreTags.matches($0.genres, selection: selectedGenres) }
        if episodes.isEmpty, phase.isLoading {
            LoadingPane(label: loadingLabel)
        } else if episodes.isEmpty, let error = phase.error {
            EmptyStateView(headline: "Kiosk unreachable", message: error) {
                Button("Try Again") { Task { await retry() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if episodes.isEmpty {
            EmptyStateView(headline: emptyHeadline, message: emptyMessage) {
                EmptyView()
            }
        } else if visible.isEmpty {
            EmptyStateView(headline: "No genre matches", message: "No loaded Kiosk shows match the selected genres.") {
                Button("Clear Filter") { selectedGenres.removeAll() }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            ScrollView {
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(visible) { episode in
                        KioskEpisodeTile(
                            episode: episode,
                            isCurrent: KioskPlayback.isCurrent(episode, in: player),
                            isPlaying: KioskPlayback.isPlaying(episode, in: player),
                            open: { appState.open(.kioskEpisode(slug: episode.slug)) }
                        ) {
                            KioskPlayback.toggle(episode, within: visible, using: player)
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
            .scrollIndicators(.visible)
        }
    }

    private var subtitle: String {
        if isSearching {
            let count = browse.searchResults.count
            return "\(count) \(count == 1 ? "show" : "shows") matching “\(query)”"
        }
        return browse.library.isEmpty
            ? "The Kiosk archive"
            : "\(browse.library.count) most recent shows"
    }

    private var availableGenres: [String] {
        let episodes = isSearching ? browse.searchResults : browse.library
        return GenreTags.available(in: episodes.flatMap(\.genres))
    }
}
