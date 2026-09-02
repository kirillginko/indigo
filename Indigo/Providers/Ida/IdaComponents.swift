//
//  IdaComponents.swift
//  Indigo
//
//  Tiles, rows and playback glue for IDA. The station hosts no audio itself —
//  every archived episode lives on SoundCloud, with a Mixcloud copy — so an
//  episode plays through the embed engine, and the odd one IDA never uploaded
//  says so rather than failing when it is pressed.
//

import SwiftUI

// MARK: - Crating

struct IdaCrateMenu: ViewModifier {
    let episode: IdaEpisode
    @Environment(CrateService.self) private var crate

    func body(content: Content) -> some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: episode.mediaID, providerID: IdaProvider.providerID)
        return content.contextMenu {
            Button(isCrated ? "Remove from Crate" : "Add to Crate") {
                toggleIdaCrate(episode, in: crate)
            }
        }
    }
}

struct IdaCrateButton: View {
    let episode: IdaEpisode
    var compact = false
    @Environment(CrateService.self) private var crate

    var body: some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: episode.mediaID, providerID: IdaProvider.providerID)
        if compact {
            CrateGlyphButton(isCrated: isCrated) { toggleIdaCrate(episode, in: crate) }
        } else {
            CrateButton(isCrated: isCrated) { toggleIdaCrate(episode, in: crate) }
        }
    }
}

private func toggleIdaCrate(_ episode: IdaEpisode, in crate: CrateService) {
    if let existing = crate.item(forBroadcast: episode.mediaID, providerID: IdaProvider.providerID) {
        crate.remove(existing)
    } else {
        let item = episode.mediaItem()
        crate.add(
            broadcast: episode.mediaID,
            providerID: IdaProvider.providerID,
            title: episode.title,
            subtitle: episode.broadcastLabel,
            artworkURL: episode.imageURL,
            playbackURL: item?.playbackURL,
            embedProvider: item?.embedProvider,
            genres: episode.genres
        )
    }
}

extension View {
    func idaCrateMenu(for episode: IdaEpisode) -> some View {
        modifier(IdaCrateMenu(episode: episode))
    }
}

// MARK: - Tiles

struct IdaEpisodeTile: View {
    let episode: IdaEpisode
    let isCurrent: Bool
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(
                remoteURL: episode.thumbnailURL ?? episode.imageURL,
                markURL: IdaProvider.logoURL,
                mark: "IDA Radio"
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
                } else if isHovering,
                          let badge = BroadcastBadge.text(
                              tracks: episode.tracks.count,
                              genres: episode.genres
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
                IdaCrateButton(episode: episode, compact: true)
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title)
                    .font(Typeface.body(12, weight: .semibold))
                    .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(episode.listSubtitle.isEmpty ? "IDA Radio" : episode.listSubtitle)
                    .microLabel(0.8)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .idaCrateMenu(for: episode)
        .accessibilityLabel("Open \(episode.title)")
    }
}

struct IdaShowTile: View {
    let show: IdaShow
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(
                remoteURL: show.thumbnailURL ?? show.imageURL,
                markURL: IdaProvider.logoURL,
                mark: "IDA Radio"
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
            // Which studio a show comes out of is the one thing a listener
            // cannot guess from its name, and IDA runs two.
            .overlay(alignment: .bottomLeading) {
                if let city = show.channel?.city {
                    Text(city)
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
                Text(show.subtitle.isEmpty ? "IDA Radio" : show.subtitle)
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

struct IdaEpisodeRow: View {
    let episode: IdaEpisode
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
                .frame(width: 170, alignment: .leading)

            Text(TimeFormat.clock(episode.duration))
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)

            Text(episode.broadcastLabel ?? "—")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 88, alignment: .trailing)

            IdaCrateButton(episode: episode, compact: true)
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
        .idaCrateMenu(for: episode)
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
enum IdaPlayback {
    static func toggle(_ episode: IdaEpisode, within list: [IdaEpisode], using player: PlaybackCoordinator) {
        guard let item = episode.mediaItem() else { return }
        if player.isCurrent(item.id) {
            player.toggle()
            return
        }
        let queue = list.compactMap { $0.mediaItem() }
        guard let start = queue.firstIndex(where: { $0.id == item.id }) else {
            if item.isEmbedded { player.playEpisode(item) } else { player.play([item]) }
            return
        }
        player.play(queue, startingAt: start)
    }

    static func isCurrent(_ episode: IdaEpisode, in player: PlaybackCoordinator) -> Bool {
        player.isCurrent(episode.mediaID)
    }

    static func isPlaying(_ episode: IdaEpisode, in player: PlaybackCoordinator) -> Bool {
        isCurrent(episode, in: player) && player.isPlaying
    }
}
