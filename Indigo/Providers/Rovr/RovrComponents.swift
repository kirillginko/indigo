//
//  RovrComponents.swift
//  Indigo
//
//  Tiles, rows and playback glue for ROVR. The station keeps its archive on
//  SoundCloud, so broadcasts use the station’s embed URL and retain its
//  private-track token when saved to the crate.
//

import SwiftUI

// MARK: - Crating

struct RovrCrateMenu: ViewModifier {
    let broadcast: RovrBroadcast
    @Environment(CrateService.self) private var crate

    func body(content: Content) -> some View {
        let _ = crate.revision
        let isCrated = crate.contains(
            broadcast: broadcast.mediaID, providerID: RovrProvider.providerID
        )
        return content.contextMenu {
            Button(isCrated ? "Remove from Crate" : "Add to Crate") {
                toggleRovrCrate(broadcast, in: crate)
            }
        }
    }
}

struct RovrCrateButton: View {
    let broadcast: RovrBroadcast
    var compact = false
    @Environment(CrateService.self) private var crate

    var body: some View {
        let _ = crate.revision
        let isCrated = crate.contains(
            broadcast: broadcast.mediaID, providerID: RovrProvider.providerID
        )
        if compact {
            CrateGlyphButton(isCrated: isCrated) { toggleRovrCrate(broadcast, in: crate) }
        } else {
            CrateButton(isCrated: isCrated) { toggleRovrCrate(broadcast, in: crate) }
        }
    }
}

private func toggleRovrCrate(_ broadcast: RovrBroadcast, in crate: CrateService) {
    if let existing = crate.item(
        forBroadcast: broadcast.mediaID, providerID: RovrProvider.providerID
    ) {
        crate.remove(existing)
    } else {
        let item = broadcast.mediaItem()
        crate.add(
            broadcast: broadcast.mediaID,
            providerID: RovrProvider.providerID,
            title: broadcast.title,
            subtitle: broadcast.broadcastLabel,
            artworkURL: broadcast.imageURL,
            playbackURL: item?.playbackURL,
            embedProvider: item?.embedProvider,
            genres: broadcast.tags
        )
    }
}

extension View {
    func rovrCrateMenu(for broadcast: RovrBroadcast) -> some View {
        modifier(RovrCrateMenu(broadcast: broadcast))
    }
}

// MARK: - Tiles

struct RovrBroadcastTile: View {
    let broadcast: RovrBroadcast
    let isCurrent: Bool
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(
                remoteURL: broadcast.thumbnailURL ?? broadcast.imageURL,
                markURL: RovrProvider.logoURL,
                mark: "ROVR"
            )
            .overlay(Rectangle().strokeBorder(
                isCurrent ? Palette.accent : Palette.rule,
                lineWidth: isCurrent ? 1.5 : Metrics.hairline
            ))
            .overlay(alignment: .bottomTrailing) {
                if isHovering || isCurrent {
                    Button(action: play) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.inverseInk)
                            .frame(width: 28, height: 28)
                            .background(Palette.inverse)
                    }
                    .buttonStyle(.plain)
                    .disabled(!broadcast.isPlayable)
                    .padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                if !broadcast.isPlayable {
                    Text("No recording")
                        .microLabel(1.1, size: 9)
                        .foregroundStyle(Palette.inkMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Palette.paper)
                        .padding(8)
                } else if isHovering, let tag = broadcast.tags.first {
                    Text(tag)
                        .microLabel(1.1, size: 9)
                        .foregroundStyle(Palette.inverseInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Palette.inverse)
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                RovrCrateButton(broadcast: broadcast, compact: true)
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(broadcast.title)
                    .font(Typeface.body(12, weight: .semibold))
                    .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(broadcast.listSubtitle.isEmpty ? "ROVR" : broadcast.listSubtitle)
                    .microLabel(0.8)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .rovrCrateMenu(for: broadcast)
        .accessibilityLabel("Open \(broadcast.title)")
    }
}

struct RovrShowTile: View {
    let show: RovrShow
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(
                remoteURL: show.thumbnailURL ?? show.imageURL,
                markURL: RovrProvider.logoURL,
                mark: "ROVR"
            )
            .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
            .overlay(alignment: .topLeading) {
                if isHovering, let frequency = show.frequency {
                    Text(frequency)
                        .microLabel(1.1, size: 9)
                        .foregroundStyle(Palette.inverseInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Palette.inverse)
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(show.title)
                    .font(Typeface.body(12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(show.subtitle.isEmpty ? "ROVR" : show.subtitle)
                    .microLabel(0.8)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Open \(show.title)")
    }
}

struct RovrCuratorTile: View {
    let curator: RovrCurator
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(
                remoteURL: curator.thumbnailURL ?? curator.imageURL,
                markURL: RovrProvider.logoURL,
                mark: "ROVR"
            )
            .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
            .overlay(alignment: .topLeading) {
                if let flag = curator.flag {
                    Text(flag)
                        .font(.system(size: 13))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Palette.paper)
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(curator.name)
                    .font(Typeface.body(12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(curator.showTitles.first ?? "ROVR")
                    .microLabel(0.8)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Open \(curator.name)")
    }
}

// MARK: - Row

struct RovrBroadcastRow: View {
    let broadcast: RovrBroadcast
    let isCurrent: Bool
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) { leading }
                .buttonStyle(.plain)
                .disabled(!broadcast.isPlayable)
                .frame(width: 26, alignment: .trailing)

            Text(broadcast.title)
                .font(Typeface.body(12.5, weight: isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(broadcast.tags.prefix(2).joined(separator: " · "))
                .font(Typeface.body(12))
                .foregroundStyle(isCurrent ? Palette.accent.opacity(0.85) : Palette.inkMuted)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            Text(TimeFormat.clock(broadcast.duration))
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)

            Text(broadcast.broadcastLabel ?? "—")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 88, alignment: .trailing)

            RovrCrateButton(broadcast: broadcast, compact: true)
        }
        .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
        .opacity(broadcast.isPlayable ? 1 : 0.45)
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.rowHeight)
        .background(isHovering ? Palette.wash : Color.clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Palette.accent)
                .frame(width: 2)
                .opacity(isCurrent ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .rovrCrateMenu(for: broadcast)
    }

    @ViewBuilder
    private var leading: some View {
        if isCurrent {
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.accent)
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
        } else if isHovering, broadcast.isPlayable {
            Image(systemName: "play.fill")
                .font(.system(size: 8.5))
                .foregroundStyle(Palette.ink)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: 9))
                .foregroundStyle(Palette.inkFaint)
        }
    }
}

// MARK: - Playback

@MainActor
enum RovrPlayback {
    static func toggle(
        _ broadcast: RovrBroadcast,
        within list: [RovrBroadcast],
        using player: PlaybackCoordinator
    ) {
        guard let item = broadcast.mediaItem() else { return }
        if player.isCurrent(item.id) {
            player.toggle()
            return
        }
        let queue = list.compactMap { $0.mediaItem() }
        guard let start = queue.firstIndex(where: { $0.id == item.id }) else {
            player.playEpisode(item)
            return
        }
        player.play(queue, startingAt: start)
    }

    static func isCurrent(_ broadcast: RovrBroadcast, in player: PlaybackCoordinator) -> Bool {
        player.isCurrent(broadcast.mediaID)
    }

    static func isPlaying(_ broadcast: RovrBroadcast, in player: PlaybackCoordinator) -> Bool {
        isCurrent(broadcast, in: player) && player.isPlaying
    }
}
