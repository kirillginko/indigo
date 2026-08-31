//
//  NTSBrowseComponents.swift
//  Indigo
//
//  Tiles and list furniture shared by the NTS browse pages.
//

import SwiftUI

// MARK: - Tiles

struct NTSEpisodeTile: View {
    let episode: NTSEpisodeSummary
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ArtworkView(remoteURL: episode.artworkURL)
                    .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
                    .overlay(alignment: .topLeading) {
                        // NTS only sends a tracklist with the episode itself,
                        // so the grid has the genres to go on.
                        if isHovering,
                           let badge = BroadcastBadge.text(
                               tracks: 0,
                               genres: episode.genres + episode.moods
                           ) {
                            Text(badge)
                                .microLabel(1.2, size: 9)
                                .foregroundStyle(Palette.inverseInk)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Palette.inverse)
                                .padding(8)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.name)
                        .font(Typeface.body(12, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .microLabel(0.8)
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var subtitle: String {
        [episode.broadcastLabel, episode.location]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct NTSShowTile: View {
    let show: NTSShowSummary
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ArtworkView(remoteURL: show.artworkURL)
                    .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
                    .overlay {
                        if isHovering {
                            Rectangle().fill(Palette.inverse.opacity(0.12))
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(show.name)
                        .font(Typeface.body(12, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(show.genres.prefix(2).joined(separator: " · ").isEmpty
                         ? (show.location ?? "NTS")
                         : show.genres.prefix(2).joined(separator: " · "))
                        .microLabel(0.8)
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Paging footer

/// Loads the next page when it scrolls into view, and surfaces failures with a
/// retry rather than silently stopping.
struct LoadMoreFooter: View {
    let isLoading: Bool
    let hasMore: Bool
    let error: String?
    let loadedCount: Int
    let total: Int?
    let loadMore: () async -> Void

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 10) {
                    Text(error)
                        .font(Typeface.mono(10.5))
                        .foregroundStyle(Palette.inkMuted)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await loadMore() } }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else if isLoading {
                Text("Loading")
                    .microLabel(1.6)
                    .foregroundStyle(Palette.inkFaint)
            } else if hasMore {
                // Deliberately manual. The footer sits outside the lazy grid so
                // it is always "on screen"; auto-loading here would walk the
                // whole 89k-episode archive on its own.
                VStack(spacing: 8) {
                    Button("Load More") { Task { await loadMore() } }
                        .buttonStyle(OutlineButtonStyle())
                    if let total {
                        Text("\(loadedCount.formatted(.number)) of \(total.formatted(.number))")
                            .microLabel(1.2)
                            .foregroundStyle(Palette.inkFaint)
                    }
                }
            } else if let total, loadedCount > 0 {
                Text("\(total.formatted(.number)) total")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkFaint)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

// MARK: - Tabs

struct SegmentedTabs<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .microLabel(1.3, size: 10)
                        .foregroundStyle(isSelected ? Palette.inverseInk : Palette.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(isSelected ? Palette.inverse : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
    }
}

// MARK: - Grid metrics

enum BrowseGrid {
    /// No `maximum`: an adaptive column capped at a maximum leaves the leftover
    /// width unused, so the last column floats short of the right edge. Without
    /// it the columns divide the full container width exactly.
    static let columns = [GridItem(.adaptive(minimum: 168), spacing: 20, alignment: .top)]
}
