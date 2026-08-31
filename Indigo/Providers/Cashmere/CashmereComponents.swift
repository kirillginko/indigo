//
//  CashmereComponents.swift
//  Indigo
//
//  Tiles, rows and playback glue for Cashmere. The station archives to
//  Mixcloud, so an episode plays through the same hosted widget Kiosk uses.
//

import SwiftUI

// MARK: - Crating

struct CashmereCrateMenu: ViewModifier {
    let episode: CashmereEpisode
    @Environment(CrateService.self) private var crate

    func body(content: Content) -> some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: episode.mediaID, providerID: CashmereProvider.providerID)
        return content.contextMenu {
            Button(isCrated ? "Remove from Crate" : "Add to Crate") {
                toggleCashmereCrate(episode, in: crate)
            }
        }
    }
}

struct CashmereCrateButton: View {
    let episode: CashmereEpisode
    var compact = false
    @Environment(CrateService.self) private var crate

    var body: some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: episode.mediaID, providerID: CashmereProvider.providerID)
        if compact {
            CrateGlyphButton(isCrated: isCrated) { toggleCashmereCrate(episode, in: crate) }
        } else {
            CrateButton(isCrated: isCrated) { toggleCashmereCrate(episode, in: crate) }
        }
    }
}

private func toggleCashmereCrate(_ episode: CashmereEpisode, in crate: CrateService) {
    if let existing = crate.item(forBroadcast: episode.mediaID, providerID: CashmereProvider.providerID) {
        crate.remove(existing)
    } else {
        crate.add(
            broadcast: episode.mediaID,
            providerID: CashmereProvider.providerID,
            title: episode.title,
            subtitle: episode.airedLabel,
            artworkURL: episode.artworkURL,
            playbackURL: episode.mixcloudURL,
            embedProvider: .mixcloud,
            genres: episode.genres
        )
    }
}

extension View {
    func cashmereCrateMenu(for episode: CashmereEpisode) -> some View {
        modifier(CashmereCrateMenu(episode: episode))
    }
}

// MARK: - Tiles

struct CashmereEpisodeTile: View {
    let episode: CashmereEpisode
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
                        .disabled(!episode.isPlayable)
                        .padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !episode.isPlayable {
                        Text("No recording")
                            .microLabel(1.1, size: 9)
                            .foregroundStyle(Palette.inkMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Palette.paper)
                            .padding(8)
                    } else if isHovering,
                              let badge = BroadcastBadge.text(
                                  tracks: 0,
                                  genres: episode.genres + episode.moods
                              ) {
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
                    CashmereCrateButton(episode: episode, compact: true)
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
        .cashmereCrateMenu(for: episode)
        .accessibilityLabel("Open \(episode.title)")
    }
}

struct CashmereShowTile: View {
    let show: CashmereShow
    let open: () -> Void

    @Environment(CashmereBrowseStore.self) private var browse
    @State private var isHovering = false

    var body: some View {
        // The show itself has neither a picture nor genres; one of its
        // episodes has both.
        let preview = browse.preview(forShow: show.slug)
        return VStack(alignment: .leading, spacing: 9) {
            ArtworkView(
                remoteURL: preview?.artworkURL,
                markURL: CashmereProvider.logoURL,
                mark: "Cashmere Radio"
            )
                .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
                .overlay(alignment: .topLeading) {
                    if isHovering,
                       let badge = BroadcastBadge.text(
                           tracks: 0,
                           genres: (preview?.genres ?? []) + (preview?.moods ?? [])
                       ) {
                        Text(badge)
                            .microLabel(1.1, size: 9)
                            .foregroundStyle(Palette.inverseInk)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Palette.inverse)
                            .padding(8)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(show.name)
                    .font(Typeface.body(12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(show.episodeCount) \(show.episodeCount == 1 ? "episode" : "episodes")")
                    .microLabel(0.8)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .task { await browse.loadShowPreviewIfNeeded(slug: show.slug) }
        .accessibilityLabel("Open \(show.name)")
    }
}

// MARK: - Row

struct CashmereEpisodeRow: View {
    let episode: CashmereEpisode
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
                .frame(width: 190, alignment: .leading)

            Text(episode.airedLabel ?? "—")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 88, alignment: .trailing)

            CashmereCrateButton(episode: episode, compact: true)
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
        .cashmereCrateMenu(for: episode)
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
            Image(systemName: "waveform")
                .font(.system(size: 9))
                .foregroundStyle(Palette.inkFaint)
        }
    }
}

// MARK: - Playback

@MainActor
enum CashmerePlayback {
    static func toggle(
        _ episode: CashmereEpisode,
        within list: [CashmereEpisode],
        using player: PlaybackCoordinator
    ) {
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

    static func isCurrent(_ episode: CashmereEpisode, in player: PlaybackCoordinator) -> Bool {
        player.isCurrent(episode.mediaID)
    }

    static func isPlaying(_ episode: CashmereEpisode, in player: PlaybackCoordinator) -> Bool {
        isCurrent(episode, in: player) && player.isPlaying
    }
}
