//
//  DublabBroadcastDetailView.swift
//  Indigo
//
//  The expanded page for one broadcast: what it was, who played it, what
//  programme it belonged to, and everything dublab wrote about both.
//

import SwiftUI

struct DublabBroadcastDetailView: View {
    let slug: String

    @Environment(AppState.self) private var appState
    @Environment(DublabBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let broadcast = browse.broadcast(slug: slug)

        VStack(spacing: 0) {
            PageHeader(
                title: broadcast?.title ?? "dublab",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: [broadcast?.airedLabel, broadcast?.showName ?? "dublab"]
                    .compactMap { $0 }.joined(separator: " · ")
            ) {
                if let broadcast {
                    HStack(spacing: 10) {
                        if broadcast.isPlayable { playButton(broadcast) }
                        DublabCrateButton(broadcast: broadcast)
                    }
                }
            }
            Rule(color: Palette.outline)

            if let broadcast {
                content(broadcast)
            } else if browse.isLoadingBroadcast(slug) {
                LoadingPane(label: "Loading broadcast")
            } else {
                EmptyStateView(
                    headline: "Broadcast unavailable",
                    message: browse.broadcastError(slug)
                        ?? "dublab is no longer publishing information for this broadcast."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: slug) { await browse.loadBroadcastIfNeeded(slug: slug) }
    }

    private func content(_ broadcast: DublabBroadcast) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(broadcast)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)

                if let summary = broadcast.showSummary, let name = broadcast.showName {
                    section("About \(name)", body: summary)
                }
                if let summary = broadcast.performerSummary, let name = broadcast.performer {
                    section(name, body: summary)
                }
                related(broadcast)
            }
        }
        .scrollIndicators(.visible)
    }

    private func hero(_ broadcast: DublabBroadcast) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(remoteURL: broadcast.artworkURL, side: 300)
                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 16) {
                MicroLabel(text: broadcast.isGuestSession ? "Guest session" : (broadcast.showName ?? "dublab archive"))

                Text(broadcast.title)
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                Text(facts(broadcast))
                    .font(Typeface.mono(11))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if !broadcast.genres.isEmpty {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(broadcast.genres) { genre in
                            TagChip(text: genre.name)
                        }
                    }
                }

                // The archive files a broadcast under everyone who played it,
                // and each of them has a page of their own.
                if !broadcast.artists.isEmpty {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(Array(broadcast.artists.enumerated()), id: \.offset) { index, artist in
                            let slug = index < broadcast.artistSlugs.count ? broadcast.artistSlugs[index] : nil
                            Button {
                                if let slug { appState.open(.dublabDJ(slug: slug)) }
                            } label: {
                                Text(artist)
                                    .microLabel(1.1, size: 9)
                                    .foregroundStyle(slug == nil ? Palette.inkMuted : Palette.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                            }
                            .buttonStyle(.plain)
                            .disabled(slug == nil)
                        }
                    }
                }

                MediaLinkChips(links: broadcast.links)

                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if broadcast.isPlayable {
                        playButton(broadcast, large: true)
                    } else {
                        Text("No recording published")
                            .microLabel(1.2, size: 9.5)
                            .foregroundStyle(Palette.inkFaint)
                    }
                    DublabCrateButton(broadcast: broadcast)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func facts(_ broadcast: DublabBroadcast) -> String {
        [broadcast.airedLabel, broadcast.performer, "Los Angeles"]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
    }

    /// The rest of this DJ's run, once their page has been read.
    @ViewBuilder
    private func related(_ broadcast: DublabBroadcast) -> some View {
        let slug = broadcast.artistSlugs.first
        let run = slug.map { browse.broadcasts(byDJ: $0) } ?? []
        let others = run.filter { $0.slug != broadcast.slug }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(
                    broadcast.performer.map { "More from \($0)" } ?? "More from the archive",
                    trailing: nil
                )
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(others.prefix(12)) { other in
                        DublabBroadcastTile(
                            broadcast: other,
                            isCurrent: DublabPlayback.isCurrent(other, in: player),
                            isPlaying: DublabPlayback.isPlaying(other, in: player),
                            open: {
                                browse.remember([other])
                                appState.open(.dublabBroadcast(slug: other.slug))
                            },
                            play: { DublabPlayback.toggle(other, within: Array(others), using: player) }
                        )
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
        }
    }

    private func section(_ title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title, trailing: nil)
            Text(body)
                .font(Typeface.body(12.5))
                .foregroundStyle(Palette.inkMuted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 18)
        }
    }

    private func sectionHeader(_ title: String, trailing: String?) -> some View {
        VStack(spacing: 0) {
            Rule(color: Palette.outline)
            HStack {
                Text(title).microLabel(1.8)
                Spacer()
                if let trailing {
                    Text(trailing).microLabel(1.2).foregroundStyle(Palette.inkFaint)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 14)
            Rule()
        }
    }

    private func playButton(_ broadcast: DublabBroadcast, large: Bool = false) -> some View {
        let isPlaying = DublabPlayback.isPlaying(broadcast, in: player)
        return Button {
            DublabPlayback.toggle(broadcast, within: [broadcast], using: player)
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
