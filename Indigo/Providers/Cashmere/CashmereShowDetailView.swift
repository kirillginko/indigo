//
//  CashmereShowDetailView.swift
//  Indigo
//
//  One show and every episode of it Cashmere has kept.
//

import SwiftUI

struct CashmereShowDetailView: View {
    let slug: String

    @Environment(AppState.self) private var appState
    @Environment(CashmereBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let show = browse.show(slug: slug)
        let episodes = browse.episodes(ofShow: slug)

        VStack(spacing: 0) {
            PageHeader(
                title: show?.name ?? "Show",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(show, episodes: episodes)
            ) {
                if let first = episodes.first(where: \.isPlayable) {
                    playButton(first, queue: episodes)
                }
            }
            Rule(color: Palette.outline)

            if let show {
                content(show, episodes: episodes)
            } else if browse.isLoadingShow(slug) || browse.showsPhase.isLoading {
                LoadingPane(label: "Loading show")
            } else {
                EmptyStateView(
                    headline: "Show unavailable",
                    message: browse.showError(slug) ?? "Cashmere no longer publishes this show."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: slug) {
            async let directory: Void = browse.loadShowsIfNeeded()
            async let run: Void = browse.loadShowIfNeeded(slug: slug)
            _ = await (directory, run)
        }
    }

    private func subtitle(_ show: CashmereShow?, episodes: [CashmereEpisode]) -> String {
        guard let show else { return "Cashmere Radio" }
        let count = episodes.isEmpty ? show.episodeCount : episodes.count
        return "\(count) \(count == 1 ? "episode" : "episodes") · Cashmere Radio"
    }

    private func content(_ show: CashmereShow, episodes: [CashmereEpisode]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(remoteURL: episodes.first?.artworkURL, side: 300)
                        .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 16) {
                        MicroLabel(text: "Show")

                        Text(show.name)
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        // Cashmere writes no blurb for a show, only for its
                        // episodes — so the most recent one speaks for it.
                        if let summary = episodes.first?.summary {
                            Text(summary)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .lineLimit(6)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        let genres = GenreTags.available(in: episodes.flatMap(\.genres)).prefix(8)
                        if !genres.isEmpty {
                            WrapLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(Array(genres), id: \.self) { genre in
                                    TagChip(text: genre)
                                }
                            }
                        }

                        Spacer(minLength: 0)
                        if let first = episodes.first(where: \.isPlayable) {
                            playButton(first, queue: episodes, large: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)

                episodeList(episodes)
            }
        }
        .scrollIndicators(.visible)
    }

    @ViewBuilder
    private func episodeList(_ episodes: [CashmereEpisode]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    Text("Episodes").microLabel(1.8)
                    Spacer()
                    if !episodes.isEmpty {
                        Text("Newest first").microLabel(1.2).foregroundStyle(Palette.inkFaint)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                Rule()
            }

            if episodes.isEmpty {
                Text(browse.isLoadingShow(slug) ? "Loading episodes…" : "Nothing archived for this show.")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                    .background(Palette.wash)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(episodes) { episode in
                        CashmereEpisodeRow(
                            episode: episode,
                            isCurrent: CashmerePlayback.isCurrent(episode, in: player),
                            isPlaying: CashmerePlayback.isPlaying(episode, in: player),
                            open: {
                                browse.remember([episode])
                                appState.open(.cashmereEpisode(slug: episode.slug))
                            },
                            play: { CashmerePlayback.toggle(episode, within: episodes, using: player) }
                        )
                        Rule()
                    }
                }
            }
        }
    }

    private func playButton(_ episode: CashmereEpisode, queue: [CashmereEpisode], large: Bool = false) -> some View {
        let isPlaying = CashmerePlayback.isPlaying(episode, in: player)
        return Button {
            CashmerePlayback.toggle(episode, within: queue, using: player)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: large ? 11 : 9))
                Text(isPlaying ? "Pause" : "Play Latest")
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
