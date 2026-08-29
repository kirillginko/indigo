//
//  CashmereEpisodeDetailView.swift
//  Indigo
//
//  The expanded page for one episode: what it was, what show it belonged to,
//  and everything Cashmere wrote about it.
//

import SwiftUI

struct CashmereEpisodeDetailView: View {
    let slug: String

    @Environment(AppState.self) private var appState
    @Environment(CashmereBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let episode = browse.episode(slug: slug)

        VStack(spacing: 0) {
            PageHeader(
                title: episode?.title ?? "Cashmere Radio",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: [episode?.airedLabel, episode?.showName ?? "Cashmere Radio"]
                    .compactMap { $0 }.joined(separator: " · ")
            ) {
                if let episode {
                    HStack(spacing: 10) {
                        if episode.isPlayable { playButton(episode) }
                        CashmereCrateButton(episode: episode)
                    }
                }
            }
            Rule(color: Palette.outline)

            if let episode {
                content(episode)
            } else if browse.isLoadingDetail(slug) {
                LoadingPane(label: "Loading episode")
            } else {
                EmptyStateView(
                    headline: "Episode unavailable",
                    message: browse.detailError(slug) ?? "Cashmere no longer publishes this episode."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: slug) { await browse.loadDetailIfNeeded(slug: slug) }
    }

    private func content(_ episode: CashmereEpisode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(episode)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                related(episode)
            }
        }
        .scrollIndicators(.visible)
    }

    private func hero(_ episode: CashmereEpisode) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(remoteURL: episode.artworkURL, side: 300)
                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 16) {
                if let show = episode.showName, let showSlug = episode.showSlug {
                    Button { appState.open(.cashmereShow(slug: showSlug)) } label: {
                        Text(show).microLabel(1.8).foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    MicroLabel(text: "Cashmere archive")
                }

                Text(episode.title)
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                Text([episode.airedLabel, "Berlin"].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(Typeface.mono(11))
                    .foregroundStyle(Palette.inkMuted)

                if !episode.genres.isEmpty || !episode.moods.isEmpty {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(episode.genres, id: \.self) { TagChip(text: $0) }
                        ForEach(episode.moods, id: \.self) { TagChip(text: $0) }
                    }
                }

                if let summary = episode.summary {
                    Text(summary)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                } else if browse.isLoadingDetail(slug) {
                    Text("Loading the description…")
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                }

                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if episode.isPlayable {
                        playButton(episode, large: true)
                    } else {
                        Text("No recording published")
                            .microLabel(1.2, size: 9.5)
                            .foregroundStyle(Palette.inkFaint)
                    }
                    CashmereCrateButton(episode: episode)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func related(_ episode: CashmereEpisode) -> some View {
        let siblings = (episode.showSlug.map { browse.episodes(ofShow: $0) } ?? [])
            .filter { $0.slug != episode.slug }
        if !siblings.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    Rule(color: Palette.outline)
                    HStack {
                        Text(episode.showName.map { "More from \($0)" } ?? "More from the archive")
                            .microLabel(1.8)
                        Spacer()
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 14)
                    Rule()
                }
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(siblings.prefix(12)) { other in
                        CashmereEpisodeTile(
                            episode: other,
                            isCurrent: CashmerePlayback.isCurrent(other, in: player),
                            isPlaying: CashmerePlayback.isPlaying(other, in: player),
                            open: {
                                browse.remember([other])
                                appState.open(.cashmereEpisode(slug: other.slug))
                            },
                            play: { CashmerePlayback.toggle(other, within: Array(siblings), using: player) }
                        )
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
        }
    }

    private func playButton(_ episode: CashmereEpisode, large: Bool = false) -> some View {
        let isPlaying = CashmerePlayback.isPlaying(episode, in: player)
        return Button {
            CashmerePlayback.toggle(episode, within: [episode], using: player)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: large ? 11 : 9))
                Text(isPlaying ? "Pause" : "Play Episode")
                    .microLabel(1.4, size: large ? 11 : 10)
            }
            .foregroundStyle(Palette.inverseInk)
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 13 : 9)
            .background(Palette.inverse)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
