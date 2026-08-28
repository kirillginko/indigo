//
//  NoodsFilterView.swift
//  Indigo
//
//  Noods tags every show by genre and exposes the whole archive behind those
//  tags — thousands of shows, reachable no other way. Picking genres is how
//  you get at it.
//

import SwiftUI

struct NoodsFilterView: View {
    @Environment(NoodsBrowseStore.self) private var browse

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Filter", subtitle: subtitle) {
                if !browse.selectedGenres.isEmpty {
                    Button("Clear") { browse.clearGenres() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
            Rule(color: Palette.outline)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    genrePicker
                    if !browse.selectedGenres.isEmpty {
                        Rule(color: Palette.outline)
                        results
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollIndicators(.visible)
        }
        .task { await browse.loadGenresIfNeeded() }
    }

    private var subtitle: String {
        if browse.selectedGenres.isEmpty { return "Pick a genre to dig through the archive" }
        guard let total = browse.filtered.total, total > 0 else {
            return browse.selectedGenres.sorted().joined(separator: " · ")
        }
        return "\(total.formatted(.number)) shows · \(browse.selectedGenres.sorted().joined(separator: " · "))"
    }

    // MARK: Genres

    @ViewBuilder
    private var genrePicker: some View {
        if browse.genreGroups.isEmpty, browse.genresPhase.isLoading {
            LoadingPane(label: "Loading genres")
                .frame(height: 160)
        } else if browse.genreGroups.isEmpty, let error = browse.genresPhase.error {
            EmptyStateView(headline: "Couldn't load genres", message: error) {
                Button("Try Again") { Task { await browse.loadGenresIfNeeded() } }
                    .buttonStyle(OutlineButtonStyle())
            }
            .frame(height: 200)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(browse.genreGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.name)
                            .microLabel(1.6)
                            .foregroundStyle(Palette.inkFaint)
                        WrapLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(group.genres, id: \.self) { genre in
                                GenreChip(
                                    text: genre,
                                    isSelected: browse.isSelected(genre)
                                ) {
                                    browse.toggle(genre: genre)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 22)
        }
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        let state = browse.filtered

        if state.items.isEmpty, state.isLoading {
            LoadingPane(label: "Filtering")
                .frame(height: 200)
        } else if state.items.isEmpty, let error = state.error {
            EmptyStateView(headline: "Filter failed", message: error) {
                Button("Try Again") { Task { await browse.loadMoreFiltered() } }
                    .buttonStyle(OutlineButtonStyle())
            }
            .frame(height: 220)
        } else if state.items.isEmpty, state.hasLoadedOnce {
            EmptyStateView(
                headline: "No shows",
                message: "Nothing in the Noods archive is tagged with that combination."
            ) { EmptyView() }
            .frame(height: 220)
        } else {
            NoodsShowGrid(shows: state.items)
                .padding(.top, 22)

            LoadMoreFooter(
                isLoading: state.isLoading,
                hasMore: state.hasMore,
                error: state.error,
                loadedCount: state.items.count,
                total: state.total
            ) {
                await browse.loadMoreFiltered()
            }
        }
    }
}

/// A genre toggle. Selected inverts, like the sidebar's current route.
private struct GenreChip: View {
    let text: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .microLabel(1.1, size: 9)
                .foregroundStyle(isSelected ? Palette.inverseInk : Palette.inkMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isSelected ? Palette.inverse : (isHovering ? Palette.wash : Color.clear))
                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
