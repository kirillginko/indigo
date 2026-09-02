//
//  PanikShowDetailView.swift
//  Indigo
//
//  One show: when it goes out, what it is, and every broadcast of it the
//  station still publishes.
//
//  This is where the archive is. The station's own feed carries fifty
//  broadcasts across a hundred and twenty-four shows; a show's feed carries
//  that show's run.
//

import SwiftUI

struct PanikShowDetailView: View {
    let slug: String

    @Environment(AppState.self) private var appState
    @Environment(PanikBrowseStore.self) private var browse
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
                    message: browse.showError(slug) ?? "Radio Panik no longer publishes this show."
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

    private func subtitle(_ show: PanikShow?, episodes: [PanikEpisode]) -> String {
        guard let show else { return "Radio Panik" }
        let count = episodes.isEmpty
            ? nil
            : "\(episodes.count) \(episodes.count == 1 ? "broadcast" : "broadcasts")"
        return [count, show.slot, "Radio Panik"].compactMap { $0 }.joined(separator: " · ")
    }

    private func content(_ show: PanikShow, episodes: [PanikEpisode]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(
                        remoteURL: show.imageURL,
                        side: 300,
                        markURL: PanikProvider.logoURL,
                        mark: "Radio Panik"
                    )
                    .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 16) {
                        MicroLabel(text: show.categories.first ?? "Show")

                        Text(show.title)
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        if let slot = show.slot {
                            Text(slot)
                                .font(Typeface.mono(11))
                                .foregroundStyle(Palette.inkMuted)
                        }

                        if !show.categories.isEmpty {
                            WrapLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(show.categories, id: \.self) { TagChip(text: $0) }
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
    private func episodeList(_ episodes: [PanikEpisode]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    Text("Broadcasts").microLabel(1.8)
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
                // Plenty of Panik's shows are broadcast live and never
                // recorded, which is the station's doing rather than a page
                // that failed to load.
                Text(browse.isLoadingShow(slug)
                     ? "Loading broadcasts…"
                     : "Radio Panik doesn't publish recordings of this show.")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                    .background(Palette.wash)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(episodes) { episode in
                        PanikEpisodeRow(
                            episode: episode,
                            isCurrent: PanikPlayback.isCurrent(episode, in: player),
                            isPlaying: PanikPlayback.isPlaying(episode, in: player),
                            open: {
                                browse.remember([episode])
                                appState.open(.panikEpisode(id: episode.id))
                            },
                            play: { PanikPlayback.toggle(episode, within: episodes, using: player) }
                        )
                        Rule()
                    }
                }
            }
        }
    }

    private func playButton(
        _ episode: PanikEpisode,
        queue: [PanikEpisode],
        large: Bool = false
    ) -> some View {
        let isPlaying = PanikPlayback.isPlaying(episode, in: player)
        return Button {
            PanikPlayback.toggle(episode, within: queue, using: player)
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
