//
//  LotShowDetailView.swift
//  Indigo
//
//  A residency: who holds it, what it sounds like, and every broadcast of it
//  the station has kept.
//

import SwiftUI

struct LotShowDetailView: View {
    let showSlug: String

    @Environment(AppState.self) private var appState
    @Environment(LotBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let detail = browse.showDetail(slug: showSlug)
        let show = detail?.show ?? browse.show(slug: showSlug)

        VStack(spacing: 0) {
            PageHeader(
                title: show?.name ?? "Show",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(detail)
            ) {
                if let detail, let first = detail.episodes.first(where: \.isPlayable) {
                    playButton(first, queue: detail.episodes)
                }
            }
            Rule(color: Palette.outline)

            if let show {
                content(show: show, detail: detail)
            } else if browse.isLoadingShow(showSlug) || browse.showsPhase.isLoading {
                LoadingPane(label: "Loading show")
            } else {
                EmptyStateView(
                    headline: "Show unavailable",
                    message: browse.showError(showSlug)
                        ?? "The Lot is no longer publishing information for this residency."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: showSlug) {
            async let directory: Void = browse.loadShowsIfNeeded()
            async let show: Void = browse.loadShowIfNeeded(slug: showSlug)
            _ = await (directory, show)
        }
    }

    private func subtitle(_ detail: LotShowDetail?) -> String {
        guard let detail else { return "The Lot Radio" }
        let count = detail.episodes.count
        guard count > 0 else { return "The Lot Radio" }
        return "\(count) \(count == 1 ? "broadcast" : "broadcasts") · The Lot Radio"
    }

    private func content(show: LotShow, detail: LotShowDetail?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(remoteURL: show.photoURL, side: 300)
                        .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 16) {
                        MicroLabel(text: "Residency")

                        Text(show.name)
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        if !show.genres.isEmpty {
                            WrapLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(show.genres) { genre in
                                    TagChip(text: genre.name)
                                }
                            }
                        }

                        if let summary = detail?.summary {
                            Text(summary)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if browse.isLoadingShow(showSlug) {
                            Text("Loading the residency note…")
                                .font(Typeface.mono(10))
                                .foregroundStyle(Palette.inkFaint)
                        }

                        Spacer(minLength: 0)
                        if let detail, let first = detail.episodes.first(where: \.isPlayable) {
                            playButton(first, queue: detail.episodes, large: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)

                if !show.artists.isEmpty { residents(show.artists) }
                broadcasts(detail)
            }
        }
        .scrollIndicators(.visible)
    }

    private func residents(_ artists: [LotArtist]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Residents", trailing: nil)
            ForEach(artists) { artist in
                HStack(spacing: 14) {
                    ArtworkView(remoteURL: artist.photoURL, side: 44)
                        .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(artist.name)
                            .font(Typeface.body(12.5, weight: .semibold))
                        if let aka = artist.aka, !aka.isEmpty {
                            Text("aka \(aka)")
                                .font(Typeface.body(12))
                                .foregroundStyle(Palette.inkMuted)
                        }
                    }
                    Spacer(minLength: 12)
                    MediaLinkChips(links: artist.links)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 10)
                Rule()
            }
        }
    }

    @ViewBuilder
    private func broadcasts(_ detail: LotShowDetail?) -> some View {
        let episodes = detail?.episodes ?? []
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                "Broadcasts",
                trailing: episodes.isEmpty ? nil : "Newest first"
            )
            if episodes.isEmpty {
                Text(browse.isLoadingShow(showSlug)
                     ? "Loading broadcasts…"
                     : "The Lot hasn't archived any broadcasts of this residency.")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                    .background(Palette.wash)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(episodes) { episode in
                        LotEpisodeRow(
                            episode: episode,
                            isCurrent: LotPlayback.isCurrent(episode, in: player),
                            isPlaying: LotPlayback.isPlaying(episode, in: player),
                            open: {
                                guard let ref = episode.ref else { return }
                                browse.remember([episode])
                                appState.open(.lotEpisode(show: ref.show, episode: ref.episode))
                            },
                            play: { LotPlayback.toggle(episode, within: episodes, using: player) }
                        )
                        Rule()
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, trailing: String?) -> some View {
        VStack(spacing: 0) {
            Rule(color: Palette.outline)
            HStack {
                Text(title).microLabel(1.8)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .microLabel(1.2)
                        .foregroundStyle(Palette.inkFaint)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 14)
            Rule()
        }
    }

    private func playButton(_ episode: LotEpisode, queue: [LotEpisode], large: Bool = false) -> some View {
        let isPlaying = LotPlayback.isPlaying(episode, in: player)
        return Button {
            LotPlayback.toggle(episode, within: queue, using: player)
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
