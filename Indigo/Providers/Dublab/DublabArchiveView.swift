//
//  DublabArchiveView.swift
//  Indigo
//
//  Twenty-seven thousand broadcasts, back to 1999. Searching and narrowing
//  re-ask dublab rather than filtering the page, so the whole archive is
//  reachable and the count on screen is the real one.
//

import SwiftUI

struct DublabArchiveView: View {
    @Environment(AppState.self) private var appState
    @Environment(DublabBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(title: "Archive", subtitle: subtitle) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Search the dublab archive",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            DublabFilterBar(
                genres: browse.genres,
                years: browse.years,
                selectedGenre: browse.query.genre,
                selectedYear: browse.query.year,
                onGenre: { browse.setGenre($0) },
                onYear: { browse.setYear($0) },
                onClear: { browse.clearFilters() }
            )
            if !browse.genres.isEmpty { Rule() }
            content
        }
        .task {
            async let archive: Void = browse.loadArchiveIfNeeded()
            async let filters: Void = browse.loadFiltersIfNeeded()
            _ = await (archive, filters)
        }
        .onChange(of: appState.searchText) { _, text in
            browse.updateSearch(text)
        }
        .onDisappear { browse.updateSearch("") }
    }

    @ViewBuilder
    private var content: some View {
        if browse.broadcasts.isEmpty, browse.archivePhase.isLoading {
            LoadingPane(label: browse.query.isSearching ? "Searching dublab" : "Loading the archive")
        } else if browse.broadcasts.isEmpty, let error = browse.archivePhase.error {
            EmptyStateView(headline: "dublab unreachable", message: error) {
                Button("Try Again") { Task { await browse.reloadArchive() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if browse.broadcasts.isEmpty {
            EmptyStateView(headline: emptyHeadline, message: emptyMessage) {
                if browse.query.isFiltered {
                    Button("Clear") {
                        appState.searchText = ""
                        browse.clearFilters()
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                ForEach(browse.broadcasts) { broadcast in
                    DublabBroadcastTile(
                        broadcast: broadcast,
                        isCurrent: DublabPlayback.isCurrent(broadcast, in: player),
                        isPlaying: DublabPlayback.isPlaying(broadcast, in: player),
                        open: { open(broadcast) },
                        play: {
                            DublabPlayback.toggle(broadcast, within: browse.broadcasts, using: player)
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
            Text("Loading more")
                .microLabel(1.4)
                .foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity)
        } else if browse.canLoadMore {
            Button("Load More") { Task { await browse.loadMore() } }
                .buttonStyle(OutlineButtonStyle())
                .frame(maxWidth: .infinity)
        } else if let error = browse.archivePhase.error {
            NoticeStrip(text: "Couldn't load more of the archive. \(error)")
        } else {
            Text(browse.query.isFiltered ? "End of the results" : "End of the archive")
                .microLabel(1.4)
                .foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity)
        }
    }

    private func open(_ broadcast: DublabBroadcast) {
        browse.remember([broadcast])
        appState.open(.dublabBroadcast(slug: broadcast.slug))
    }

    // MARK: - Copy

    private var subtitle: String {
        guard !browse.broadcasts.isEmpty else { return "The dublab archive" }
        let total = max(browse.archiveTotal, browse.broadcasts.count)
        let shown = "\(browse.broadcasts.count.formatted(.number)) of \(total.formatted(.number))"
        if browse.query.isSearching {
            return "\(shown) matching “\(browse.query.search)”"
        }
        if let genre = browse.genres.first(where: { $0.slug == browse.query.genre })?.name {
            return "\(shown) in \(genre)\(browse.query.year.map { ", \($0)" } ?? "")"
        }
        if let year = browse.query.year {
            return "\(shown) from \(year)"
        }
        return "\(shown) broadcasts"
    }

    private var emptyHeadline: String {
        browse.query.isSearching ? "No matches" : "Nothing here"
    }

    private var emptyMessage: String {
        if browse.query.isSearching {
            return "dublab has nothing in its archive matching “\(browse.query.search)”."
        }
        if browse.query.isFiltered {
            return "dublab has nothing archived under that."
        }
        return "dublab isn't publishing an archive right now."
    }
}
