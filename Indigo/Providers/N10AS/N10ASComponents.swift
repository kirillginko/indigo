//
//  N10ASComponents.swift
//  Indigo
//
//  Tiles, rows and playback glue for n10.as. The station hosts no audio
//  itself — every recording is on its Mixcloud account — so a broadcast plays
//  through the embed engine rather than as a stream.
//

import SwiftUI

// MARK: - Crating

struct N10ASCrateMenu: ViewModifier {
    let episode: N10ASEpisode
    @Environment(CrateService.self) private var crate

    func body(content: Content) -> some View {
        let _ = crate.revision
        let isCrated = crate.contains(
            broadcast: episode.mediaID, providerID: N10ASProvider.providerID
        )
        return content.contextMenu {
            Button(isCrated ? "Remove from Crate" : "Add to Crate") {
                toggleN10ASCrate(episode, in: crate)
            }
        }
    }
}

struct N10ASCrateButton: View {
    let episode: N10ASEpisode
    var compact = false
    @Environment(CrateService.self) private var crate

    var body: some View {
        let _ = crate.revision
        let isCrated = crate.contains(
            broadcast: episode.mediaID, providerID: N10ASProvider.providerID
        )
        if compact {
            CrateGlyphButton(isCrated: isCrated) { toggleN10ASCrate(episode, in: crate) }
        } else {
            CrateButton(isCrated: isCrated) { toggleN10ASCrate(episode, in: crate) }
        }
    }
}

private func toggleN10ASCrate(_ episode: N10ASEpisode, in crate: CrateService) {
    if let existing = crate.item(
        forBroadcast: episode.mediaID, providerID: N10ASProvider.providerID
    ) {
        crate.remove(existing)
    } else {
        let item = episode.mediaItem()
        crate.add(
            broadcast: episode.mediaID,
            providerID: N10ASProvider.providerID,
            title: episode.title,
            subtitle: episode.broadcastLabel,
            artworkURL: episode.artworkURL,
            playbackURL: item.playbackURL,
            embedProvider: item.embedProvider,
            genres: episode.genres
        )
    }
}

extension View {
    func n10asCrateMenu(for episode: N10ASEpisode) -> some View {
        modifier(N10ASCrateMenu(episode: episode))
    }
}

// MARK: - Tiles

struct N10ASEpisodeTile: View {
    let episode: N10ASEpisode
    let isCurrent: Bool
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(
                remoteURL: episode.artworkURL,
                markURL: N10ASProvider.logoURL,
                mark: "n10.as"
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
                    .padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                // n10.as logs no tracklists anywhere, so the badge is always
                // the genre Mixcloud carries.
                if isHovering,
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
                N10ASCrateButton(episode: episode, compact: true)
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title)
                    .font(Typeface.body(12, weight: .semibold))
                    .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(episode.listSubtitle.isEmpty ? "n10.as" : episode.listSubtitle)
                    .microLabel(0.8)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .n10asCrateMenu(for: episode)
        .accessibilityLabel("Open \(episode.title)")
    }
}

struct N10ASShowTile: View {
    let show: N10ASShow
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(
                remoteURL: show.imageURL,
                markURL: N10ASProvider.logoURL,
                mark: "n10.as"
            )
            .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
            .overlay(alignment: .topLeading) {
                if isHovering, let genre = show.genres.first {
                    Text(genre)
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
                Text(show.subtitle.isEmpty ? "n10.as" : show.subtitle)
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

// MARK: - Row

struct N10ASEpisodeRow: View {
    let episode: N10ASEpisode
    let isCurrent: Bool
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) { leading }
                .buttonStyle(.plain)
                .frame(width: 26, alignment: .trailing)

            Text(episode.title)
                .font(Typeface.body(12.5, weight: isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(episode.guest.map { "w/ \($0)" } ?? episode.genres.prefix(2).joined(separator: " · "))
                .font(Typeface.body(12))
                .foregroundStyle(isCurrent ? Palette.accent.opacity(0.85) : Palette.inkMuted)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            Text(TimeFormat.clock(episode.duration))
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)

            Text(episode.broadcastLabel ?? "—")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 88, alignment: .trailing)

            N10ASCrateButton(episode: episode, compact: true)
        }
        .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
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
        .n10asCrateMenu(for: episode)
    }

    @ViewBuilder
    private var leading: some View {
        if isCurrent {
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.accent)
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
        } else if isHovering {
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
enum N10ASPlayback {
    static func toggle(
        _ episode: N10ASEpisode,
        within list: [N10ASEpisode],
        using player: PlaybackCoordinator
    ) {
        let item = episode.mediaItem()
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

    static func isCurrent(_ episode: N10ASEpisode, in player: PlaybackCoordinator) -> Bool {
        player.isCurrent(episode.mediaID)
    }

    static func isPlaying(_ episode: N10ASEpisode, in player: PlaybackCoordinator) -> Bool {
        isCurrent(episode, in: player) && player.isPlaying
    }
}
