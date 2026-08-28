//
//  ArtistsView.swift
//  Indigo
//

import SwiftUI
import SwiftData

struct ArtistsView: View {
    @Environment(AppState.self) private var appState

    @Query(sort: [SortDescriptor(\Track.artistKey), SortDescriptor(\Track.albumKey)])
    private var tracks: [Track]

    var body: some View {
        @Bindable var state = appState
        let visible = artists

        VStack(spacing: 0) {
            PageHeader(
                title: "Artists",
                subtitle: "\(visible.count.formatted(.number)) \(visible.count == 1 ? "artist" : "artists")"
            ) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Artist",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)

            if tracks.isEmpty {
                NoLibraryView(context: "Artists appear once Indigo has indexed a folder.")
            } else if visible.isEmpty {
                EmptyStateView(headline: "No matches",
                               message: "No artist matches “\(appState.searchText)”.") {
                    Button("Clear Search") { state.searchText = "" }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { artist in
                            ArtistRow(artist: artist) { appState.open(.artist(artist.id)) }
                            Rule()
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private var artists: [ArtistGroup] {
        let query = LibraryKey.normalize(appState.searchText)
        guard !query.isEmpty else { return LibraryGrouping.artists(from: tracks) }
        return LibraryGrouping.artists(from: tracks.filter { $0.searchIndex.contains(query) })
    }
}

private struct ArtistRow: View {
    let artist: ArtistGroup
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ArtworkView(localKey: artist.artworkKey, side: 34)
                    .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
                Text(artist.name)
                    .font(Typeface.body(13.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text("\(artist.albumCount) \(artist.albumCount == 1 ? "album" : "albums") · \(artist.trackCount) \(artist.trackCount == 1 ? "track" : "tracks")")
                    .microLabel(0.9)
                    .foregroundStyle(Palette.inkFaint)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isHovering ? Palette.ink : Palette.inkFaint.opacity(0.5))
            }
            .padding(.horizontal, Metrics.gutter)
            .frame(height: 52)
            .background(isHovering ? Palette.wash : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
