//
//  IdaEpisodeDetailView.swift
//  Indigo
//
//  The expanded page for one episode. IDA logs a tracklist for most of what it
//  archives, written a track a paragraph with the label and year in brackets —
//  which is a good deal more than most stations publish, and the reason this
//  page is worth opening.
//

import SwiftUI

struct IdaEpisodeDetailView: View {
    let slug: String

    @Environment(AppState.self) private var appState
    @Environment(IdaBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let episode = browse.episode(slug: slug)

        VStack(spacing: 0) {
            PageHeader(
                title: episode?.title ?? "IDA Radio",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: [episode?.broadcastLabel, episode?.showTitle ?? "IDA Radio"]
                    .compactMap { $0 }.joined(separator: " · ")
            ) {
                if let episode {
                    HStack(spacing: 10) {
                        if episode.isPlayable { playButton(episode) }
                        IdaCrateButton(episode: episode)
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
                    message: browse.detailError(slug) ?? "IDA no longer publishes this episode."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: slug) { await browse.loadDetailIfNeeded(slug: slug) }
    }

    private func content(_ episode: IdaEpisode) -> some View {
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

    private func hero(_ episode: IdaEpisode) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(
                remoteURL: episode.imageURL,
                side: 300,
                markURL: IdaProvider.logoURL,
                mark: "IDA Radio"
            )
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 16) {
                if let show = episode.showTitle, let showSlug = episode.showSlug {
                    Button { appState.open(.idaShow(slug: showSlug)) } label: {
                        Text(show).microLabel(1.8).foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    MicroLabel(text: "IDA archive")
                }

                Text(episode.title)
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle = episode.subtitle {
                    Text(subtitle)
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

                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if episode.isPlayable {
                        playButton(episode, large: true)
                    } else {
                        Text("No recording published")
                            .microLabel(1.2, size: 9.5)
                            .foregroundStyle(Palette.inkFaint)
                    }
                    IdaCrateButton(episode: episode)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func facts(_ episode: IdaEpisode) -> String {
        [
            episode.broadcastLabel,
            episode.showArtist,
            episode.channel?.city,
            episode.duration.map { TimeFormat.clock($0) },
            episode.isRepeat ? "Repeat" : nil
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func tracklist(_ episode: IdaEpisode) -> some View {
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
                     : "IDA didn't log a tracklist for this episode.")
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
                                providerID: IdaProvider.providerID, showID: episode.slug,
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
    private func related(_ episode: IdaEpisode) -> some View {
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
                        IdaEpisodeTile(
                            episode: other,
                            isCurrent: IdaPlayback.isCurrent(other, in: player),
                            isPlaying: IdaPlayback.isPlaying(other, in: player),
                            open: {
                                browse.remember([other])
                                appState.open(.idaEpisode(slug: other.slug))
                            },
                            play: { IdaPlayback.toggle(other, within: Array(siblings), using: player) }
                        )
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
        }
    }

    private func playButton(_ episode: IdaEpisode, large: Bool = false) -> some View {
        let isPlaying = IdaPlayback.isPlaying(episode, in: player)
        return Button {
            IdaPlayback.toggle(episode, within: [episode], using: player)
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
