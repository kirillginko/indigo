//
//  AlharaArchiveView.swift
//  Indigo
//
//  alHara's recorded shows. The station keeps them on Mixcloud rather than on
//  its own site, and stopped adding to them after its first year — so the page
//  says what it holds and when, instead of implying an archive that is still
//  filling up.
//

import SwiftUI

struct AlharaArchiveView: View {
    @Environment(AppState.self) private var appState
    @Environment(AlharaBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

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
                    placeholder: "Search loaded shows",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            provenance
            content
        }
        .task { await browse.loadIfNeeded() }
    }

    /// The archive is somebody else's site and stops in 2020. Both facts
    /// belong on the page rather than in a commit message.
    private var provenance: some View {
        HStack(spacing: 6) {
            Text("Kept on Mixcloud")
                .microLabel(1.4)
                .foregroundStyle(Palette.inkFaint)
            if let range = browse.yearRange {
                Text(range.first == range.last ? "· \(range.first)" : "· \(range.first)–\(range.last)")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 12)
        .background(Palette.paperChrome)
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.shows.isEmpty, browse.phase.isLoading {
            LoadingPane(label: "Loading the archive")
        } else if browse.shows.isEmpty, let error = browse.phase.error {
            EmptyStateView(headline: "Archive unreachable", message: error) {
                Button("Try Again") { Task { await browse.load() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if browse.shows.isEmpty {
            EmptyStateView(
                headline: "Nothing archived",
                message: "Radio alHara isn't publishing any recorded shows right now."
            ) {
                EmptyView()
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

    private func grid(_ shows: [AlharaShow]) -> some View {
        ScrollView {
            LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                ForEach(shows) { show in
                    AlharaShowTile(
                        show: show,
                        isCurrent: AlharaPlayback.isCurrent(show, in: player),
                        isPlaying: AlharaPlayback.isPlaying(show, in: player),
                        open: {
                            browse.remember([show])
                            appState.open(.alharaShow(slug: show.slug))
                        },
                        play: { AlharaPlayback.toggle(show, within: shows, using: player) }
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
            Text("Loading more")
                .microLabel(1.4)
                .foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity)
        } else if browse.canLoadMore {
            Button("Load More") { Task { await browse.loadMore() } }
                .buttonStyle(OutlineButtonStyle())
                .frame(maxWidth: .infinity)
        } else if let error = browse.phase.error {
            NoticeStrip(text: "Couldn't load more of the archive. \(error)")
        } else {
            Text("End of the archive")
                .microLabel(1.4)
                .foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity)
        }
    }

    private var visible: [AlharaShow] {
        guard isSearching else { return browse.shows }
        return browse.shows.filter { show in
            ([show.title] + show.genres).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var subtitle: String {
        if isSearching {
            let count = visible.count
            return "\(count) \(count == 1 ? "show" : "shows") matching “\(query)” in \(browse.shows.count) loaded"
        }
        guard !browse.shows.isEmpty else { return "Radio alHara's recorded shows" }
        return browse.canLoadMore
            ? "\(browse.shows.count) shows so far"
            : "\(browse.shows.count) shows"
    }
}
