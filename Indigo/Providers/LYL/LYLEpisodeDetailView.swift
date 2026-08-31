//
//  LYLEpisodeDetailView.swift
//  Indigo
//
//  The expanded page for one episode. LYL writes a note for most of them and
//  logs a tracklist for nearly all, so there is usually a good deal to show.
//

import SwiftUI

struct LYLEpisodeDetailView: View {
    let slug: String

    @Environment(AppState.self) private var appState
    @Environment(LYLBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let episode = browse.episode(slug: slug)

        VStack(spacing: 0) {
            PageHeader(
                title: episode?.title ?? "LYL Radio",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: [episode?.broadcastLabel, episode?.showTitle ?? "LYL Radio"]
                    .compactMap { $0 }.joined(separator: " · ")
            ) {
                if let episode {
                    HStack(spacing: 10) {
                        if episode.isPlayable { playButton(episode) }
                        LYLCrateButton(episode: episode)
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
                    message: browse.detailError(slug) ?? "LYL no longer publishes this episode."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: slug) { await browse.loadDetailIfNeeded(slug: slug) }
    }

    private func content(_ episode: LYLEpisode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(episode)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                tracklist(episode)
                related(episode)
            }
        }
        .scrollIndicators(.visible)
    }

    private func hero(_ episode: LYLEpisode) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(
                remoteURL: episode.imageURL,
                side: 300,
                markURL: LYLProvider.logoURL,
                mark: "LYL Radio"
            )
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 16) {
                if let show = episode.showTitle, let showSlug = episode.showSlug {
                    Button { appState.open(.lylShow(slug: showSlug)) } label: {
                        Text(show).microLabel(1.8).foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    MicroLabel(text: "LYL archive")
                }

                Text(episode.title)
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                Text(facts(episode))
                    .font(Typeface.mono(11))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if !episode.styles.isEmpty {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(episode.styles, id: \.self) { TagChip(text: $0) }
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
                    LYLCrateButton(episode: episode)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func facts(_ episode: LYLEpisode) -> String {
        [
            episode.broadcastLabel,
            episode.artists,
            episode.duration.map { TimeFormat.clock($0) }
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func tracklist(_ episode: LYLEpisode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    Text("Tracklist").microLabel(1.8)
                    Spacer()
                    if !episode.tracks.isEmpty {
                        Text("\(episode.tracks.count) logged")
                            .microLabel(1.2).foregroundStyle(Palette.inkFaint)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                Rule()
            }

            if episode.tracks.isEmpty {
                Text(browse.isLoadingDetail(slug)
                     ? "Loading…"
                     : "LYL didn't log a tracklist for this episode.")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                    .background(Palette.wash)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(episode.tracks.enumerated()), id: \.offset) { index, track in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text("\(index + 1)")
                                .font(Typeface.mono(9.5))
                                .foregroundStyle(Palette.inkFaint)
                                .frame(width: 28, alignment: .trailing)
                            Text(track)
                                .font(Typeface.body(12.5))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            RadioTracklistCrateButton(item: RadioTracklistItem(
                                providerID: "lyl", showID: episode.slug,
                                showTitle: episode.title, airedAt: episode.broadcastAt,
                                entryID: "\(index)", title: track, artist: nil, offsetSeconds: nil
                            ))
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, 7)
                        .frame(minHeight: Metrics.rowHeight)
                        Rule()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func related(_ episode: LYLEpisode) -> some View {
        let siblings = (episode.showSlug.map { browse.episodes(ofShow: $0) } ?? [])
            .filter { $0.slug != episode.slug }
        if !siblings.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    Rule(color: Palette.outline)
                    HStack {
                        Text(episode.showTitle.map { "More from \($0)" } ?? "More from the archive")
                            .microLabel(1.8)
                        Spacer()
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 14)
                    Rule()
                }
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(siblings.prefix(12)) { other in
                        LYLEpisodeTile(
                            episode: other,
                            isCurrent: LYLPlayback.isCurrent(other, in: player),
                            isPlaying: LYLPlayback.isPlaying(other, in: player),
                            open: {
                                browse.remember([other])
                                appState.open(.lylEpisode(slug: other.slug))
                            },
                            play: { LYLPlayback.toggle(other, within: Array(siblings), using: player) }
                        )
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
        }
    }

    private func playButton(_ episode: LYLEpisode, large: Bool = false) -> some View {
        let isPlaying = LYLPlayback.isPlaying(episode, in: player)
        return Button {
            LYLPlayback.toggle(episode, within: [episode], using: player)
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
