//
//  LYLShowDetailView.swift
//  Indigo
//
//  One show: how often it returns, who makes it, and every episode of it LYL
//  has archived.
//

import SwiftUI

struct LYLShowDetailView: View {
    let slug: String

    @Environment(AppState.self) private var appState
    @Environment(LYLBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let show = browse.show(slug: slug)
        let episodes = browse.episodes(ofShow: slug)

        VStack(spacing: 0) {
            PageHeader(
                title: show?.title ?? "Show",
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
                    message: browse.showError(slug) ?? "LYL no longer publishes this show."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: slug) {
            async let directory: Void = browse.loadShowsIfNeeded()
            async let detail: Void = browse.loadShowIfNeeded(slug: slug)
            _ = await (directory, detail)
        }
    }

    private func subtitle(_ show: LYLShow?, episodes: [LYLEpisode]) -> String {
        guard let show else { return "LYL Radio" }
        let count = episodes.isEmpty ? nil : "\(episodes.count) \(episodes.count == 1 ? "episode" : "episodes")"
        return [count, show.recursionLabel, "LYL Radio"].compactMap { $0 }.joined(separator: " · ")
    }

    private func content(_ show: LYLShow, episodes: [LYLEpisode]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(
                        remoteURL: show.imageURL,
                        side: 300,
                        markURL: LYLProvider.logoURL,
                        mark: "LYL Radio"
                    )
                    .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 16) {
                        MicroLabel(text: show.hasEnded ? "Ended" : (show.recursionLabel ?? "Show"))

                        Text(show.title)
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        if let artists = show.artists {
                            Text(artists)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !show.styles.isEmpty {
                            WrapLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(show.styles, id: \.self) { TagChip(text: $0) }
                            }
                        }

                        if let summary = show.summary {
                            Text(summary)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        MediaLinkChips(links: show.links)

                        if let next = show.nextBroadcast, next > .now {
                            VStack(alignment: .leading, spacing: 4) {
                                MicroLabel(text: "Next broadcast")
                                Text(next.formatted(date: .abbreviated, time: .shortened))
                                    .font(Typeface.mono(11))
                                    .foregroundStyle(Palette.inkMuted)
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
    private func episodeList(_ episodes: [LYLEpisode]) -> some View {
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
                        LYLEpisodeRow(
                            episode: episode,
                            isCurrent: LYLPlayback.isCurrent(episode, in: player),
                            isPlaying: LYLPlayback.isPlaying(episode, in: player),
                            open: {
                                browse.remember([episode])
                                appState.open(.lylEpisode(slug: episode.slug))
                            },
                            play: { LYLPlayback.toggle(episode, within: episodes, using: player) }
                        )
                        Rule()
                    }
                }
            }
        }
    }

    private func playButton(_ episode: LYLEpisode, queue: [LYLEpisode], large: Bool = false) -> some View {
        let isPlaying = LYLPlayback.isPlaying(episode, in: player)
        return Button {
            LYLPlayback.toggle(episode, within: queue, using: player)
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
