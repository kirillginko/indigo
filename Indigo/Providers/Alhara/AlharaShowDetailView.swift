//
//  AlharaShowDetailView.swift
//  Indigo
//
//  One archived show. The listing gives the title, date and artwork; the
//  description and tracklist only arrive when the show is asked for by name.
//

import SwiftUI

struct AlharaShowDetailView: View {
    let slug: String

    @Environment(AppState.self) private var appState
    @Environment(AlharaBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let show = browse.show(slug: slug)

        VStack(spacing: 0) {
            PageHeader(
                title: show?.title ?? "Radio alHara",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: [show?.publishedLabel, "Radio alHara"]
                    .compactMap { $0 }.joined(separator: " · ")
            ) {
                if let show {
                    HStack(spacing: 10) {
                        playButton(show)
                        AlharaCrateButton(show: show)
                    }
                }
            }
            Rule(color: Palette.outline)

            if let show {
                content(show)
            } else if browse.isLoadingDetail(slug) {
                LoadingPane(label: "Loading show")
            } else {
                EmptyStateView(
                    headline: "Show unavailable",
                    message: browse.detailError(slug)
                        ?? "This show is no longer published."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: slug) { await browse.loadDetailIfNeeded(slug: slug) }
    }

    private func content(_ show: AlharaShow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(show)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)

                tracklist(show)
            }
        }
        .scrollIndicators(.visible)
    }

    private func hero(_ show: AlharaShow) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(remoteURL: show.artworkURL, side: 300)
                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 16) {
                MicroLabel(text: "alHara archive")

                Text(show.title)
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                Text(facts(show))
                    .font(Typeface.mono(11))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if !show.genres.isEmpty {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(show.genres, id: \.self) { genre in
                            TagChip(text: genre)
                        }
                    }
                }

                if let summary = show.summary {
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
                    playButton(show, large: true)
                    AlharaCrateButton(show: show)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func facts(_ show: AlharaShow) -> String {
        [
            show.publishedLabel,
            show.duration.map { TimeFormat.clock($0) },
            show.playCount.map { "\($0.formatted(.number)) plays" },
            "Bethlehem"
        ]
        .compactMap { $0 }
        .joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func tracklist(_ show: AlharaShow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    Text("Tracklist").microLabel(1.8)
                    Spacer()
                    if !show.tracklist.isEmpty {
                        Text("\(show.tracklist.count) logged")
                            .microLabel(1.2)
                            .foregroundStyle(Palette.inkFaint)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                Rule()
            }

            if show.tracklist.isEmpty {
                Text(browse.isLoadingDetail(slug)
                     ? "Loading…"
                     : "No tracklist was published for this show.")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                    .background(Palette.wash)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(show.tracklist) { track in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text("\(track.index)")
                                .font(Typeface.mono(9.5))
                                .foregroundStyle(Palette.inkFaint)
                                .frame(width: 28, alignment: .trailing)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(Typeface.body(12.5, weight: .semibold))
                                    .lineLimit(2)
                                if let artist = track.artist {
                                    Text(artist)
                                        .font(Typeface.body(12))
                                        .foregroundStyle(Palette.inkMuted)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(track.offsetLabel ?? "—")
                                .font(Typeface.mono(10))
                                .foregroundStyle(Palette.inkFaint)
                                .monospacedDigit()
                                .frame(width: 78, alignment: .trailing)
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, 8)
                        .frame(minHeight: Metrics.rowHeight)
                        Rule()
                    }
                }
            }
        }
    }

    private func playButton(_ show: AlharaShow, large: Bool = false) -> some View {
        let isPlaying = AlharaPlayback.isPlaying(show, in: player)
        return Button {
            AlharaPlayback.toggle(show, within: [show], using: player)
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
