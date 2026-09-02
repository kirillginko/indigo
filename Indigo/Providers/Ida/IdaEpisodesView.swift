//
//  IdaEpisodesView.swift
//  Indigo
//
//  IDA's archive, newest first — twenty thousand episodes deep.
//
//  The genre bar is the same control every other station uses, but it narrows
//  at the station rather than on screen: with an archive this size, filtering
//  the loaded page would be filtering a rounding error of it. Search is the
//  other way round — IDA publishes no search endpoint — so it narrows what has
//  been loaded, and the page says as much.
//

import SwiftUI

struct IdaEpisodesView: View {
    @Environment(AppState.self) private var appState
    @Environment(IdaBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    private var query: String {
        appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { query.count >= 2 }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(title: "Episodes", subtitle: subtitle) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Search loaded episodes",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: browse.genres.map(\.name), selection: genreSelection)
            if !browse.genres.isEmpty { Rule() }
            content
        }
        .task {
            async let archive: Void = browse.loadArchiveIfNeeded()
            async let genres: Void = browse.loadGenresIfNeeded()
            _ = await (archive, genres)
        }
    }

    /// Writes straight through to the store, which re-asks IDA. The bar is a
    /// plain multi-select; that it costs a request rather than a filter pass
    /// is the store's business, not the control's.
    private var genreSelection: Binding<Set<String>> {
        Binding(
            get: { browse.selectedGenres },
            set: { browse.setGenres($0) }
        )
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.episodes.isEmpty, browse.archivePhase.isLoading {
            LoadingPane(label: "Loading the archive")
        } else if browse.episodes.isEmpty, let error = browse.archivePhase.error {
            EmptyStateView(headline: "IDA unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadArchive() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if browse.episodes.isEmpty {
            EmptyStateView(
                headline: "Nothing archived",
                message: browse.selectedGenres.isEmpty
                    ? "IDA isn't publishing an archive right now."
                    : "IDA has nothing archived under \(browse.selectedGenres.sorted().joined(separator: ", "))."
            ) {
                if !browse.selectedGenres.isEmpty {
                    Button("Clear Filter") { browse.setGenres([]) }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: "No matches",
                message: "Nothing loaded matches “\(query)”. Load more to search further back."
            ) {
                if browse.canLoadMore {
                    Button("Load More") { Task { await browse.loadMore() } }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        } else {
            grid(visible)
        }
    }

    private func grid(_ episodes: [IdaEpisode]) -> some View {
        ScrollView {
            LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                ForEach(episodes) { episode in
                    IdaEpisodeTile(
                        episode: episode,
                        isCurrent: IdaPlayback.isCurrent(episode, in: player),
                        isPlaying: IdaPlayback.isPlaying(episode, in: player),
                        open: {
                            browse.remember([episode])
                            appState.open(.idaEpisode(slug: episode.slug))
                        },
                        play: { IdaPlayback.toggle(episode, within: episodes, using: player) }
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

    private var visible: [IdaEpisode] {
        guard isSearching else { return browse.episodes }
        return browse.episodes.filter { episode in
            var haystack = [
                episode.title,
                episode.subtitle ?? "",
                episode.showTitle ?? "",
                episode.showArtist ?? ""
            ]
            haystack += episode.genres
            return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var subtitle: String {
        guard !browse.episodes.isEmpty else { return "The IDA Radio archive" }
        if isSearching {
            return "\(visible.count) matching “\(query)” in \(browse.episodes.count) loaded"
        }
        let count = browse.canLoadMore
            ? "\(browse.episodes.count) episodes so far"
            : "\(browse.episodes.count) episodes"
        guard !browse.selectedGenres.isEmpty else { return count }
        return "\(count) · \(browse.selectedGenres.sorted().joined(separator: ", "))"
    }
}
