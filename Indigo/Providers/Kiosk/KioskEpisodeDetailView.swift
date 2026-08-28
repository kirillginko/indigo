//
//  KioskEpisodeDetailView.swift
//  Indigo
//
//  Kiosk does not publish tracklists or episode descriptions, but an archive
//  entry still has useful identity, date, genres, artwork and playback links.
//

import SwiftUI

struct KioskEpisodeDetailView: View {
    let episodeSlug: String

    @Environment(AppState.self) private var appState
    @Environment(KioskBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let detail = browse.episodeDetail(slug: episodeSlug)
        let episode = detail?.episode ?? browse.episode(slug: episodeSlug)

        VStack(spacing: 0) {
            PageHeader(
                title: episode?.title ?? "Kiosk Show",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: [episode?.airedLabel, "Kiosk Radio"]
                    .compactMap { $0 }.joined(separator: " · ")
            ) {
                if let episode {
                    HStack(spacing: 10) {
                        if episode.isPlayable { playButton(episode) }
                        KioskCrateButton(episode: episode)
                    }
                }
            }
            Rule(color: Palette.outline)

            if let detail {
                content(detail)
            } else if browse.isLoadingEpisodeDetail(episodeSlug)
                        || browse.libraryPhase.isLoading || browse.moodsPhase.isLoading {
                LoadingPane(label: "Loading show")
            } else {
                EmptyStateView(
                    headline: "Show unavailable",
                    message: browse.episodeDetailError(episodeSlug)
                        ?? "Kiosk is no longer publishing information for this show."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: episodeSlug) {
            async let library: Void = browse.loadLibraryIfNeeded()
            async let moods: Void = browse.loadMoodsIfNeeded()
            async let detail: Void = browse.loadEpisodeDetailIfNeeded(slug: episodeSlug)
            _ = await (library, moods, detail)
        }
    }

    private func content(_ detail: KioskEpisodeDetail) -> some View {
        let episode = detail.episode
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(remoteURL: episode.artworkURL, side: 300)
                        .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 16) {
                        MicroLabel(text: detail.residencyName ?? "Kiosk archive")

                        Text(episode.title)
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        if let date = episode.airedLabel {
                            Text(date)
                                .font(Typeface.mono(11))
                                .foregroundStyle(Palette.inkMuted)
                        }

                        if !episode.genres.isEmpty {
                            Text(episode.genres.joined(separator: " · "))
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let description = detail.description {
                            Text(description)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let schedule = detail.residencySchedule {
                            Text(schedule).microLabel(1.1).foregroundStyle(Palette.inkFaint)
                        }

                        Spacer(minLength: 0)
                        HStack(spacing: 10) {
                            if episode.isPlayable { playButton(episode, large: true) }
                            KioskCrateButton(episode: episode)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)

                if let summary = detail.residencySummary, summary != detail.description {
                    sectionHeader(detail.residencyName ?? "About the show")
                    Text(summary)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .lineSpacing(4)
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, 18)
                }

                sectionHeader("Tracklist")
                if detail.tracklist.isEmpty {
                    Text("Kiosk has not published a tracklist for this show.")
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, 22)
                        .background(Palette.wash)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(detail.tracklist.enumerated()), id: \.offset) { index, track in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text("\(index + 1)")
                                    .font(Typeface.mono(9.5)).foregroundStyle(Palette.inkFaint)
                                    .frame(width: 28, alignment: .trailing)
                                Text(track).font(Typeface.body(12.5))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Metrics.gutter)
                            .frame(minHeight: Metrics.rowHeight)
                            Rule()
                        }
                    }
                }

                sectionHeader(detail.residencyName == nil ? "Similar shows" : "More from \(detail.residencyName!)")
                if detail.related.isEmpty {
                    Text("No similar archived shows were found.")
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, 22)
                } else {
                    KioskRelatedGrid(episodes: detail.related)
                        .padding(.vertical, 22)
                }
            }
        }
        .scrollIndicators(.visible)
    }

    private func sectionHeader(_ title: String) -> some View {
        VStack(spacing: 0) {
            Rule(color: Palette.outline)
            HStack { Text(title).microLabel(1.8); Spacer() }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
            Rule()
        }
    }

    private func playButton(_ episode: KioskEpisode, large: Bool = false) -> some View {
        let isPlaying = KioskPlayback.isPlaying(episode, in: player)
        return Button {
            KioskPlayback.toggle(episode, within: [episode], using: player)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: large ? 11 : 9))
                Text(isPlaying ? "Pause" : "Play Show")
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

private struct KioskRelatedGrid: View {
    let episodes: [KioskEpisode]
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
            ForEach(episodes) { episode in
                KioskEpisodeTile(
                    episode: episode,
                    isCurrent: KioskPlayback.isCurrent(episode, in: player),
                    isPlaying: KioskPlayback.isPlaying(episode, in: player),
                    open: { appState.open(.kioskEpisode(slug: episode.slug)) },
                    play: { KioskPlayback.toggle(episode, within: episodes, using: player) }
                )
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}
