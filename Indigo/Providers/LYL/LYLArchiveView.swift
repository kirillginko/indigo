//
//  LYLArchiveView.swift
//  Indigo
//
//  LYL's archive, newest first. The station publishes no search endpoint, so
//  searching narrows what has been loaded rather than reaching the rest — and
//  the page says as much instead of implying otherwise.
//

import SwiftUI

struct LYLArchiveView: View {
    @Environment(AppState.self) private var appState
    @Environment(LYLBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    @State private var selectedStyles: Set<String> = []

    private var query: String {
        appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { query.count >= 2 }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(title: "Archive", subtitle: subtitle) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Search loaded episodes",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: availableStyles, selection: $selectedStyles)
            if !availableStyles.isEmpty { Rule() }
            content
        }
        .task { await browse.loadArchiveIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.episodes.isEmpty, browse.archivePhase.isLoading {
            LoadingPane(label: "Loading the archive")
        } else if browse.episodes.isEmpty, let error = browse.archivePhase.error {
            EmptyStateView(headline: "LYL unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadArchive() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if browse.episodes.isEmpty {
            EmptyStateView(
                headline: "Nothing archived",
                message: "LYL isn't publishing an archive right now."
            ) {
                EmptyView()
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: isSearching ? "No matches" : "No style matches",
                message: isSearching
                    ? "Nothing loaded matches “\(query)”. Load more to search further back."
                    : "No loaded episodes match the selected styles."
            ) {
                HStack(spacing: 10) {
                    if !selectedStyles.isEmpty {
                        Button("Clear Filter") { selectedStyles.removeAll() }
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

    private func grid(_ episodes: [LYLEpisode]) -> some View {
        ScrollView {
            LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                ForEach(episodes) { episode in
                    LYLEpisodeTile(
                        episode: episode,
                        isCurrent: LYLPlayback.isCurrent(episode, in: player),
                        isPlaying: LYLPlayback.isPlaying(episode, in: player),
                        open: {
                            browse.remember([episode])
                            appState.open(.lylEpisode(slug: episode.slug))
                        },
                        play: { LYLPlayback.toggle(episode, within: episodes, using: player) }
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
            Text("End of the archive").microLabel(1.4).foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity)
        }
    }

    private var visible: [LYLEpisode] {
        browse.episodes.filter { episode in
            guard GenreTags.matches(episode.styles, selection: selectedStyles) else { return false }
            guard isSearching else { return true }
            var haystack = [episode.title, episode.artists ?? "", episode.showTitle ?? ""]
            haystack += episode.styles
            haystack += episode.tracks
            return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var availableStyles: [String] {
        GenreTags.available(in: browse.episodes.flatMap(\.styles))
    }

    private var subtitle: String {
        guard !browse.episodes.isEmpty else { return "The LYL Radio archive" }
        if isSearching {
            return "\(visible.count) matching “\(query)” in \(browse.episodes.count) loaded"
        }
        return browse.canLoadMore
            ? "\(browse.episodes.count) episodes so far"
            : "\(browse.episodes.count) episodes"
    }
}
