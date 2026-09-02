//
//  RovrArchiveView.swift
//  Indigo
//
//  ROVR's archive, newest first — ten thousand seven hundred broadcasts deep.
//
//  Everything here narrows at the station: the search reaches the whole
//  archive rather than the two dozen rows on screen, and so do the tags. That
//  is unusual among the stations Indigo reads, most of which publish no search
//  at all, and it is worth using rather than filtering locally out of habit.
//

import SwiftUI

struct RovrArchiveView: View {
    @Environment(AppState.self) private var appState
    @Environment(RovrBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    /// The bar works in the words the listener sees; the station filters on
    /// the ones behind them. See `RovrBrowseStore.tagTypes(forLabels:)`.
    @State private var selectedLabels: Set<String> = []

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(title: "Archive", subtitle: subtitle) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Search the whole archive",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: browse.tags.map(\.label), selection: tagSelection)
            if !browse.tags.isEmpty { Rule() }
            content
        }
        .task {
            async let tags: Void = browse.loadTagsIfNeeded()
            async let archive: Void = browse.loadArchiveIfNeeded()
            _ = await (tags, archive)
        }
        // Typing reaches the station rather than the loaded page, so it is
        // debounced — a request a keystroke over ten thousand rows is not a
        // search, it is a stampede.
        .task(id: appState.searchText) {
            let typed = appState.searchText
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, typed == appState.searchText else { return }
            browse.search(typed)
        }
    }

    private var tagSelection: Binding<Set<String>> {
        Binding(
            get: { selectedLabels },
            set: { labels in
                selectedLabels = labels
                browse.setTags(browse.tagTypes(forLabels: labels))
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        if browse.broadcasts.isEmpty, browse.archivePhase.isLoading {
            LoadingPane(label: "Loading the archive")
        } else if browse.broadcasts.isEmpty, let error = browse.archivePhase.error {
            EmptyStateView(headline: "ROVR unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadArchive() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if browse.broadcasts.isEmpty {
            EmptyStateView(headline: "No matches", message: emptyMessage) {
                HStack(spacing: 10) {
                    if !selectedLabels.isEmpty {
                        Button("Clear Filter") {
                            selectedLabels.removeAll()
                            browse.setTags([])
                        }
                        .buttonStyle(OutlineButtonStyle())
                    }
                    if !browse.searchQuery.isEmpty {
                        Button("Clear Search") { appState.searchText = "" }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
            }
        } else {
            grid(browse.broadcasts)
        }
    }

    private var emptyMessage: String {
        if !browse.searchQuery.isEmpty {
            return "ROVR has nothing matching “\(browse.searchQuery)”."
        }
        if !selectedLabels.isEmpty {
            return "Nothing archived under \(selectedLabels.sorted().joined(separator: ", "))."
        }
        return "ROVR isn't publishing an archive right now."
    }

    private func grid(_ broadcasts: [RovrBroadcast]) -> some View {
        ScrollView {
            LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                ForEach(broadcasts) { broadcast in
                    RovrBroadcastTile(
                        broadcast: broadcast,
                        isCurrent: RovrPlayback.isCurrent(broadcast, in: player),
                        isPlaying: RovrPlayback.isPlaying(broadcast, in: player),
                        open: {
                            browse.remember([broadcast])
                            appState.open(.rovrBroadcast(id: broadcast.documentID))
                        },
                        play: { RovrPlayback.toggle(broadcast, within: broadcasts, using: player) }
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

    private var subtitle: String {
        guard !browse.broadcasts.isEmpty else { return "The ROVR archive" }
        let shown = browse.broadcasts.count
        let total = browse.archiveTotal
        var parts: [String] = []
        if !browse.searchQuery.isEmpty {
            parts.append("\(total) matching “\(browse.searchQuery)”")
        } else {
            parts.append(total > shown ? "\(shown) of \(total) broadcasts" : "\(shown) broadcasts")
        }
        if !selectedLabels.isEmpty {
            parts.append(selectedLabels.sorted().joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}
