//
//  IdaShowDetailView.swift
//  Indigo
//
//  One show: who makes it, which studio it comes out of, and every episode of
//  it IDA has archived.
//

import SwiftUI

struct IdaShowDetailView: View {
    let slug: String

    @Environment(AppState.self) private var appState
    @Environment(IdaBrowseStore.self) private var browse
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
                    message: browse.showError(slug) ?? "IDA no longer publishes this show."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: slug) { await browse.loadShowIfNeeded(slug: slug) }
    }

    private func subtitle(_ show: IdaShow?, episodes: [IdaEpisode]) -> String {
        guard let show else { return "IDA Radio" }
        let count = episodes.isEmpty
            ? nil
            : "\(episodes.count) \(episodes.count == 1 ? "episode" : "episodes")"
        return [count, show.channel?.city, "IDA Radio"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func content(_ show: IdaShow, episodes: [IdaEpisode]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(
                        remoteURL: show.imageURL,
                        side: 300,
                        markURL: IdaProvider.logoURL,
                        mark: "IDA Radio"
                    )
                    .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 16) {
                        MicroLabel(text: show.isArchived ? "Ended" : "Show")

                        Text(show.title)
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        if let artist = show.artist {
                            Text(artist)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let city = show.channel?.city {
                            Text("Broadcast from \(city)")
                                .microLabel(1.4)
                                .foregroundStyle(Palette.inkMuted)
                        }

                        if !show.genres.isEmpty {
                            WrapLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(show.genres, id: \.self) { TagChip(text: $0) }
                            }
                        }

                        if let summary = show.summary {
                            Text(summary)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
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
    private func episodeList(_ episodes: [IdaEpisode]) -> some View {
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
                Text(browse.isLoadingShow(slug)
                     ? "Loading episodes…"
                     : "Nothing archived for this show.")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                    .background(Palette.wash)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(episodes) { episode in
                        IdaEpisodeRow(
                            episode: episode,
                            isCurrent: IdaPlayback.isCurrent(episode, in: player),
                            isPlaying: IdaPlayback.isPlaying(episode, in: player),
                            open: {
                                browse.remember([episode])
                                appState.open(.idaEpisode(slug: episode.slug))
                            },
                            play: { IdaPlayback.toggle(episode, within: episodes, using: player) }
                        )
                        Rule()
                    }
                }
            }
        }
    }

    private func playButton(_ episode: IdaEpisode, queue: [IdaEpisode], large: Bool = false) -> some View {
        let isPlaying = IdaPlayback.isPlaying(episode, in: player)
        return Button {
            IdaPlayback.toggle(episode, within: queue, using: player)
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
