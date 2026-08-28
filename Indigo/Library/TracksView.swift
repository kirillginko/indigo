//
//  TracksView.swift
//  Indigo
//

import SwiftUI
import SwiftData

struct TracksView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(LibraryStore.self) private var library

    @Query(sort: [SortDescriptor(\Track.sortTitle), SortDescriptor(\Track.artistKey)])
    private var tracks: [Track]
    @State private var selectedGenres: Set<String> = []

    var body: some View {
        @Bindable var state = appState
        let visible = filtered

        VStack(spacing: 0) {
            PageHeader(
                title: "Tracks",
                subtitle: subtitle(for: visible)
            ) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Title, artist, album",
                    focusSignal: appState.searchFocusRequests
                )
            }

            Rule(color: Palette.outline)
            GenreFilterBar(genres: availableGenres, selection: $selectedGenres)
            if !availableGenres.isEmpty { Rule() }

            if tracks.isEmpty {
                NoLibraryView(context: library.hasLibrary
                              ? "Nothing indexed in \(library.rootDisplayName) yet. Indigo reads MP3, AAC, ALAC, FLAC and WAV."
                              : "Point Indigo at a folder and it will index everything inside.")
            } else if visible.isEmpty {
                EmptyStateView(headline: "No matches",
                               message: "Nothing in the library matches “\(appState.searchText)”.") {
                    Button("Clear Search") { state.searchText = "" }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                ColumnHeader(showGenre: true)
                    .padding(.top, 11)
                Rule()
                list(visible)
            }
        }
    }

    private func list(_ visible: [Track]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.persistentModelID) { offset, track in
                    TrackRow(
                        track: track,
                        index: offset + 1,
                        showGenre: true,
                        isCurrent: player.isCurrent(track.path),
                        isPlaying: player.isPlaying
                    ) {
                        play(visible, from: offset)
                    }
                    Rule()
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.visible)
    }

    private func subtitle(for visible: [Track]) -> String {
        let total = visible.count
        let seconds = visible.reduce(0) { $0 + $1.duration }
        let hours = Int(seconds / 3600)
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        let length = hours > 0 ? "\(hours) hr \(minutes) min" : "\(minutes) min"
        return "\(total.formatted(.number)) \(total == 1 ? "track" : "tracks") · \(length)"
    }

    private var filtered: [Track] {
        let query = LibraryKey.normalize(appState.searchText)
        return tracks.filter { track in
            (query.isEmpty || track.searchIndex.contains(query))
                && GenreTags.matches(track.genre.isEmpty ? [] : [track.genre], selection: selectedGenres)
        }
    }

    private var availableGenres: [String] {
        GenreTags.available(in: tracks.map(\.genre))
    }

    private func play(_ visible: [Track], from offset: Int) {
        if player.isCurrent(visible[offset].path) {
            player.toggle()
        } else {
            player.play(visible.mediaItems(), startingAt: offset)
        }
    }
}
