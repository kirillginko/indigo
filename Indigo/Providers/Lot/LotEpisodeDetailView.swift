//
//  LotEpisodeDetailView.swift
//  Indigo
//
//  The expanded page for one broadcast. The Lot archives more about a set than
//  any other station Indigo reads — a timestamped tracklist, frames grabbed
//  off the booth camera, the residency and who played it — so this page shows
//  all of it rather than a summary of it.
//

import SwiftUI

struct LotEpisodeDetailView: View {
    let ref: LotEpisodeRef

    @Environment(AppState.self) private var appState
    @Environment(LotBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let detail = browse.episodeDetail(ref: ref)
        let episode = detail?.episode ?? browse.episode(ref: ref)

        VStack(spacing: 0) {
            PageHeader(
                title: episode?.title ?? "The Lot Radio",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: [episode?.airedLabel, episode?.show?.name ?? "The Lot Radio"]
                    .compactMap { $0 }.joined(separator: " · ")
            ) {
                if let episode {
                    HStack(spacing: 10) {
                        if episode.isPlayable { playButton(episode) }
                        LotCrateButton(episode: episode)
                    }
                }
            }
            Rule(color: Palette.outline)

            if let episode {
                content(episode: episode, detail: detail)
            } else if browse.isLoadingEpisode(ref) {
                LoadingPane(label: "Loading broadcast")
            } else {
                EmptyStateView(
                    headline: "Broadcast unavailable",
                    message: browse.episodeError(ref)
                        ?? "The Lot is no longer publishing information for this broadcast."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: ref) { await browse.loadEpisodeIfNeeded(ref: ref) }
    }

    private func content(episode: LotEpisode, detail: LotEpisodeDetail?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(episode: episode, detail: detail)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)

                if episode.thumbnailURLs.count > 1 { gallery(episode) }
                if !episode.artists.isEmpty { people(episode.artists, title: "On this broadcast") }
                tracklist(episode)
                related(detail)
            }
        }
        .scrollIndicators(.visible)
    }

    // MARK: - Hero

    private func hero(episode: LotEpisode, detail: LotEpisodeDetail?) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(remoteURL: episode.artworkURL, side: 300)
                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 16) {
                if let show = episode.show {
                    Button {
                        appState.open(.lotShow(slug: show.slug))
                    } label: {
                        Text(show.name)
                            .microLabel(1.8)
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    MicroLabel(text: "The Lot archive")
                }

                Text(episode.title)
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                factLine(episode)

                if !episode.genres.isEmpty {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(episode.genres) { genre in
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
                } else if browse.isLoadingEpisode(ref) {
                    Text("Loading the session note…")
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
                    LotCrateButton(episode: episode)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func factLine(_ episode: LotEpisode) -> some View {
        let facts = [
            episode.airedLabel,
            episode.slot,
            episode.duration.map { TimeFormat.clock($0) },
            episode.location
        ].compactMap { $0 }.filter { !$0.isEmpty }

        return Text(facts.joined(separator: "  ·  "))
            .font(Typeface.mono(11))
            .foregroundStyle(Palette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Sections

    /// The Lot samples the video stream every so often while a set is running,
    /// so these are the broadcast itself rather than press shots.
    private func gallery(_ episode: LotEpisode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("From the broadcast", trailing: "\(episode.thumbnailURLs.count) frames")
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(episode.thumbnailURLs, id: \.self) { url in
                        AsyncImage(url: url, transaction: Transaction(animation: .none)) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            default:
                                Rectangle().fill(Palette.placeholder)
                            }
                        }
                        .frame(width: 214, height: 120)
                        .clipped()
                        .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func people(_ artists: [LotArtist], title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title, trailing: nil)
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
                        } else if artist.isResident {
                            Text("Resident")
                                .microLabel(1.1, size: 9)
                                .foregroundStyle(Palette.inkFaint)
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

    private func tracklist(_ episode: LotEpisode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                "Tracklist",
                trailing: episode.tracklist.isEmpty ? nil : "\(episode.tracklist.count) logged"
            )
            if episode.tracklist.isEmpty {
                Text("The Lot didn't log a tracklist for this broadcast.")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                    .background(Palette.wash)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(episode.tracklist) { track in
                        LotTrackRow(track: track, isPlayable: episode.isPlayable) {
                            LotPlayback.play(episode, from: track, using: player)
                        }
                        Rule()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func related(_ detail: LotEpisodeDetail?) -> some View {
        let episodes = detail?.related ?? []
        if !episodes.isEmpty {
            let name = detail?.episode.show?.name
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(
                    name.map { "More from \($0)" } ?? "More from the archive",
                    trailing: nil
                )
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(episodes) { episode in
                        LotEpisodeTile(
                            episode: episode,
                            isCurrent: LotPlayback.isCurrent(episode, in: player),
                            isPlaying: LotPlayback.isPlaying(episode, in: player),
                            open: {
                                guard let next = episode.ref else { return }
                                browse.remember([episode])
                                appState.open(.lotEpisode(show: next.show, episode: next.episode))
                            },
                            play: { LotPlayback.toggle(episode, within: episodes, using: player) }
                        )
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
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

    private func playButton(_ episode: LotEpisode, large: Bool = false) -> some View {
        let isPlaying = LotPlayback.isPlaying(episode, in: player)
        return Button {
            LotPlayback.toggle(episode, within: [episode], using: player)
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
