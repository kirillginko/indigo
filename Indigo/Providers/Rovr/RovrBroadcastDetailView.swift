//
//  RovrBroadcastDetailView.swift
//  Indigo
//
//  The expanded page for one broadcast: what it is, who made it, and the rest
//  of their run.
//
//  ROVR publishes no tracklists, so there is no panel promising one. What it
//  does publish is the curator, and that is the thread worth following here.
//

import SwiftUI

struct RovrBroadcastDetailView: View {
    let broadcastID: String

    @Environment(AppState.self) private var appState
    @Environment(RovrBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let broadcast = browse.broadcast(id: broadcastID)

        VStack(spacing: 0) {
            PageHeader(
                title: broadcast?.title ?? "ROVR",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: [broadcast?.broadcastLabel, broadcast?.curatorName ?? "ROVR"]
                    .compactMap { $0 }.joined(separator: " · ")
            ) {
                if let broadcast {
                    HStack(spacing: 10) {
                        if broadcast.isPlayable { playButton(broadcast) }
                        RovrCrateButton(broadcast: broadcast)
                    }
                }
            }
            Rule(color: Palette.outline)

            if let broadcast {
                content(broadcast)
            } else if browse.isLoadingDetail(broadcastID) {
                LoadingPane(label: "Loading broadcast")
            } else {
                EmptyStateView(
                    headline: "Broadcast unavailable",
                    message: browse.detailError(broadcastID)
                        ?? "ROVR no longer publishes this broadcast."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: broadcastID) {
            await browse.loadDetailIfNeeded(id: broadcastID)
            guard let id = browse.broadcast(id: broadcastID)?.curatorID else { return }
            await browse.loadCuratorIfNeeded(id: id)
        }
    }

    private func content(_ broadcast: RovrBroadcast) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(broadcast)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                related(broadcast)
            }
        }
        .scrollIndicators(.visible)
    }

    private func hero(_ broadcast: RovrBroadcast) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkView(
                remoteURL: broadcast.imageURL,
                side: 300,
                markURL: RovrProvider.logoURL,
                mark: "ROVR"
            )
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 16) {
                if let show = broadcast.showTitle, let id = broadcast.showID {
                    Button { appState.open(.rovrShow(id: id)) } label: {
                        Text(show).microLabel(1.8).foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    MicroLabel(text: broadcast.showTitle ?? "ROVR")
                }

                Text(broadcast.title)
                    .font(Typeface.display(30))
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)

                if let curator = broadcast.curatorName, let id = broadcast.curatorID {
                    Button { appState.open(.rovrCurator(id: id)) } label: {
                        Text(curator)
                            .font(Typeface.body(12.5))
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                }

                Text(facts(broadcast))
                    .font(Typeface.mono(11))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if !broadcast.tags.isEmpty {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(broadcast.tags, id: \.self) { TagChip(text: $0) }
                    }
                }

                if let summary = broadcast.summary {
                    Text(summary)
                        .font(Typeface.body(12.5))
                        .foregroundStyle(Palette.inkMuted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if broadcast.isPlayable {
                        playButton(broadcast, large: true)
                    } else {
                        Text("No recording published")
                            .microLabel(1.2, size: 9.5)
                            .foregroundStyle(Palette.inkFaint)
                    }
                    RovrCrateButton(broadcast: broadcast)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func facts(_ broadcast: RovrBroadcast) -> String {
        [
            broadcast.broadcastLabel,
            broadcast.duration.map { TimeFormat.clock($0) },
            broadcast.episodeNumber.map { "Episode \($0)" }
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func related(_ broadcast: RovrBroadcast) -> some View {
        let siblings = (broadcast.curatorID.map { browse.broadcasts(byCurator: $0) } ?? [])
            .filter { $0.documentID != broadcast.documentID }
        if !siblings.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    Rule(color: Palette.outline)
                    HStack {
                        Text(broadcast.curatorName.map { "More from \($0)" } ?? "More broadcasts")
                            .microLabel(1.8)
                        Spacer()
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 14)
                    Rule()
                }
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(siblings.prefix(12)) { other in
                        RovrBroadcastTile(
                            broadcast: other,
                            isCurrent: RovrPlayback.isCurrent(other, in: player),
                            isPlaying: RovrPlayback.isPlaying(other, in: player),
                            open: {
                                browse.remember([other])
                                appState.open(.rovrBroadcast(id: other.documentID))
                            },
                            play: {
                                RovrPlayback.toggle(other, within: Array(siblings), using: player)
                            }
                        )
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
        }
    }

    private func playButton(_ broadcast: RovrBroadcast, large: Bool = false) -> some View {
        let isPlaying = RovrPlayback.isPlaying(broadcast, in: player)
        return Button {
            RovrPlayback.toggle(broadcast, within: [broadcast], using: player)
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
