//
//  NoodsComponents.swift
//  Indigo
//
//  Tiles and rows shared by the Noods pages. A Noods show has a tracklist, so
//  unlike a Kiosk show the tile opens a page and the play button is separate.
//

import SwiftUI

struct NoodsShowTile: View {
    let show: NoodsShow
    let isCurrent: Bool
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(remoteURL: show.artworkURL)
                .overlay(Rectangle().strokeBorder(
                    isCurrent ? Palette.accent : Palette.rule,
                    lineWidth: isCurrent ? 1.5 : Metrics.hairline
                ))
                .overlay(alignment: .topLeading) {
                    if !show.isPlayable {
                        Text("No audio")
                            .microLabel(1.1, size: 9)
                            .foregroundStyle(Palette.inkMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Palette.paper)
                            .padding(8)
                    }
                }
                // Nested so the tile opens the show and this still plays.
                .overlay(alignment: .bottomTrailing) {
                    if show.isPlayable, isHovering || isCurrent {
                        Button(action: play) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.inverseInk)
                                .frame(width: 28, height: 28)
                                .background(Palette.inverse)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPlaying ? "Pause \(show.title)" : "Play \(show.title)")
                        .padding(8)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(show.title)
                    .font(Typeface.body(12, weight: .semibold))
                    .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(show.subtitle)
                    .microLabel(0.8)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(show.title)
    }
}

struct NoodsResidentTile: View {
    let resident: NoodsResidentRef
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ArtworkView(remoteURL: resident.artworkURL)
                    .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
                    .overlay {
                        if isHovering { Rectangle().fill(Palette.inverse.opacity(0.12)) }
                    }
                Text(resident.name)
                    .font(Typeface.body(12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct NoodsCollectionTile: View {
    let collection: NoodsCollection
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ArtworkView(remoteURL: collection.artworkURL)
                    .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
                    .overlay(alignment: .topLeading) {
                        if let kind = collection.kind {
                            Text(kind)
                                .microLabel(1.1, size: 9)
                                .foregroundStyle(Palette.inverseInk)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Palette.inverse)
                                .padding(8)
                        }
                    }
                    .overlay {
                        if isHovering { Rectangle().fill(Palette.inverse.opacity(0.12)) }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(collection.title)
                        .font(Typeface.body(12, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text([collection.location, collection.airedLabel]
                        .compactMap { $0 }.joined(separator: " · "))
                        .microLabel(0.8)
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

extension NoodsCollection {
    var airedLabel: String? {
        guard let airedAt else { return rawDate }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: airedAt)
    }
}

// MARK: - Playback

@MainActor
enum NoodsPlayback {
    static func toggle(_ show: NoodsShow, within list: [NoodsShow], using player: PlaybackCoordinator) {
        guard let item = show.mediaItem() else { return }
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

    static func isCurrent(_ show: NoodsShow, in player: PlaybackCoordinator) -> Bool {
        player.isCurrent(show.mediaID)
    }

    static func isPlaying(_ show: NoodsShow, in player: PlaybackCoordinator) -> Bool {
        isCurrent(show, in: player) && player.isPlaying
    }
}

/// The show grid every Noods list page renders.
struct NoodsShowGrid: View {
    let shows: [NoodsShow]
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
            ForEach(shows) { show in
                NoodsShowTile(
                    show: show,
                    isCurrent: NoodsPlayback.isCurrent(show, in: player),
                    isPlaying: NoodsPlayback.isPlaying(show, in: player),
                    open: { appState.open(.noodsShow(path: show.path)) },
                    play: { NoodsPlayback.toggle(show, within: shows, using: player) }
                )
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}
