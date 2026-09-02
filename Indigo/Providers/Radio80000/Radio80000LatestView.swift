//
//  Radio80000LatestView.swift
//  Indigo
//
//  The station's recent broadcasts, newest first.
//
//  Deliberately called Latest rather than Archive: SoundCloud stops this
//  listing at a hundred however it is asked, so this is the top of the pile
//  and not the whole of it. The depth is inside each show's own playlists,
//  and the page says where to find it rather than implying there is nothing
//  further back.
//

import SwiftUI

struct Radio80000LatestView: View {
    @Environment(AppState.self) private var appState
    @Environment(Radio80000BrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    @State private var selectedGenres: Set<String> = []

    private var query: String {
        appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { query.count >= 2 }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(title: "Latest", subtitle: subtitle) {
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
        .task { await browse.loadLatestIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.latest.isEmpty, browse.latestPhase.isLoading {
            LoadingPane(label: "Loading broadcasts")
        } else if browse.latest.isEmpty, let error = browse.latestPhase.error {
            EmptyStateView(headline: "Radio 80000 unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadLatest() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if browse.latest.isEmpty {
            EmptyStateView(
                headline: "Nothing published",
                message: "Radio 80000 isn't publishing recent broadcasts right now."
            ) {
                EmptyView()
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: isSearching ? "No matches" : "No genre matches",
                message: isSearching
                    ? "Nothing loaded matches “\(query)”. The full archive is on the show pages."
                    : "No loaded broadcasts match the selected genres."
            ) {
                HStack(spacing: 10) {
                    if !selectedGenres.isEmpty {
                        Button("Clear Filter") { selectedGenres.removeAll() }
                            .buttonStyle(OutlineButtonStyle())
                    }
                    Button("Browse Shows") { appState.select(.radio80000Shows) }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        } else {
            grid(visible)
        }
    }

    private func grid(_ episodes: [Radio80000Episode]) -> some View {
        ScrollView {
            LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                ForEach(episodes) { episode in
                    Radio80000EpisodeTile(
                        episode: episode,
                        isCurrent: Radio80000Playback.isCurrent(episode, in: player),
                        isPlaying: Radio80000Playback.isPlaying(episode, in: player),
                        open: {
                            browse.remember([episode])
                            appState.open(.radio80000Episode(id: episode.id))
                        },
                        play: {
                            Radio80000Playback.toggle(episode, within: episodes, using: player)
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
            Button("Load More") { Task { await browse.loadMore() } }
                .buttonStyle(OutlineButtonStyle())
                .frame(maxWidth: .infinity)
        } else if let error = browse.latestPhase.error {
            NoticeStrip(text: "Couldn't load more broadcasts. \(error)")
        } else {
            // The end of this listing is not the end of the archive, and a
            // listener who has scrolled this far is exactly the one who wants
            // to know that.
            VStack(spacing: 10) {
                Text("The rest of the archive lives on the show pages")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkFaint)
                Button("Browse Shows") { appState.select(.radio80000Shows) }
                    .buttonStyle(OutlineButtonStyle())
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var visible: [Radio80000Episode] {
        browse.latest.filter { episode in
            guard GenreTags.matches(episode.genres, selection: selectedGenres) else { return false }
            guard isSearching else { return true }
            var haystack = [episode.title, episode.showTitle ?? "", episode.summary ?? ""]
            haystack += episode.genres
            return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var availableGenres: [String] {
        GenreTags.available(in: browse.latest.flatMap(\.genres))
    }

    private var subtitle: String {
        guard !browse.latest.isEmpty else { return "Recent Radio 80000 broadcasts" }
        if isSearching {
            return "\(visible.count) matching “\(query)” in \(browse.latest.count) loaded"
        }
        return browse.canLoadMore
            ? "\(browse.latest.count) broadcasts so far"
            : "\(browse.latest.count) recent broadcasts"
    }
}
