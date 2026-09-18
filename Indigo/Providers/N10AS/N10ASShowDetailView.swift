//
//  N10ASShowDetailView.swift
//  Indigo
//
//  One show: when it goes out, what it is, and as much of its run as can be
//  found.
//
//  n10.as publishes no link at all between a programme and its recordings —
//  the archive is one flat Mixcloud feed of eleven thousand uploads, and the
//  only thing tying a broadcast to a show is the name typed at the front of
//  its title. So the run here is searched for and merged with whatever the
//  Archive page has been scrolled through, and the page says how many it
//  found rather than presenting it as the complete run, because for a
//  programme whose name is a common word it will not be.
//

import SwiftUI

struct N10ASShowDetailView: View {
    let slug: String

    @Environment(AppState.self) private var appState
    @Environment(N10ASBrowseStore.self) private var browse
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
                    message: browse.showError(slug) ?? "n10.as no longer publishes this show."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: slug) { await browse.loadShowIfNeeded(slug: slug) }
    }

    private func subtitle(_ show: N10ASShow?, episodes: [N10ASEpisode]) -> String {
        guard let show else { return "n10.as" }
        let count = episodes.isEmpty
            ? nil
            : "\(episodes.count) \(episodes.count == 1 ? "broadcast" : "broadcasts") found"
        return [count, show.timeslot, "n10.as"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func content(_ show: N10ASShow, episodes: [N10ASEpisode]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(
                        remoteURL: show.imageURL,
                        side: 300,
                        markURL: N10ASProvider.logoURL,
                        mark: "n10.as"
                    )
                    .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 16) {
                        MicroLabel(text: "Show")

                        Text(show.title)
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        if let timeslot = show.timeslot {
                            Text(timeslot)
                                .font(Typeface.mono(11))
                                .foregroundStyle(Palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text("Montréal, Canada")
                            .microLabel(1.4)
                            .foregroundStyle(Palette.inkMuted)

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

                episodeList(episodes)
            }
        }
        .scrollIndicators(.visible)
    }

    @ViewBuilder
    private func episodeList(_ episodes: [N10ASEpisode]) -> some View {
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
                emptyNote
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(episodes) { episode in
                        N10ASEpisodeRow(
                            episode: episode,
                            isCurrent: N10ASPlayback.isCurrent(episode, in: player),
                            isPlaying: N10ASPlayback.isPlaying(episode, in: player),
                            open: {
                                browse.remember([episode])
                                appState.open(.n10asEpisode(id: episode.id))
                            },
                            play: {
                                N10ASPlayback.toggle(episode, within: episodes, using: player)
                            }
                        )
                        Rule()
                    }
                }
                deeperNote
            }
        }
    }

    /// Nothing found is not the same as nothing published, and for this
    /// station the difference is usually the show's name: a programme called
    /// "Exhale" or "Channel Z" is a common enough phrase that a search of
    /// Mixcloud comes back with other people's uploads and none of n10.as's.
    /// The Archive page reads the station's own feed in order and will turn
    /// them up, so that is what the page offers.
    private var emptyNote: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                browse.isLoadingShow(slug)
                    ? "Looking for this show's broadcasts…"
                    : "Couldn't find this show's broadcasts. n10.as files every recording in one archive without saying which show it belongs to, so a show named after a common word can be hard to pick out. Reading further back through the Archive will turn them up."
            )
            .font(Typeface.body(12.5))
            .foregroundStyle(Palette.inkMuted)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)

            if !browse.isLoadingShow(slug) {
                Button("Open the Archive") { appState.select(.n10asArchive) }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 22)
        .background(Palette.wash)
    }

    /// A found run is a floor, not a ceiling — say so once, at the bottom,
    /// where somebody who has read the whole list is the one asking.
    private var deeperNote: some View {
        Text("Found by searching n10.as's archive — reading further back through the Archive may turn up more")
            .microLabel(1.4)
            .foregroundStyle(Palette.inkFaint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 22)
    }

    private func playButton(
        _ episode: N10ASEpisode,
        queue: [N10ASEpisode],
        large: Bool = false
    ) -> some View {
        let isPlaying = N10ASPlayback.isPlaying(episode, in: player)
        return Button {
            N10ASPlayback.toggle(episode, within: queue, using: player)
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
