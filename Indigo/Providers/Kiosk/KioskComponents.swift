//
//  KioskComponents.swift
//  Indigo
//
//  Tiles and rows shared by the Kiosk browse pages. Kiosk publishes no
//  tracklists, so a show is something you play rather than open — the tile
//  itself is the play button.
//

import SwiftUI

// MARK: - Crating

/// Kiosk shows are crated as broadcasts — the whole set, not a track inside
/// it. Unlike playback, keeping a show does not require its audio to remain
/// available, so an archive entry can always be saved.
struct KioskCrateMenu: ViewModifier {
    let episode: KioskEpisode
    @Environment(CrateService.self) private var crate

    func body(content: Content) -> some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: episode.mediaID, providerID: KioskProvider.providerID)
        return content.contextMenu {
            Button(isCrated ? "Remove from Crate" : "Add to Crate") {
                toggleKioskCrate(episode, in: crate)
            }
        }
    }
}

struct KioskCrateButton: View {
    let episode: KioskEpisode
    var compact = false
    @Environment(CrateService.self) private var crate

    var body: some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: episode.mediaID, providerID: KioskProvider.providerID)
        if compact {
            CrateGlyphButton(isCrated: isCrated) { toggleKioskCrate(episode, in: crate) }
        } else {
            CrateButton(isCrated: isCrated) { toggleKioskCrate(episode, in: crate) }
        }
    }
}

private func toggleKioskCrate(_ episode: KioskEpisode, in crate: CrateService) {
    if let existing = crate.item(forBroadcast: episode.mediaID, providerID: KioskProvider.providerID) {
        crate.remove(existing)
    } else {
        crate.add(
            broadcast: episode.mediaID,
            providerID: KioskProvider.providerID,
            title: episode.title,
            subtitle: episode.airedLabel,
            artworkURL: episode.artworkURL,
            playbackURL: episode.audio?.url,
            embedProvider: episode.audio?.provider,
            genres: episode.genres
        )
    }
}

extension View {
    func kioskCrateMenu(for episode: KioskEpisode) -> some View {
        modifier(KioskCrateMenu(episode: episode))
    }
}

// MARK: - Tile

struct KioskEpisodeTile: View {
    let episode: KioskEpisode
    let isCurrent: Bool
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
                ArtworkView(remoteURL: episode.artworkURL)
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
                        if !episode.isPlayable {
                            Text("No audio")
                                .microLabel(1.1, size: 9)
                                .foregroundStyle(Palette.inkMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Palette.paper)
                                .padding(8)
                        } else if isHovering,
                                  // Kiosk publishes no tracklists, but it tags
                                  // every broadcast by genre.
                                  let badge = BroadcastBadge.text(tracks: 0, genres: episode.genres) {
                            Text(badge)
                                .microLabel(1.1, size: 9)
                                .foregroundStyle(Palette.inverseInk)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Palette.inverse)
                                .padding(8)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        KioskCrateButton(episode: episode, compact: true)
                            .padding(8)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title)
                        .font(Typeface.body(12, weight: .semibold))
                        .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(episode.subtitle)
                        .microLabel(0.8)
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .kioskCrateMenu(for: episode)
        .accessibilityLabel("Open \(episode.title)")
    }
}

// MARK: - Row

/// Used inside a mood, where the playlist reads as a running order.
struct KioskEpisodeRow: View {
    let index: Int
    let episode: KioskEpisode
    let isCurrent: Bool
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
                Button(action: play) { leading }
                    .buttonStyle(.plain)
                    .disabled(!episode.isPlayable)
                    .frame(width: 26, alignment: .trailing)

                Text(episode.title)
                    .font(Typeface.body(12.5, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(episode.genres.prefix(2).joined(separator: " · "))
                    .font(Typeface.body(12))
                    .foregroundStyle(isCurrent ? Palette.accent.opacity(0.85) : Palette.inkMuted)
                    .lineLimit(1)
                    .frame(width: 200, alignment: .leading)

                Text(episode.airedLabel ?? "—")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(width: 88, alignment: .trailing)

                KioskCrateButton(episode: episode, compact: true)
            }
            .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
            .opacity(episode.isPlayable ? 1 : 0.45)
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
        .kioskCrateMenu(for: episode)
    }

    @ViewBuilder
    private var leading: some View {
        if isCurrent {
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.accent)
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
        } else if isHovering, episode.isPlayable {
            Image(systemName: "play.fill")
                .font(.system(size: 8.5))
                .foregroundStyle(Palette.ink)
        } else {
            Text("\(index)")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
        }
    }
}

// MARK: - Playback

/// Kiosk pages all start playback the same way: play this show, or toggle it
/// if it is already the loaded one, with the surrounding list as the queue.
@MainActor
enum KioskPlayback {
    static func toggle(_ episode: KioskEpisode, within list: [KioskEpisode], using player: PlaybackCoordinator) {
        guard let item = episode.mediaItem() else { return }
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

    static func isCurrent(_ episode: KioskEpisode, in player: PlaybackCoordinator) -> Bool {
        player.isCurrent(episode.mediaID)
    }

    static func isPlaying(_ episode: KioskEpisode, in player: PlaybackCoordinator) -> Bool {
        isCurrent(episode, in: player) && player.isPlaying
    }
}
