//
//  KioskMoodsView.swift
//  Indigo
//
//  Kiosk's Moods — hand-curated playlists cut across the archive by feel
//  rather than genre. Each one opens as a running order you can play through.
//

import SwiftUI

struct KioskMoodsView: View {
    @Environment(AppState.self) private var appState
    @Environment(KioskBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player
    @State private var selectedGenres: Set<String> = []

    var body: some View {
        @Bindable var state = appState
        let visible = filteredMoods
        VStack(spacing: 0) {
            PageHeader(title: "Moods", subtitle: subtitle) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Moods, shows, genres",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: availableGenres, selection: $selectedGenres)
            if !availableGenres.isEmpty { Rule() }

            if browse.moods.isEmpty, browse.moodsPhase.isLoading {
                LoadingPane(label: "Loading moods")
            } else if browse.moods.isEmpty, let error = browse.moodsPhase.error {
                EmptyStateView(headline: "Kiosk unreachable", message: error) {
                    Button("Try Again") { Task { await browse.loadMoods() } }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else if visible.isEmpty {
                EmptyStateView(headline: "No matches", message: "No Kiosk moods match the current search and genres.") {
                    Button("Clear Filters") {
                        appState.searchText = ""
                        selectedGenres.removeAll()
                    }.buttonStyle(OutlineButtonStyle())
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                        ForEach(visible) { mood in
                            MoodTile(
                                mood: mood,
                                isPlaying: isPlaying(mood),
                                open: { appState.open(.kioskMood(id: mood.id)) },
                                play: { play(mood) }
                            )
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                }
                .scrollIndicators(.visible)
            }
        }
        .task { await browse.loadMoodsIfNeeded() }
    }

    private var availableGenres: [String] {
        GenreTags.available(in: browse.moods.flatMap { $0.episodes.flatMap(\.genres) })
    }

    private var filteredMoods: [KioskMood] {
        let query = LibraryKey.normalize(appState.searchText)
        return browse.moods.filter { mood in
            let genres = mood.episodes.flatMap(\.genres)
            let text = [mood.title] + mood.episodes.map(\.title) + genres
            return GenreTags.matches(genres, selection: selectedGenres)
                && (query.isEmpty || text.map(LibraryKey.normalize).contains { $0.contains(query) })
        }
    }

    private var subtitle: String {
        browse.moods.isEmpty
            ? "Curated Kiosk playlists"
            : "\(browse.moods.count) curated playlists"
    }

    /// A mood is "playing" while the loaded show is one of its own.
    private func isPlaying(_ mood: KioskMood) -> Bool {
        guard player.isPlaying else { return false }
        return mood.episodes.contains { KioskPlayback.isCurrent($0, in: player) }
    }

    private func play(_ mood: KioskMood) {
        if isPlaying(mood) {
            player.toggle()
            return
        }
        guard let first = mood.playableEpisodes.first else { return }
        KioskPlayback.toggle(first, within: mood.episodes, using: player)
    }
}

private struct MoodTile: View {
    let mood: KioskMood
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: open) {
                    ArtworkView(remoteURL: mood.artworkURL)
                        .overlay(Rectangle().strokeBorder(
                            isPlaying ? Palette.accent : Palette.rule,
                            lineWidth: isPlaying ? 1.5 : Metrics.hairline
                        ))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(mood.title)")

                // Keep playback as a separate control so it cannot swallow
                // the artwork's navigation click.
                Group {
                    if isHovering || isPlaying {
                        Button(action: play) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.inverseInk)
                                .frame(width: 28, height: 28)
                                .background(Palette.inverse)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPlaying ? "Pause \(mood.title)" : "Play \(mood.title)")
                        .padding(8)
                    }
                }
            }

            Button(action: open) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mood.title)
                        .font(Typeface.body(12, weight: .semibold))
                        .lineLimit(1)
                    Text("\(mood.episodes.count) shows")
                        .microLabel(0.8)
                        .foregroundStyle(Palette.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(mood.title)")
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mood.title)
    }
}
