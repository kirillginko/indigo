//
//  Radio80000ShowDetailView.swift
//  Indigo
//
//  One show: when it goes out, who is behind it, and its whole run.
//
//  This is where the archive actually is. A show's recordings can be on
//  SoundCloud, on Mixcloud, or split across both — shows that moved platform
//  have their early years on one and their recent ones on the other — so the
//  two are read together and shown as one run in date order.
//

import SwiftUI

struct Radio80000ShowDetailView: View {
    let slug: String

    @Environment(AppState.self) private var appState
    @Environment(Radio80000BrowseStore.self) private var browse
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
                if let first = episodes.first {
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
                    message: browse.showError(slug) ?? "Radio 80000 no longer publishes this show."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: slug) { await browse.loadShowIfNeeded(slug: slug) }
    }

    private func subtitle(_ show: Radio80000Show?, episodes: [Radio80000Episode]) -> String {
        guard let show else { return "Radio 80000" }
        let count = episodes.isEmpty
            ? nil
            : "\(episodes.count) \(episodes.count == 1 ? "broadcast" : "broadcasts")"
        return [count, show.scheduleLabel, "Radio 80000"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func content(_ show: Radio80000Show, episodes: [Radio80000Episode]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(
                        remoteURL: show.imageURL,
                        side: 300,
                        markURL: Radio80000Provider.logoURL,
                        mark: "Radio 80000"
                    )
                    .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 16) {
                        MicroLabel(text: show.cycle ?? "Show")

                        Text(show.title)
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        if let slot = show.scheduleLabel {
                            Text(slot)
                                .font(Typeface.mono(11))
                                .foregroundStyle(Palette.inkMuted)
                        }

                        if let city = show.city {
                            Text(city)
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

                        MediaLinkChips(links: show.links)

                        Spacer(minLength: 0)
                        if let first = episodes.first {
                            playButton(first, queue: episodes, large: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)

                episodeList(show, episodes: episodes)
            }
        }
        .scrollIndicators(.visible)
    }

    @ViewBuilder
    private func episodeList(_ show: Radio80000Show, episodes: [Radio80000Episode]) -> some View {
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
                Text(emptyNote(show))
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                    .background(Palette.wash)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(episodes) { episode in
                        Radio80000EpisodeRow(
                            episode: episode,
                            isCurrent: Radio80000Playback.isCurrent(episode, in: player),
                            isPlaying: Radio80000Playback.isPlaying(episode, in: player),
                            open: {
                                browse.remember([episode])
                                appState.open(.radio80000Episode(id: episode.id))
                            },
                            play: {
                                Radio80000Playback.toggle(episode, within: episodes, using: player)
                            }
                        )
                        Rule()
                    }
                }
            }
        }
    }

    /// Twenty-nine shows keep no playlist on either platform. That is the
    /// station's doing, not a failure to load, and the page should say which.
    private func emptyNote(_ show: Radio80000Show) -> String {
        if browse.isLoadingShow(slug) { return "Loading broadcasts…" }
        return show.hasArchive
            ? "Nothing published for this show yet."
            : "Radio 80000 keeps no recordings for this show."
    }

    private func playButton(
        _ episode: Radio80000Episode,
        queue: [Radio80000Episode],
        large: Bool = false
    ) -> some View {
        let isPlaying = Radio80000Playback.isPlaying(episode, in: player)
        return Button {
            Radio80000Playback.toggle(episode, within: queue, using: player)
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
