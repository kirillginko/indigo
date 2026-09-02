//
//  Radio80000EpisodeDetailView.swift
//  Indigo
//
//  The expanded page for one broadcast. Whether it has a tracklist depends on
//  where it lives: Mixcloud logs one per upload and hands it back on the
//  single-cloudcast read, and SoundCloud does not — so the page says which of
//  the two it came from rather than leaving a blank panel unexplained.
//

import SwiftUI

struct Radio80000EpisodeDetailView: View {
    let episodeID: String

    @Environment(AppState.self) private var appState
    @Environment(Radio80000BrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let episode = browse.episode(id: episodeID)

        VStack(spacing: 0) {
            PageHeader(
                title: episode?.title ?? "Radio 80000",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: [episode?.broadcastLabel, episode?.showTitle ?? "Radio 80000"]
                    .compactMap { $0 }.joined(separator: " · ")
            ) {
                if let episode {
                    HStack(spacing: 10) {
                        playButton(episode)
                        Radio80000CrateButton(episode: episode)
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
                        ?? "Radio 80000 no longer publishes this broadcast."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: episodeID) { await browse.loadDetailIfNeeded(id: episodeID) }
    }

    private func content(_ episode: Radio80000Episode) -> some View {
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

    private func hero(_ episode: Radio80000Episode) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(
                remoteURL: episode.artworkURL,
                side: 300,
                markURL: Radio80000Provider.logoURL,
                mark: "Radio 80000"
            )
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 16) {
                if let show = episode.showTitle, let slug = episode.showSlug {
                    Button { appState.open(.radio80000Show(slug: slug)) } label: {
                        Text(show).microLabel(1.8).foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    MicroLabel(text: episode.showTitle ?? "Radio 80000")
                }

                Text(episode.title)
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

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
                    Radio80000CrateButton(episode: episode)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func facts(_ episode: Radio80000Episode) -> String {
        [
            episode.broadcastLabel,
            episode.duration.map { TimeFormat.clock($0) },
            episode.source.label
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func tracklist(_ episode: Radio80000Episode) -> some View {
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
                Text(emptyTracklistNote(episode))
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                    .background(Palette.wash)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(episode.tracks) { track in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text("\(track.index + 1)")
                                .font(Typeface.mono(9.5))
                                .foregroundStyle(Palette.inkFaint)
                                .frame(width: 28, alignment: .trailing)
                            Text(track.display)
                                .font(Typeface.body(12.5))
                                .fixedSize(horizontal: false, vertical: true)
                            if let offset = track.offsetLabel {
                                Text(offset)
                                    .font(Typeface.mono(9.5))
                                    .foregroundStyle(Palette.inkFaint)
                                    .monospacedDigit()
                            }
                            Spacer(minLength: 0)
                            RadioTracklistCrateButton(item: RadioTracklistItem(
                                providerID: Radio80000Provider.providerID,
                                showID: episode.id,
                                showTitle: episode.title,
                                airedAt: episode.broadcastAt,
                                entryID: "\(track.index)",
                                title: track.title,
                                artist: track.artist,
                                offsetSeconds: track.offset
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

    /// Why the panel is empty, which differs by platform and is not the
    /// listener's fault either way.
    private func emptyTracklistNote(_ episode: Radio80000Episode) -> String {
        if browse.isLoadingDetail(episodeID) { return "Loading…" }
        switch episode.source {
        case .mixcloud:
            return "Radio 80000 didn't log a tracklist for this broadcast."
        case .soundcloud:
            return "SoundCloud carries no tracklist for this broadcast."
        }
    }

    @ViewBuilder
    private func related(_ episode: Radio80000Episode) -> some View {
        let siblings = (episode.showSlug.map { browse.episodes(ofShow: $0) } ?? [])
            .filter { $0.id != episode.id }
        if !siblings.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    Rule(color: Palette.outline)
                    HStack {
                        Text(episode.showTitle.map { "More from \($0)" } ?? "More broadcasts")
                            .microLabel(1.8)
                        Spacer()
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 14)
                    Rule()
                }
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(siblings.prefix(12)) { other in
                        Radio80000EpisodeTile(
                            episode: other,
                            isCurrent: Radio80000Playback.isCurrent(other, in: player),
                            isPlaying: Radio80000Playback.isPlaying(other, in: player),
                            open: {
                                browse.remember([other])
                                appState.open(.radio80000Episode(id: other.id))
                            },
                            play: {
                                Radio80000Playback.toggle(
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

    private func playButton(_ episode: Radio80000Episode, large: Bool = false) -> some View {
        let isPlaying = Radio80000Playback.isPlaying(episode, in: player)
        return Button {
            Radio80000Playback.toggle(episode, within: [episode], using: player)
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
