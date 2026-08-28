//
//  NTSShowDetailView.swift
//  Indigo
//
//  One residency and its back catalogue.
//

import SwiftUI

struct NTSShowDetailView: View {
    let alias: String

    @Environment(AppState.self) private var appState
    @Environment(NTSBrowseStore.self) private var browse

    var body: some View {
        let episodes = browse.episodes(of: alias)
        let show = browse.knownShow(alias)

        VStack(spacing: 0) {
            PageHeader(
                title: show?.name ?? displayAlias,
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(show: show, total: episodes.total)
            )
            Rule(color: Palette.outline)

            if episodes.items.isEmpty, episodes.isLoading {
                LoadingPane(label: "Loading episodes")
            } else if episodes.items.isEmpty, let error = episodes.error {
                EmptyStateView(headline: "Couldn't load this show", message: error) {
                    Button("Try Again") { Task { await browse.loadMoreEpisodes(of: alias) } }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else if episodes.items.isEmpty {
                EmptyStateView(headline: "No episodes",
                               message: "NTS isn't listing any episodes for this show.") {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let show {
                            header(show)
                        }

                        MicroLabel(text: "Episodes")
                            .padding(.horizontal, Metrics.gutter)
                            .padding(.bottom, 10)
                        Rule()

                        ForEach(episodes.items) { episode in
                            EpisodeRow(episode: episode) {
                                appState.open(.ntsEpisode(show: episode.showAlias,
                                                          episode: episode.episodeAlias))
                            }
                            Rule()
                        }

                        LoadMoreFooter(
                            isLoading: episodes.isLoading,
                            hasMore: episodes.hasMore,
                            error: episodes.error,
                            loadedCount: episodes.items.count,
                            total: episodes.total
                        ) {
                            await browse.loadMoreEpisodes(of: alias)
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
        .task(id: alias) { await browse.loadEpisodesIfNeeded(of: alias) }
    }

    private func header(_ show: NTSShowSummary) -> some View {
        HStack(alignment: .top, spacing: 22) {
            ArtworkView(remoteURL: show.artworkURL, side: 150)
                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 12) {
                if !show.genres.isEmpty {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(show.genres.prefix(6), id: \.self) { TagChip(text: $0) }
                    }
                }
                if let summary = show.summary, !summary.isEmpty {
                    Text(summary)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 22)
        .padding(.bottom, 30)
    }

    private var displayAlias: String {
        alias.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private func subtitle(show: NTSShowSummary?, total: Int?) -> String {
        var parts: [String] = []
        if let location = show?.location { parts.append(location) }
        if let total, total > 0 { parts.append("\(total.formatted(.number)) episodes") }
        return parts.isEmpty ? "NTS" : parts.joined(separator: " · ")
    }
}

private struct EpisodeRow: View {
    let episode: NTSEpisodeSummary
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ArtworkView(remoteURL: episode.artworkURL, side: 40)
                    .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.name)
                        .font(Typeface.body(12.5, weight: .medium))
                        .lineLimit(1)
                    if !episode.genres.isEmpty {
                        Text(episode.genres.prefix(3).joined(separator: " · "))
                            .microLabel(0.8)
                            .foregroundStyle(Palette.inkFaint)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                if let broadcast = episode.broadcastLabel {
                    Text(broadcast)
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isHovering ? Palette.ink : Palette.inkFaint.opacity(0.5))
            }
            .padding(.horizontal, Metrics.gutter)
            .frame(height: 58)
            .background(isHovering ? Palette.wash : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
