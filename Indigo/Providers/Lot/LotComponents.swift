//
//  LotComponents.swift
//  Indigo
//
//  Tiles, rows and playback glue shared by the Lot pages. Unlike Kiosk and
//  NTS, the Lot archives to plain HLS rather than to somebody's widget, so a
//  broadcast plays through the same engine a local file does: seekable, with
//  a real duration, and a tracklist that can be jumped into.
//

import SwiftUI

// MARK: - Crating

/// Lot broadcasts are crated as broadcasts — the whole set, not a track inside
/// it. Keeping one does not require its recording to remain available, so an
/// archive entry can always be saved.
struct LotCrateMenu: ViewModifier {
    let episode: LotEpisode
    @Environment(CrateService.self) private var crate

    func body(content: Content) -> some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: episode.mediaID, providerID: LotProvider.providerID)
        return content.contextMenu {
            Button(isCrated ? "Remove from Crate" : "Add to Crate") {
                toggleLotCrate(episode, in: crate)
            }
        }
    }
}

struct LotCrateButton: View {
    let episode: LotEpisode
    var compact = false
    @Environment(CrateService.self) private var crate

    var body: some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: episode.mediaID, providerID: LotProvider.providerID)
        if compact {
            CrateGlyphButton(isCrated: isCrated) { toggleLotCrate(episode, in: crate) }
        } else {
            CrateButton(isCrated: isCrated) { toggleLotCrate(episode, in: crate) }
        }
    }
}

private func toggleLotCrate(_ episode: LotEpisode, in crate: CrateService) {
    if let existing = crate.item(forBroadcast: episode.mediaID, providerID: LotProvider.providerID) {
        crate.remove(existing)
    } else {
        crate.add(
            broadcast: episode.mediaID,
            providerID: LotProvider.providerID,
            title: episode.title,
            subtitle: episode.airedLabel,
            artworkURL: episode.artworkURL,
            playbackURL: episode.streamURL,
            embedProvider: nil,
            genres: episode.genreNames
        )
    }
}

extension View {
    func lotCrateMenu(for episode: LotEpisode) -> some View {
        modifier(LotCrateMenu(episode: episode))
    }
}

// MARK: - Tiles

struct LotEpisodeTile: View {
    let episode: LotEpisode
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
                    } else if !episode.tracklist.isEmpty, isHovering {
                        Text("\(episode.tracklist.count) tracks")
                            .microLabel(1.1, size: 9)
                            .foregroundStyle(Palette.inverseInk)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Palette.inverse)
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    LotCrateButton(episode: episode, compact: true)
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
        .lotCrateMenu(for: episode)
        .accessibilityLabel("Open \(episode.title)")
    }
}

struct LotShowTile: View {
    let show: LotShow
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(remoteURL: show.photoURL)
                .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
                .overlay(alignment: .topLeading) {
                    if isHovering, let line = show.genreLine {
                        Text(line)
                            .microLabel(1.1, size: 9)
                            .foregroundStyle(Palette.inverseInk)
                            .lineLimit(1)
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
                Text(show.artistLine ?? "The Lot Radio")
                    .microLabel(0.8)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Open \(show.name)")
    }
}

// MARK: - Rows

/// Used where a residency reads as a running order rather than a grid.
struct LotEpisodeRow: View {
    let episode: LotEpisode
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

            Text(episode.genreNames.prefix(2).joined(separator: " · "))
                .font(Typeface.body(12))
                .foregroundStyle(isCurrent ? Palette.accent.opacity(0.85) : Palette.inkMuted)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            Text(episode.tracklist.isEmpty ? "—" : "\(episode.tracklist.count)")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 34, alignment: .trailing)

            Text(TimeFormat.clock(episode.duration))
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)

            Text(episode.airedLabel ?? "—")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 88, alignment: .trailing)

            LotCrateButton(episode: episode, compact: true)
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
        .lotCrateMenu(for: episode)
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

/// One logged track. The Lot stamps its tracklists with wall-clock times, so
/// every line knows where in the recording it starts — which makes the line
/// itself a seek.
struct LotTrackRow: View {
    let track: LotTrack
    let isPlayable: Bool
    let seek: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(track.index)")
                .font(Typeface.mono(9.5))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(Typeface.body(12.5, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let artist = track.artist {
                    Text(artist)
                        .font(Typeface.body(12))
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let label = track.offsetLabel {
                Text(isHovering && isPlayable ? "Play from" : label)
                    .font(isHovering && isPlayable ? Typeface.micro(9) : Typeface.mono(10))
                    .textCase(isHovering && isPlayable ? .uppercase : nil)
                    .foregroundStyle(isHovering && isPlayable ? Palette.accent : Palette.inkFaint)
                    .monospacedDigit()
                    .frame(width: 78, alignment: .trailing)
            } else {
                Text("—")
                    .font(Typeface.mono(10))
                    .foregroundStyle(Palette.inkFaint)
                    .frame(width: 78, alignment: .trailing)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 8)
        .frame(minHeight: Metrics.rowHeight)
        .background(isHovering && canSeek ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if canSeek { seek() } }
    }

    private var canSeek: Bool { isPlayable && track.offset != nil }
}

/// Where else an artist can be heard. Rendered as chips because the Lot lists
/// between none and six of them and a column of full URLs reads as noise.
struct MediaLinkChips: View {
    let links: [MediaLink]

    var body: some View {
        if !links.isEmpty {
            WrapLayout(spacing: 6, lineSpacing: 6) {
                ForEach(links) { link in
                    Link(destination: link.url) {
                        Text(link.label)
                            .microLabel(1.1, size: 9)
                            .foregroundStyle(Palette.inkMuted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Playback

/// Every Lot page starts playback the same way: play this broadcast, or toggle
/// it if it is already loaded, with the surrounding list as the queue.
@MainActor
enum LotPlayback {
    static func toggle(_ episode: LotEpisode, within list: [LotEpisode], using player: PlaybackCoordinator) {
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

    /// Loads the broadcast if it isn't already playing, then drops the
    /// playhead where that track begins.
    static func play(_ episode: LotEpisode, from track: LotTrack, using player: PlaybackCoordinator) {
        guard let offset = track.offset, let item = episode.mediaItem() else { return }
        if !player.isCurrent(item.id) {
            player.play([item])
        }
        player.seekWhenReady(to: offset, in: item.id)
    }

    static func isCurrent(_ episode: LotEpisode, in player: PlaybackCoordinator) -> Bool {
        player.isCurrent(episode.mediaID)
    }

    static func isPlaying(_ episode: LotEpisode, in player: PlaybackCoordinator) -> Bool {
        isCurrent(episode, in: player) && player.isPlaying
    }
}
