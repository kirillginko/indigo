//
//  LotIndexView.swift
//  Indigo
//
//  The Index: every broadcast The Lot has archived, newest first. There are
//  thousands, so the page walks the archive a chunk at a time and says plainly
//  how far in it has got — searching and filtering narrow what has been loaded
//  rather than pretending to reach the rest.
//

import SwiftUI

struct LotIndexView: View {
    @Environment(AppState.self) private var appState
    @Environment(LotBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    @State private var selectedGenres: Set<String> = []

    private var query: String {
        appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { query.count >= 2 }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(title: "The Index", subtitle: subtitle) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Search loaded broadcasts",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: availableGenres, selection: $selectedGenres)
            if !availableGenres.isEmpty { Rule() }
            content
        }
        .task { await browse.loadIndexIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.episodes.isEmpty, browse.indexPhase.isLoading {
            LoadingPane(label: "Loading the index")
        } else if browse.episodes.isEmpty, let error = browse.indexPhase.error {
            EmptyStateView(headline: "The Lot unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadIndex() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if browse.episodes.isEmpty {
            EmptyStateView(
                headline: "Nothing archived",
                message: "The Lot isn't publishing any archived broadcasts right now."
            ) {
                EmptyView()
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: isSearching ? "No matches" : "No genre matches",
                message: isSearching
                    ? "Nothing loaded from the index matches “\(query)”. Load more to search further back."
                    : "No loaded broadcasts match the selected genres."
            ) {
                HStack(spacing: 10) {
                    if !selectedGenres.isEmpty {
                        Button("Clear Filter") { selectedGenres.removeAll() }
                            .buttonStyle(OutlineButtonStyle())
                    }
                    if browse.canLoadMore {
                        Button("Load More") { Task { await browse.loadMore() } }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
            }
        } else {
            grid(visible)
        }
    }

    private func grid(_ episodes: [LotEpisode]) -> some View {
        ScrollView {
            LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                ForEach(episodes) { episode in
                    LotEpisodeTile(
                        episode: episode,
                        isCurrent: LotPlayback.isCurrent(episode, in: player),
                        isPlaying: LotPlayback.isPlaying(episode, in: player),
                        open: { open(episode) },
                        play: { LotPlayback.toggle(episode, within: episodes, using: player) }
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
            HStack(spacing: 10) {
                Text("Loading more")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkFaint)
            }
            .frame(maxWidth: .infinity)
        } else if browse.canLoadMore {
            Button("Load More") { Task { await browse.loadMore() } }
                .buttonStyle(OutlineButtonStyle())
                .frame(maxWidth: .infinity)
        } else if let error = browse.indexPhase.error {
            NoticeStrip(text: "Couldn't load more of the index. \(error)")
        } else {
            Text("End of the archive")
                .microLabel(1.4)
                .foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity)
        }
    }

    private func open(_ episode: LotEpisode) {
        guard let ref = episode.ref else { return }
        browse.remember([episode])
        appState.open(.lotEpisode(show: ref.show, episode: ref.episode))
    }

    // MARK: - Filtering

    private var visible: [LotEpisode] {
        browse.episodes.filter { episode in
            GenreTags.matches(episode.genreNames, selection: selectedGenres) && matchesQuery(episode)
        }
    }

    /// Titles, residency, genres and the tracklist — the archive's own search
    /// looks at rather less, and a set is often remembered by one record in it.
    private func matchesQuery(_ episode: LotEpisode) -> Bool {
        guard isSearching else { return true }
        var haystack = [episode.title, episode.show?.name ?? ""]
        haystack += episode.genreNames
        haystack += episode.artists.map(\.name)
        haystack += episode.tracklist.flatMap { [$0.title, $0.artist ?? ""] }
        return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private var subtitle: String {
        if isSearching {
            let count = visible.count
            return "\(count) \(count == 1 ? "broadcast" : "broadcasts") matching “\(query)” in \(browse.episodes.count) loaded"
        }
        guard !browse.episodes.isEmpty else { return "The Lot Radio archive" }
        let total = max(browse.indexTotal, browse.episodes.count)
        return "\(browse.episodes.count.formatted(.number)) of \(total.formatted(.number)) broadcasts"
    }

    private var availableGenres: [String] {
        GenreTags.available(in: browse.episodes.flatMap(\.genreNames))
    }
}
