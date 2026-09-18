//
//  N10ASArchiveView.swift
//  Indigo
//
//  Everything n10.as has published, newest first — 11,849 broadcasts back to
//  February 2016, which is the station's whole run.
//
//  This is the archive rather than a "latest": Mixcloud pages the feed all the
//  way down by cursor, so it really does go to the bottom. It goes fifty at a
//  time, and the page says how far in it is, because the difference between
//  loading a hundred and having reached the end is the difference between a
//  quiet page and a wrong one.
//

import SwiftUI

struct N10ASArchiveView: View {
    @Environment(AppState.self) private var appState
    @Environment(N10ASBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    @State private var selectedGenres: Set<String> = []

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
                    placeholder: "Search loaded broadcasts",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: availableGenres, selection: $selectedGenres)
            if !availableGenres.isEmpty { Rule() }
            content
        }
        .task { await browse.loadArchiveIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.archive.isEmpty, browse.archivePhase.isLoading {
            LoadingPane(label: "Loading broadcasts")
        } else if browse.archive.isEmpty, let error = browse.archivePhase.error {
            EmptyStateView(headline: "n10.as unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadArchive() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if browse.archive.isEmpty {
            EmptyStateView(
                headline: "Nothing published",
                message: "n10.as isn't publishing recordings right now."
            ) {
                EmptyView()
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: isSearching ? "No matches" : "No genre matches",
                message: isSearching
                    ? "Nothing loaded so far matches “\(query)”. Load more of the archive, or try the show pages."
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
                    Button("Browse Shows") { appState.select(.n10asShows) }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        } else {
            grid(visible)
        }
    }

    private func grid(_ episodes: [N10ASEpisode]) -> some View {
        ScrollView {
            LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                ForEach(episodes) { episode in
                    N10ASEpisodeTile(
                        episode: episode,
                        isCurrent: N10ASPlayback.isCurrent(episode, in: player),
                        isPlaying: N10ASPlayback.isPlaying(episode, in: player),
                        open: {
                            browse.remember([episode])
                            appState.open(.n10asEpisode(id: episode.id))
                        },
                        play: {
                            N10ASPlayback.toggle(episode, within: episodes, using: player)
                        }
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
            VStack(spacing: 10) {
                Button("Load More") { Task { await browse.loadMore() } }
                    .buttonStyle(OutlineButtonStyle())
                if let remaining, remaining > 0 {
                    Text("\(remaining) further back")
                        .microLabel(1.4)
                        .foregroundStyle(Palette.inkFaint)
                }
            }
            .frame(maxWidth: .infinity)
        } else if let error = browse.archivePhase.error {
            NoticeStrip(text: "Couldn't load more broadcasts. \(error)")
        } else {
            Text("The beginning — February 2016")
                .microLabel(1.4)
                .foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity)
        }
    }

    private var remaining: Int? {
        guard let total = browse.archiveTotal else { return nil }
        return max(0, total - browse.archive.count)
    }

    private var visible: [N10ASEpisode] {
        browse.archive.filter { episode in
            guard GenreTags.matches(episode.genres, selection: selectedGenres) else { return false }
            guard isSearching else { return true }
            var haystack = [
                episode.title,
                episode.programme ?? "",
                episode.guest ?? "",
                episode.summary ?? ""
            ]
            haystack += episode.genres
            return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var availableGenres: [String] {
        GenreTags.available(in: browse.archive.flatMap(\.genres))
    }

    private var subtitle: String {
        guard !browse.archive.isEmpty else { return "Every n10.as broadcast" }
        if isSearching {
            return "\(visible.count) matching “\(query)” in \(browse.archive.count) loaded"
        }
        if let total = browse.archiveTotal, browse.canLoadMore {
            return "\(browse.archive.count) of \(total) broadcasts"
        }
        return browse.canLoadMore
            ? "\(browse.archive.count) broadcasts so far"
            : "\(browse.archive.count) broadcasts"
    }
}
