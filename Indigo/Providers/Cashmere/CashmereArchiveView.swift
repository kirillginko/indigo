//
//  CashmereArchiveView.swift
//  Indigo
//
//  Cashmere's archive. Searching re-asks the station rather than filtering the
//  page, so the whole thing is reachable.
//

import SwiftUI

struct CashmereArchiveView: View {
    @Environment(AppState.self) private var appState
    @Environment(CashmereBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    @State private var selectedGenres: Set<String> = []

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(title: "Archive", subtitle: subtitle) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Search the Cashmere archive",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: availableGenres, selection: $selectedGenres)
            if !availableGenres.isEmpty { Rule() }
            content
        }
        .task { await browse.loadArchiveIfNeeded() }
        .onChange(of: appState.searchText) { _, text in browse.updateSearch(text) }
        .onDisappear { browse.updateSearch("") }
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.episodes.isEmpty, browse.archivePhase.isLoading {
            LoadingPane(label: browse.isSearching ? "Searching Cashmere" : "Loading the archive")
        } else if browse.episodes.isEmpty, let error = browse.archivePhase.error {
            EmptyStateView(headline: "Cashmere unreachable", message: error) {
                Button("Try Again") { Task { await browse.reloadArchive() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if browse.episodes.isEmpty {
            EmptyStateView(
                headline: browse.isSearching ? "No matches" : "Nothing archived",
                message: browse.isSearching
                    ? "Cashmere has nothing in its archive matching “\(browse.search)”."
                    : "Cashmere isn't publishing an archive right now."
            ) {
                EmptyView()
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: "No genre matches",
                message: "No loaded episodes match the selected genres."
            ) {
                Button("Clear Filter") { selectedGenres.removeAll() }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            grid(visible)
        }
    }

    private func grid(_ episodes: [CashmereEpisode]) -> some View {
        ScrollView {
            LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                ForEach(episodes) { episode in
                    CashmereEpisodeTile(
                        episode: episode,
                        isCurrent: CashmerePlayback.isCurrent(episode, in: player),
                        isPlaying: CashmerePlayback.isPlaying(episode, in: player),
                        open: {
                            browse.remember([episode])
                            appState.open(.cashmereEpisode(slug: episode.slug))
                        },
                        play: { CashmerePlayback.toggle(episode, within: episodes, using: player) }
                    )
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

    @ViewBuilder
    private var footer: some View {
        if browse.isLoadingMore {
            Text("Loading more").microLabel(1.4).foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity)
        } else if browse.canLoadMore {
            Button("Load More") { Task { await browse.loadMore() } }
                .buttonStyle(OutlineButtonStyle())
                .frame(maxWidth: .infinity)
        } else if let error = browse.archivePhase.error {
            NoticeStrip(text: "Couldn't load more of the archive. \(error)")
        } else {
            Text(browse.isSearching ? "End of the results" : "End of the archive")
                .microLabel(1.4).foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity)
        }
    }

    private var visible: [CashmereEpisode] {
        browse.episodes.filter { GenreTags.matches($0.genres, selection: selectedGenres) }
    }

    private var availableGenres: [String] {
        GenreTags.available(in: browse.episodes.flatMap(\.genres))
    }

    private var subtitle: String {
        guard !browse.episodes.isEmpty else { return "The Cashmere Radio archive" }
        let count = browse.episodes.count
        if browse.isSearching {
            return "\(count) loaded matching “\(browse.search)”"
        }
        return browse.canLoadMore ? "\(count) episodes so far" : "\(count) episodes"
    }
}
