//
//  N10ASEpisodeDetailView.swift
//  Indigo
//
//  The expanded page for one broadcast.
//
//  There is no tracklist panel here, and that is not an omission: n10.as logs
//  no tracklists anywhere. Every one of its 11,849 uploads comes back from
//  Mixcloud with an empty sections list, and RadioCult reports no track while
//  a show is on. So the page gives the broadcast what it does have — the
//  programme, the night, whoever was guesting, and whatever the host wrote —
//  and says plainly that the station does not publish what was played, rather
//  than showing an empty panel that reads as a failure to load.
//

import SwiftUI

struct N10ASEpisodeDetailView: View {
    let episodeID: String

    @Environment(AppState.self) private var appState
    @Environment(N10ASBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let episode = browse.episode(id: episodeID)

        VStack(spacing: 0) {
            PageHeader(
                title: episode?.title ?? "n10.as",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: [episode?.broadcastLabel, episode?.programme ?? "n10.as"]
                    .compactMap { $0 }.joined(separator: " · ")
            ) {
                if let episode {
                    HStack(spacing: 10) {
                        playButton(episode)
                        N10ASCrateButton(episode: episode)
                    }
                }
            }
            Rule(color: Palette.outline)

            if let episode {
                content(episode)
            } else if browse.isLoadingDetail(episodeID) {
                LoadingPane(label: "Loading broadcast")
            } else {
                EmptyStateView(
                    headline: "Broadcast unavailable",
                    message: browse.detailError(episodeID)
                        ?? "n10.as no longer publishes this broadcast."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: episodeID) { await browse.loadDetailIfNeeded(id: episodeID) }
    }

    private func content(_ episode: N10ASEpisode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(episode)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                tracklistNote
                related(episode)
            }
        }
        .scrollIndicators(.visible)
    }

    private func hero(_ episode: N10ASEpisode) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(
                remoteURL: episode.artworkURL,
                side: 300,
                markURL: N10ASProvider.logoURL,
                mark: "n10.as"
            )
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 16) {
                programmeLine(episode)

                Text(episode.title)
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                if let guest = episode.guest {
                    Text("with \(guest)")
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(facts(episode))
                    .font(Typeface.mono(11))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if !episode.genres.isEmpty {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(episode.genres, id: \.self) { TagChip(text: $0) }
                    }
                }

                if let summary = episode.summary {
                    Text(summary)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    playButton(episode, large: true)
                    N10ASCrateButton(episode: episode)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The programme is a link only when the station still lists it — several
    /// hundred of the archive's shows have ended and have no directory page
    /// to open.
    @ViewBuilder
    private func programmeLine(_ episode: N10ASEpisode) -> some View {
        if let show = browse.directoryShow(for: episode) {
            Button { appState.open(.n10asShow(slug: show.slug)) } label: {
                Text(show.title).microLabel(1.8).foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
        } else {
            MicroLabel(text: episode.programme ?? "n10.as")
        }
    }

    private func facts(_ episode: N10ASEpisode) -> String {
        [
            episode.broadcastLabel,
            episode.duration.map { TimeFormat.clock($0) },
            "Mixcloud"
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "  ·  ")
    }

    /// Said once, quietly, where a tracklist would be. Every other station in
    /// Indigo that keeps one shows it here, so its absence needs a reason
    /// rather than a blank.
    private var tracklistNote: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule(color: Palette.outline)
            Text("n10.as doesn't publish tracklists for its broadcasts.")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 18)
                .background(Palette.wash)
        }
    }

    @ViewBuilder
    private func related(_ episode: N10ASEpisode) -> some View {
        let siblings = browse.siblings(of: episode)
        if !siblings.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    Rule(color: Palette.outline)
                    HStack {
                        Text(episode.programme.map { "More from \($0)" } ?? "More broadcasts")
                            .microLabel(1.8)
                        Spacer()
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 14)
                    Rule()
                }
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(siblings.prefix(12)) { other in
                        N10ASEpisodeTile(
                            episode: other,
                            isCurrent: N10ASPlayback.isCurrent(other, in: player),
                            isPlaying: N10ASPlayback.isPlaying(other, in: player),
                            open: {
                                browse.remember([other])
                                appState.open(.n10asEpisode(id: other.id))
                            },
                            play: {
                                N10ASPlayback.toggle(
                                    other, within: Array(siblings), using: player
                                )
                            }
                        )
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
        }
    }

    private func playButton(_ episode: N10ASEpisode, large: Bool = false) -> some View {
        let isPlaying = N10ASPlayback.isPlaying(episode, in: player)
        return Button {
            N10ASPlayback.toggle(episode, within: [episode], using: player)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: large ? 11 : 9))
                Text(isPlaying ? "Pause" : "Play Broadcast")
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
