//
//  Radio80000Components.swift
//  Indigo
//
//  Tiles, rows and playback glue for Radio 80000. The station hosts no audio
//  itself — every recording is on SoundCloud or Mixcloud — so a broadcast
//  plays through the embed engine, and which of the two it came from is shown
//  on the tile, because it is the difference between a widget that seeks and
//  one that does not.
//

import SwiftUI

// MARK: - Crating

struct Radio80000CrateMenu: ViewModifier {
    let episode: Radio80000Episode
    @Environment(CrateService.self) private var crate

    func body(content: Content) -> some View {
        let _ = crate.revision
        let isCrated = crate.contains(
            broadcast: episode.mediaID, providerID: Radio80000Provider.providerID
        )
        return content.contextMenu {
            Button(isCrated ? "Remove from Crate" : "Add to Crate") {
                toggleRadio80000Crate(episode, in: crate)
            }
        }
    }
}

struct Radio80000CrateButton: View {
    let episode: Radio80000Episode
    var compact = false
    @Environment(CrateService.self) private var crate

    var body: some View {
        let _ = crate.revision
        let isCrated = crate.contains(
            broadcast: episode.mediaID, providerID: Radio80000Provider.providerID
        )
        if compact {
            CrateGlyphButton(isCrated: isCrated) { toggleRadio80000Crate(episode, in: crate) }
        } else {
            CrateButton(isCrated: isCrated) { toggleRadio80000Crate(episode, in: crate) }
        }
    }
}

private func toggleRadio80000Crate(_ episode: Radio80000Episode, in crate: CrateService) {
    if let existing = crate.item(
        forBroadcast: episode.mediaID, providerID: Radio80000Provider.providerID
    ) {
        crate.remove(existing)
    } else {
        let item = episode.mediaItem()
        crate.add(
            broadcast: episode.mediaID,
            providerID: Radio80000Provider.providerID,
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
    func radio80000CrateMenu(for episode: Radio80000Episode) -> some View {
        modifier(Radio80000CrateMenu(episode: episode))
    }
}

// MARK: - Tiles

struct Radio80000EpisodeTile: View {
    let episode: Radio80000Episode
    let isCurrent: Bool
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(
                remoteURL: episode.artworkURL,
                markURL: Radio80000Provider.logoURL,
                mark: "Radio 80000"
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
                if isHovering,
                   let badge = BroadcastBadge.text(
                       tracks: episode.tracks.count, genres: episode.genres
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
                Radio80000CrateButton(episode: episode, compact: true)
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title)
                    .font(Typeface.body(12, weight: .semibold))
                    .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(episode.listSubtitle.isEmpty ? "Radio 80000" : episode.listSubtitle)
                    .microLabel(0.8)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .radio80000CrateMenu(for: episode)
        .accessibilityLabel("Open \(episode.title)")
    }
}

struct Radio80000ShowTile: View {
    let show: Radio80000Show
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(
                remoteURL: show.thumbnailURL ?? show.imageURL,
                markURL: Radio80000Provider.logoURL,
                mark: "Radio 80000"
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
            // Twenty-nine shows have no recordings anywhere. Saying so on the
            // tile is the difference between a quiet page and a broken one.
            .overlay(alignment: .bottomLeading) {
                if !show.hasArchive {
                    Text("No recordings")
                        .microLabel(1.1, size: 9)
                        .foregroundStyle(Palette.inkMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Palette.paper)
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(show.title)
                    .font(Typeface.body(12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(show.subtitle.isEmpty ? "Radio 80000" : show.subtitle)
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

struct Radio80000EpisodeRow: View {
    let episode: Radio80000Episode
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

            Text(episode.genres.prefix(2).joined(separator: " · "))
                .font(Typeface.body(12))
                .foregroundStyle(isCurrent ? Palette.accent.opacity(0.85) : Palette.inkMuted)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            Text(episode.source.label)
                .microLabel(0.9)
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 76, alignment: .leading)

            Text(TimeFormat.clock(episode.duration))
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)

            Text(episode.broadcastLabel ?? "—")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 88, alignment: .trailing)

            Radio80000CrateButton(episode: episode, compact: true)
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
        .radio80000CrateMenu(for: episode)
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
enum Radio80000Playback {
    static func toggle(
        _ episode: Radio80000Episode,
        within list: [Radio80000Episode],
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

    static func isCurrent(_ episode: Radio80000Episode, in player: PlaybackCoordinator) -> Bool {
        player.isCurrent(episode.mediaID)
    }

    static func isPlaying(_ episode: Radio80000Episode, in player: PlaybackCoordinator) -> Bool {
        isCurrent(episode, in: player) && player.isPlaying
    }
}
