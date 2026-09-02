//
//  PanikComponents.swift
//  Indigo
//
//  Tiles, rows and playback glue for Radio Panik. The station hosts its own
//  recordings and publishes the address of each one, so a broadcast plays
//  through the same engine a local file does — seekable, with a real duration,
//  and no widget in the way.
//

import SwiftUI

// MARK: - Crating

struct PanikCrateMenu: ViewModifier {
    let episode: PanikEpisode
    @Environment(CrateService.self) private var crate

    func body(content: Content) -> some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: episode.mediaID, providerID: PanikProvider.providerID)
        return content.contextMenu {
            Button(isCrated ? "Remove from Crate" : "Add to Crate") {
                togglePanikCrate(episode, in: crate)
            }
        }
    }
}

struct PanikCrateButton: View {
    let episode: PanikEpisode
    var compact = false
    @Environment(CrateService.self) private var crate

    var body: some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: episode.mediaID, providerID: PanikProvider.providerID)
        if compact {
            CrateGlyphButton(isCrated: isCrated) { togglePanikCrate(episode, in: crate) }
        } else {
            CrateButton(isCrated: isCrated) { togglePanikCrate(episode, in: crate) }
        }
    }
}

private func togglePanikCrate(_ episode: PanikEpisode, in crate: CrateService) {
    if let existing = crate.item(forBroadcast: episode.mediaID, providerID: PanikProvider.providerID) {
        crate.remove(existing)
    } else {
        let item = episode.mediaItem()
        crate.add(
            broadcast: episode.mediaID,
            providerID: PanikProvider.providerID,
            title: episode.title,
            subtitle: episode.broadcastLabel,
            artworkURL: episode.imageURL,
            playbackURL: item?.playbackURL,
            embedProvider: nil,
            genres: []
        )
    }
}

extension View {
    func panikCrateMenu(for episode: PanikEpisode) -> some View {
        modifier(PanikCrateMenu(episode: episode))
    }
}

// MARK: - Tiles

struct PanikEpisodeTile: View {
    let episode: PanikEpisode
    let isCurrent: Bool
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(
                remoteURL: episode.imageURL,
                markURL: PanikProvider.logoURL,
                mark: "Radio Panik"
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
                } else if isHovering, let duration = episode.duration {
                    Text(TimeFormat.clock(duration))
                        .microLabel(1.1, size: 9)
                        .foregroundStyle(Palette.inverseInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Palette.inverse)
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                PanikCrateButton(episode: episode, compact: true)
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title)
                    .font(Typeface.body(12, weight: .semibold))
                    .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(episode.listSubtitle.isEmpty ? "Radio Panik" : episode.listSubtitle)
                    .microLabel(0.8)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .panikCrateMenu(for: episode)
        .accessibilityLabel("Open \(episode.title)")
    }
}

struct PanikShowTile: View {
    let show: PanikShow
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(
                remoteURL: show.imageURL,
                markURL: PanikProvider.logoURL,
                mark: "Radio Panik"
            )
            .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
            .overlay(alignment: .topLeading) {
                if isHovering, let category = show.categories.first {
                    Text(category)
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
                Text(show.subtitle.isEmpty ? "Radio Panik" : show.subtitle)
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

struct PanikEpisodeRow: View {
    let episode: PanikEpisode
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

            Text(TimeFormat.clock(episode.duration))
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)

            Text(episode.broadcastLabel ?? "—")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 88, alignment: .trailing)

            PanikCrateButton(episode: episode, compact: true)
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
        .panikCrateMenu(for: episode)
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
enum PanikPlayback {
    static func toggle(
        _ episode: PanikEpisode,
        within list: [PanikEpisode],
        using player: PlaybackCoordinator
    ) {
        guard let item = episode.mediaItem() else { return }
        if player.isCurrent(item.id) {
            player.toggle()
            return
        }
        let queue = list.compactMap { $0.mediaItem() }
        guard let start = queue.firstIndex(where: { $0.id == item.id }) else {
            player.play([item])
            return
        }
        player.play(queue, startingAt: start)
    }

    static func isCurrent(_ episode: PanikEpisode, in player: PlaybackCoordinator) -> Bool {
        player.isCurrent(episode.mediaID)
    }

    static func isPlaying(_ episode: PanikEpisode, in player: PlaybackCoordinator) -> Bool {
        isCurrent(episode, in: player) && player.isPlaying
    }
}
