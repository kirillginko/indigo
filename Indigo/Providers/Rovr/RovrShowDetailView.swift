//
//  RovrShowDetailView.swift
//  Indigo
//
//  One show: what it is, who makes it, and its run.
//
//  The archive can be asked for a single show's broadcasts, so the list below
//  is a real filter of ten thousand rather than whatever the archive page
//  happened to have loaded when you came through it.
//

import SwiftUI

struct RovrShowDetailView: View {
    let showID: String

    @Environment(AppState.self) private var appState
    @Environment(RovrBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let show = browse.show(id: showID)
        let broadcasts = browse.broadcasts(ofShow: showID)

        VStack(spacing: 0) {
            PageHeader(
                title: show?.title ?? "Show",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(show, broadcasts: broadcasts)
            ) {
                if let first = broadcasts.first(where: \.isPlayable) {
                    playButton(first, queue: broadcasts)
                }
            }
            Rule(color: Palette.outline)

            if let show {
                content(show, broadcasts: broadcasts)
            } else if browse.isLoadingShow(showID) || browse.showsPhase.isLoading {
                LoadingPane(label: "Loading show")
            } else {
                EmptyStateView(
                    headline: "Show unavailable",
                    message: browse.showError(showID) ?? "ROVR no longer lists this show."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task(id: showID) {
            async let roster: Void = browse.loadShowsIfNeeded()
            async let detail: Void = browse.loadShowIfNeeded(id: showID)
            _ = await (roster, detail)
        }
    }

    private func subtitle(_ show: RovrShow?, broadcasts: [RovrBroadcast]) -> String {
        guard let show else { return "ROVR" }
        let count = broadcasts.isEmpty
            ? nil
            : "\(broadcasts.count) \(broadcasts.count == 1 ? "broadcast" : "broadcasts")"
        return [count, show.frequency?.capitalized, "ROVR"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func content(_ show: RovrShow, broadcasts: [RovrBroadcast]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(
                        remoteURL: show.imageURL ?? show.thumbnailURL,
                        side: 300,
                        markURL: RovrProvider.logoURL,
                        mark: "ROVR"
                    )
                    .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 16) {
                        MicroLabel(text: show.isCommunityRadio ? "Community radio" : "Show")

                        Text(show.title)
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        if let frequency = show.frequency {
                            Text(frequency.capitalized)
                                .font(Typeface.mono(11))
                                .foregroundStyle(Palette.inkMuted)
                        }

                        // A show's curators are people with pages of their own,
                        // so they are a way through rather than a label.
                        if !show.curators.isEmpty {
                            WrapLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(show.curators, id: \.self) { name in
                                    if let curator = curator(named: name) {
                                        Button {
                                            appState.open(.rovrCurator(id: curator.documentID))
                                        } label: {
                                            TagChip(text: name)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        TagChip(text: name)
                                    }
                                }
                            }
                        }

                        if let summary = show.summary {
                            Text(summary)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }

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

    /// The roster knows a curator's id; a show only names them.
    private func curator(named name: String) -> RovrCurator? {
        browse.curators.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
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
                Text(browse.isLoadingShow(showID)
                     ? "Loading broadcasts…"
                     : "Nothing archived under this show yet.")
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
