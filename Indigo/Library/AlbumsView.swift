//
//  AlbumsView.swift
//  Indigo
//

import SwiftUI
import SwiftData

struct AlbumsView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryStore.self) private var library

    @Query(sort: [SortDescriptor(\Track.albumKey), SortDescriptor(\Track.discNumber),
                  SortDescriptor(\Track.trackNumber)])
    private var tracks: [Track]

    private let columns = BrowseGrid.columns
    @State private var selectedGenres: Set<String> = []

    var body: some View {
        @Bindable var state = appState
        let visible = albums

        VStack(spacing: 0) {
            PageHeader(
                title: "Albums",
                subtitle: "\(visible.count.formatted(.number)) \(visible.count == 1 ? "album" : "albums")"
            ) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Album or artist",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: availableGenres, selection: $selectedGenres)
            if !availableGenres.isEmpty { Rule() }

            if tracks.isEmpty {
                NoLibraryView(context: "Albums appear once Indigo has indexed a folder.")
            } else if visible.isEmpty {
                EmptyStateView(headline: "No matches",
                               message: "No album matches “\(appState.searchText)”.") {
                    Button("Clear Search") { state.searchText = "" }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(visible) { album in
                            AlbumTile(album: album) {
                                appState.open(.album(album.id))
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    /// Filter the cheap way (one precomputed string per row), then group only
    /// what survives — grouping the whole library on every keystroke is what
    /// makes search feel heavy.
    private var albums: [AlbumGroup] {
        let query = LibraryKey.normalize(appState.searchText)
        let matching = tracks.filter { track in
            (query.isEmpty || track.searchIndex.contains(query))
                && GenreTags.matches(track.genre.isEmpty ? [] : [track.genre], selection: selectedGenres)
        }
        return LibraryGrouping.albums(from: matching)
    }

    private var availableGenres: [String] {
        GenreTags.available(in: tracks.map(\.genre))
    }
}
