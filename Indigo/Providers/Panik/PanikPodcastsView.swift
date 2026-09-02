//
//  PanikPodcastsView.swift
//  Indigo
//
//  Radio Panik's recent broadcasts, newest first.
//
//  Called Podcasts because that is what the station calls them, and because
//  the feed behind it is a window on the archive rather than the whole of it —
//  fifty across every show. The depth is in each show's own feed, which is
//  what the show pages read.
//
//  Search here narrows what has been loaded. That is not a shortcut: Panik's
//  robots.txt reserves its search path, so Indigo does not query the station.
//

import SwiftUI

struct PanikPodcastsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PanikBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    private var query: String {
        appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { query.count >= 2 }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(title: "Podcasts", subtitle: subtitle) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Search loaded broadcasts",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            content
        }
        .task { await browse.loadPodcastsIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.podcasts.isEmpty, browse.podcastsPhase.isLoading {
            LoadingPane(label: "Loading broadcasts")
        } else if browse.podcasts.isEmpty, let error = browse.podcastsPhase.error {
            EmptyStateView(headline: "Radio Panik unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadPodcasts() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if browse.podcasts.isEmpty {
            EmptyStateView(
                headline: "Nothing published",
                message: "Radio Panik isn't publishing recent broadcasts right now."
            ) {
                EmptyView()
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: "No matches",
                message: "Nothing loaded matches “\(query)”. Each show keeps its own archive."
            ) {
                Button("Browse Shows") { appState.select(.panikShows) }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            grid(visible)
        }
    }

    private func grid(_ episodes: [PanikEpisode]) -> some View {
        ScrollView {
            LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                ForEach(episodes) { episode in
                    PanikEpisodeTile(
                        episode: episode,
                        isCurrent: PanikPlayback.isCurrent(episode, in: player),
                        isPlaying: PanikPlayback.isPlaying(episode, in: player),
                        open: {
                            browse.remember([episode])
                            appState.open(.panikEpisode(id: episode.id))
                        },
                        play: { PanikPlayback.toggle(episode, within: episodes, using: player) }
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

    /// The end of this feed is not the end of the archive, and a listener who
    /// has scrolled this far is the one who wants to know that.
    private var footer: some View {
        VStack(spacing: 10) {
            Text("Each show keeps its own archive")
                .microLabel(1.4)
                .foregroundStyle(Palette.inkFaint)
            Button("Browse Shows") { appState.select(.panikShows) }
                .buttonStyle(OutlineButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }

    private var visible: [PanikEpisode] {
        guard isSearching else { return browse.podcasts }
        return browse.podcasts.filter { episode in
            [episode.title, episode.showTitle ?? "", episode.summary ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var subtitle: String {
        guard !browse.podcasts.isEmpty else { return "Recent Radio Panik broadcasts" }
        if isSearching {
            return "\(visible.count) matching “\(query)” in \(browse.podcasts.count) loaded"
        }
        return "\(browse.podcasts.count) recent broadcasts"
    }
}
