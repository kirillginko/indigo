//
//  AlharaComponents.swift
//  Indigo
//
//  Tiles and playback glue for alHara's archive. The recordings live on
//  Mixcloud, so they play through the same hosted widget Kiosk uses — which is
//  also what keeps the plays counted where they belong.
//

import SwiftUI

// MARK: - Crating

struct AlharaCrateMenu: ViewModifier {
    let show: AlharaShow
    @Environment(CrateService.self) private var crate

    func body(content: Content) -> some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: show.mediaID, providerID: AlharaProvider.providerID)
        return content.contextMenu {
            Button(isCrated ? "Remove from Crate" : "Add to Crate") {
                toggleAlharaCrate(show, in: crate)
            }
        }
    }
}

struct AlharaCrateButton: View {
    let show: AlharaShow
    var compact = false
    @Environment(CrateService.self) private var crate

    var body: some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: show.mediaID, providerID: AlharaProvider.providerID)
        if compact {
            CrateGlyphButton(isCrated: isCrated) { toggleAlharaCrate(show, in: crate) }
        } else {
            CrateButton(isCrated: isCrated) { toggleAlharaCrate(show, in: crate) }
        }
    }
}

private func toggleAlharaCrate(_ show: AlharaShow, in crate: CrateService) {
    if let existing = crate.item(forBroadcast: show.mediaID, providerID: AlharaProvider.providerID) {
        crate.remove(existing)
    } else {
        crate.add(
            broadcast: show.mediaID,
            providerID: AlharaProvider.providerID,
            title: show.title,
            subtitle: show.publishedLabel,
            artworkURL: show.artworkURL,
            playbackURL: show.mixcloudURL,
            embedProvider: .mixcloud,
            genres: show.genres
        )
    }
}

extension View {
    func alharaCrateMenu(for show: AlharaShow) -> some View {
        modifier(AlharaCrateMenu(show: show))
    }
}

// MARK: - Tile

struct AlharaShowTile: View {
    let show: AlharaShow
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
                        .padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isHovering, let duration = show.duration {
                        Text(TimeFormat.clock(duration))
                            .microLabel(1.1, size: 9)
                            .foregroundStyle(Palette.inverseInk)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Palette.inverse)
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    AlharaCrateButton(show: show, compact: true)
                        .padding(8)
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
        .alharaCrateMenu(for: show)
        .accessibilityLabel("Open \(show.title)")
    }
}

// MARK: - Playback

@MainActor
enum AlharaPlayback {
    static func toggle(_ show: AlharaShow, within list: [AlharaShow], using player: PlaybackCoordinator) {
        let item = show.mediaItem()
        if player.isCurrent(item.id) {
            player.toggle()
            return
        }
        let queue = list.map { $0.mediaItem() }
        guard let start = queue.firstIndex(where: { $0.id == item.id }) else {
            player.playEpisode(item)
            return
        }
        player.play(queue, startingAt: start)
    }

    static func isCurrent(_ show: AlharaShow, in player: PlaybackCoordinator) -> Bool {
        player.isCurrent(show.mediaID)
    }

    static func isPlaying(_ show: AlharaShow, in player: PlaybackCoordinator) -> Bool {
        isCurrent(show, in: player) && player.isPlaying
    }
}
