//
//  DublabDJDetailView.swift
//  Indigo
//
//  One DJ: who they are, the programmes they hold, and every broadcast of
//  theirs dublab has kept.
//

import SwiftUI

struct DublabDJDetailView: View {
    let slug: String

    @Environment(AppState.self) private var appState
    @Environment(DublabBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let dj = browse.dj(slug: slug)
        let run = browse.broadcasts(byDJ: slug)

        VStack(spacing: 0) {
            PageHeader(
                title: dj?.name ?? "DJ",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(dj, run: run)
            ) {
                if let first = run.first(where: \.isPlayable) {
                    playButton(first, queue: run)
                }
            }
            Rule(color: Palette.outline)

            if let dj {
                content(dj, run: run)
            } else if browse.isLoadingDJ(slug) || browse.djsPhase.isLoading {
                LoadingPane(label: "Loading DJ")
            } else {
                EmptyStateView(
                    headline: "DJ unavailable",
                    message: browse.djError(slug)
                        ?? "dublab is no longer publishing a page for this DJ."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: slug) {
            async let roster: Void = browse.loadDJsIfNeeded()
            async let detail: Void = browse.loadDJIfNeeded(slug: slug)
            _ = await (roster, detail)
        }
    }

    private func subtitle(_ dj: DublabDJ?, run: [DublabBroadcast]) -> String {
        guard dj != nil else { return "dublab" }
        let count = run.count
        let broadcasts = count > 0 ? "\(count) \(count == 1 ? "broadcast" : "broadcasts")" : nil
        return [broadcasts, "dublab"].compactMap { $0 }.joined(separator: " · ")
    }

    private func content(_ dj: DublabDJ, run: [DublabBroadcast]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(remoteURL: dj.artworkURL, side: 300)
                        .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 16) {
                        MicroLabel(text: dj.isActive ? "On air" : "Past resident")

                        Text(dj.name)
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        if !dj.shows.isEmpty {
                            WrapLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(dj.shows) { show in
                                    TagChip(text: show.title)
                                }
                            }
                        }

                        if let biography = dj.biography {
                            Text(biography)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if browse.isLoadingDJ(slug) {
                            Text("Loading the biography…")
                                .font(Typeface.mono(10))
                                .foregroundStyle(Palette.inkFaint)
                        }

                        Spacer(minLength: 0)
                        if let first = run.first(where: \.isPlayable) {
                            playButton(first, queue: run, large: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)

                broadcasts(run)
            }
        }
        .scrollIndicators(.visible)
    }

    @ViewBuilder
    private func broadcasts(_ run: [DublabBroadcast]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    Text("Broadcasts").microLabel(1.8)
                    Spacer()
                    if !run.isEmpty {
                        Text("Newest first").microLabel(1.2).foregroundStyle(Palette.inkFaint)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                Rule()
            }

            if run.isEmpty {
                Text(browse.isLoadingDJ(slug)
                     ? "Loading broadcasts…"
                     : "dublab hasn't archived any broadcasts for this DJ.")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                    .background(Palette.wash)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(run) { broadcast in
                        DublabBroadcastRow(
                            broadcast: broadcast,
                            isCurrent: DublabPlayback.isCurrent(broadcast, in: player),
                            isPlaying: DublabPlayback.isPlaying(broadcast, in: player),
                            open: {
                                browse.remember([broadcast])
                                appState.open(.dublabBroadcast(slug: broadcast.slug))
                            },
                            play: { DublabPlayback.toggle(broadcast, within: run, using: player) }
                        )
                        Rule()
                    }
                }
            }
        }
    }

    private func playButton(_ broadcast: DublabBroadcast, queue: [DublabBroadcast], large: Bool = false) -> some View {
        let isPlaying = DublabPlayback.isPlaying(broadcast, in: player)
        return Button {
            DublabPlayback.toggle(broadcast, within: queue, using: player)
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
