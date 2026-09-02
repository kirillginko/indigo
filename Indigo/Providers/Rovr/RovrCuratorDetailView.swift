//
//  RovrCuratorDetailView.swift
//  Indigo
//
//  One curator: who they are, where they are, and their run.
//
//  The archive can be asked for a single curator's broadcasts, so this page is
//  a real filter of ten thousand rather than whatever happened to be loaded.
//

import SwiftUI

struct RovrCuratorDetailView: View {
    let curatorID: String

    @Environment(AppState.self) private var appState
    @Environment(RovrBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let curator = browse.curator(id: curatorID)
        let broadcasts = browse.broadcasts(byCurator: curatorID)

        VStack(spacing: 0) {
            PageHeader(
                title: curator?.name ?? "Curator",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(curator, broadcasts: broadcasts)
            ) {
                if let first = broadcasts.first(where: \.isPlayable) {
                    playButton(first, queue: broadcasts)
                }
            }
            Rule(color: Palette.outline)

            if let curator {
                content(curator, broadcasts: broadcasts)
            } else if browse.isLoadingCurator(curatorID) || browse.curatorsPhase.isLoading {
                LoadingPane(label: "Loading curator")
            } else {
                EmptyStateView(
                    headline: "Curator unavailable",
                    message: browse.curatorError(curatorID) ?? "ROVR no longer lists this curator."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: curatorID) {
            async let roster: Void = browse.loadCuratorsIfNeeded()
            async let detail: Void = browse.loadCuratorIfNeeded(id: curatorID)
            _ = await (roster, detail)
        }
    }

    private func subtitle(_ curator: RovrCurator?, broadcasts: [RovrBroadcast]) -> String {
        guard curator != nil else { return "ROVR" }
        let count = broadcasts.isEmpty
            ? nil
            : "\(broadcasts.count) \(broadcasts.count == 1 ? "broadcast" : "broadcasts")"
        return [count, "ROVR"].compactMap { $0 }.joined(separator: " · ")
    }

    private func content(_ curator: RovrCurator, broadcasts: [RovrBroadcast]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(
                        remoteURL: curator.imageURL,
                        side: 300,
                        markURL: RovrProvider.logoURL,
                        mark: "ROVR"
                    )
                    .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 16) {
                        MicroLabel(text: "Curator")

                        Text(curator.name)
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        if let flag = curator.flag {
                            Text("\(flag)  \(curator.countryCode ?? "")")
                                .font(Typeface.mono(11))
                                .foregroundStyle(Palette.inkMuted)
                        }

                        if !curator.showTitles.isEmpty {
                            WrapLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(curator.showTitles, id: \.self) { TagChip(text: $0) }
                            }
                        }

                        if let about = curator.about {
                            Text(about)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        MediaLinkChips(links: curator.links)

                        Spacer(minLength: 0)
                        if let first = broadcasts.first(where: \.isPlayable) {
                            playButton(first, queue: broadcasts, large: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)

                broadcastList(broadcasts)
            }
        }
        .scrollIndicators(.visible)
    }

    @ViewBuilder
    private func broadcastList(_ broadcasts: [RovrBroadcast]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                Rule(color: Palette.outline)
                HStack {
                    Text("Broadcasts").microLabel(1.8)
                    Spacer()
                    if !broadcasts.isEmpty {
                        Text("Newest first").microLabel(1.2).foregroundStyle(Palette.inkFaint)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                Rule()
            }

            if broadcasts.isEmpty {
                Text(browse.isLoadingCurator(curatorID)
                     ? "Loading broadcasts…"
                     : "Nothing archived under this curator yet.")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                    .background(Palette.wash)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(broadcasts) { broadcast in
                        RovrBroadcastRow(
                            broadcast: broadcast,
                            isCurrent: RovrPlayback.isCurrent(broadcast, in: player),
                            isPlaying: RovrPlayback.isPlaying(broadcast, in: player),
                            open: {
                                browse.remember([broadcast])
                                appState.open(.rovrBroadcast(id: broadcast.documentID))
                            },
                            play: {
                                RovrPlayback.toggle(broadcast, within: broadcasts, using: player)
                            }
                        )
                        Rule()
                    }
                }
            }
        }
    }

    private func playButton(
        _ broadcast: RovrBroadcast,
        queue: [RovrBroadcast],
        large: Bool = false
    ) -> some View {
        let isPlaying = RovrPlayback.isPlaying(broadcast, in: player)
        return Button {
            RovrPlayback.toggle(broadcast, within: queue, using: player)
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
