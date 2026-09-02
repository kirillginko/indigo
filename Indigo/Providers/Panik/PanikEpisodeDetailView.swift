//
//  PanikEpisodeDetailView.swift
//  Indigo
//
//  The expanded page for one broadcast.
//
//  Panik logs what it played on the continuous-music hours, filed by the day
//  rather than by the episode — so the log for a broadcast is fetched by its
//  date, and most episodes have none. The page says which rather than leaving
//  an empty panel to be read as a failure.
//

import SwiftUI

struct PanikEpisodeDetailView: View {
    let episodeID: String

    @Environment(AppState.self) private var appState
    @Environment(PanikBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let episode = browse.episode(id: episodeID)

        VStack(spacing: 0) {
            PageHeader(
                title: episode?.title ?? "Radio Panik",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: [episode?.broadcastLabel, episode?.showTitle ?? "Radio Panik"]
                    .compactMap { $0 }.joined(separator: " · ")
            ) {
                if let episode {
                    HStack(spacing: 10) {
                        if episode.isPlayable { playButton(episode) }
                        PanikCrateButton(episode: episode)
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
                        ?? "Radio Panik no longer publishes this broadcast."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: episodeID) {
            await browse.loadDetailIfNeeded(id: episodeID)
            guard let episode = browse.episode(id: episodeID),
                  let slug = episode.showSlug,
                  let date = episode.playlistDate
            else { return }
            await browse.loadTracksIfNeeded(forShow: slug, on: date)
        }
    }

    private func content(_ episode: PanikEpisode) -> some View {
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

    private func hero(_ episode: PanikEpisode) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(
                remoteURL: episode.imageURL,
                side: 300,
                markURL: PanikProvider.logoURL,
                mark: "Radio Panik"
            )
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 16) {
                if let show = episode.showTitle, let slug = episode.showSlug {
                    Button { appState.open(.panikShow(slug: slug)) } label: {
                        Text(show).microLabel(1.8).foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    MicroLabel(text: "Radio Panik")
                }

                Text(episode.title)
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                Text(facts(episode))
                    .font(Typeface.mono(11))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if let summary = episode.summary {
                    Text(summary)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
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
                    PanikCrateButton(episode: episode)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func facts(_ episode: PanikEpisode) -> String {
        [
            episode.broadcastLabel,
            episode.duration.map { TimeFormat.clock($0) }
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func tracklist(_ episode: PanikEpisode) -> some View {
        let tracks = loggedTracks(episode)
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    Text("Tracklist").microLabel(1.8)
                    Spacer()
                    if !tracks.isEmpty {
                        Text("\(tracks.count) logged")
                            .microLabel(1.2).foregroundStyle(Palette.inkFaint)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                Rule()
            }

            if tracks.isEmpty {
                Text(emptyNote(episode))
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                    .background(Palette.wash)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(tracks) { track in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(track.time ?? "\(track.index + 1)")
                                .font(Typeface.mono(9.5))
                                .foregroundStyle(Palette.inkFaint)
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                            Text(track.display)
                                .font(Typeface.body(12.5))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            RadioTracklistCrateButton(item: RadioTracklistItem(
                                providerID: PanikProvider.providerID,
                                showID: episode.id,
                                showTitle: episode.title,
                                airedAt: episode.publishedAt,
                                entryID: "\(track.index)",
                                title: track.title,
                                artist: track.artist,
                                offsetSeconds: nil
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

    private func loggedTracks(_ episode: PanikEpisode) -> [PanikTrack] {
        guard let slug = episode.showSlug, let date = episode.playlistDate else { return [] }
        return browse.tracks(forShow: slug, on: date)
    }

    /// Panik keeps a log for the continuous-music hours and not for the rest,
    /// which is the station's practice rather than a gap in the page.
    private func emptyNote(_ episode: PanikEpisode) -> String {
        guard let slug = episode.showSlug, let date = episode.playlistDate else {
            return "Radio Panik didn't log a tracklist for this broadcast."
        }
        return browse.isLoadingTracks(forShow: slug, on: date)
            ? "Loading…"
            : "Radio Panik didn't log a tracklist for this broadcast."
    }

    @ViewBuilder
    private func related(_ episode: PanikEpisode) -> some View {
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
                        PanikEpisodeTile(
                            episode: other,
                            isCurrent: PanikPlayback.isCurrent(other, in: player),
                            isPlaying: PanikPlayback.isPlaying(other, in: player),
                            open: {
                                browse.remember([other])
                                appState.open(.panikEpisode(id: other.id))
                            },
                            play: {
                                PanikPlayback.toggle(other, within: Array(siblings), using: player)
                            }
                        )
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
        }
    }

    private func playButton(_ episode: PanikEpisode, large: Bool = false) -> some View {
        let isPlaying = PanikPlayback.isPlaying(episode, in: player)
        return Button {
            PanikPlayback.toggle(episode, within: [episode], using: player)
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
