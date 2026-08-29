//
//  DublabComponents.swift
//  Indigo
//
//  Tiles, rows and playback glue shared by the dublab pages. dublab publishes
//  its archive as plain MP3s, so a broadcast plays through the same engine a
//  local file does — seekable, with a real duration.
//

import SwiftUI

// MARK: - Crating

/// dublab broadcasts are crated as broadcasts — the whole set, not a track
/// inside it. Keeping one does not require its recording to stay up, so an
/// archive entry can always be saved.
struct DublabCrateMenu: ViewModifier {
    let broadcast: DublabBroadcast
    @Environment(CrateService.self) private var crate

    func body(content: Content) -> some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: broadcast.mediaID, providerID: DublabProvider.providerID)
        return content.contextMenu {
            Button(isCrated ? "Remove from Crate" : "Add to Crate") {
                toggleDublabCrate(broadcast, in: crate)
            }
        }
    }
}

struct DublabCrateButton: View {
    let broadcast: DublabBroadcast
    var compact = false
    @Environment(CrateService.self) private var crate

    var body: some View {
        let _ = crate.revision
        let isCrated = crate.contains(broadcast: broadcast.mediaID, providerID: DublabProvider.providerID)
        if compact {
            CrateGlyphButton(isCrated: isCrated) { toggleDublabCrate(broadcast, in: crate) }
        } else {
            CrateButton(isCrated: isCrated) { toggleDublabCrate(broadcast, in: crate) }
        }
    }
}

private func toggleDublabCrate(_ broadcast: DublabBroadcast, in crate: CrateService) {
    if let existing = crate.item(forBroadcast: broadcast.mediaID, providerID: DublabProvider.providerID) {
        crate.remove(existing)
    } else {
        crate.add(
            broadcast: broadcast.mediaID,
            providerID: DublabProvider.providerID,
            title: broadcast.title,
            subtitle: broadcast.airedLabel,
            artworkURL: broadcast.artworkURL,
            playbackURL: broadcast.audioURL,
            embedProvider: nil,
            genres: broadcast.genreNames
        )
    }
}

extension View {
    func dublabCrateMenu(for broadcast: DublabBroadcast) -> some View {
        modifier(DublabCrateMenu(broadcast: broadcast))
    }
}

// MARK: - Tiles

struct DublabBroadcastTile: View {
    let broadcast: DublabBroadcast
    let isCurrent: Bool
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(remoteURL: broadcast.artworkURL)
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
                    } else if broadcast.isGuestSession, isHovering {
                        Text("Guest")
                            .microLabel(1.1, size: 9)
                            .foregroundStyle(Palette.inverseInk)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Palette.inverse)
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    DublabCrateButton(broadcast: broadcast, compact: true)
                        .padding(8)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(broadcast.title)
                    .font(Typeface.body(12, weight: .semibold))
                    .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(broadcast.subtitle)
                    .microLabel(0.8)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .dublabCrateMenu(for: broadcast)
        .accessibilityLabel("Open \(broadcast.title)")
    }
}

struct DublabDJTile: View {
    let dj: DublabDJ
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(remoteURL: dj.artworkURL)
                .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))
                .overlay(alignment: .topLeading) {
                    if !dj.isActive, isHovering {
                        Text("Past resident")
                            .microLabel(1.1, size: 9)
                            .foregroundStyle(Palette.inverseInk)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Palette.inverse)
                            .padding(8)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(dj.name)
                    .font(Typeface.body(12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(dj.shows.first?.title ?? (dj.isActive ? "dublab" : "Past resident"))
                    .microLabel(0.8)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Open \(dj.name)")
    }
}

// MARK: - Row

/// Used where a DJ's run reads as a running order rather than a grid.
struct DublabBroadcastRow: View {
    let broadcast: DublabBroadcast
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

            Text(broadcast.genreNames.prefix(2).joined(separator: " · "))
                .font(Typeface.body(12))
                .foregroundStyle(isCurrent ? Palette.accent.opacity(0.85) : Palette.inkMuted)
                .lineLimit(1)
                .frame(width: 190, alignment: .leading)

            Text(broadcast.airedLabel ?? "—")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 88, alignment: .trailing)

            DublabCrateButton(broadcast: broadcast, compact: true)
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
        .dublabCrateMenu(for: broadcast)
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

// MARK: - Filtering

/// dublab files its archive under three hundred genres and thirty years —
/// far too many for a row of chips — and narrowing re-asks the station rather
/// than filtering the page, so these are menus rather than toggles.
struct DublabFilterBar: View {
    let genres: [DublabGenre]
    let years: [String]
    let selectedGenre: String?
    let selectedYear: String?
    let onGenre: (String?) -> Void
    let onYear: (String?) -> Void
    let onClear: () -> Void

    var body: some View {
        if !genres.isEmpty || !years.isEmpty {
            HStack(spacing: 10) {
                Text("Narrow by").microLabel(1.4).foregroundStyle(Palette.inkFaint)

                if !genres.isEmpty {
                    Menu {
                        Button("All genres") { onGenre(nil) }
                        Divider()
                        ForEach(genres) { genre in
                            Button(genre.name) { onGenre(genre.slug) }
                        }
                    } label: {
                        chip(genreTitle, isSet: selectedGenre != nil)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                if !years.isEmpty {
                    Menu {
                        Button("All years") { onYear(nil) }
                        Divider()
                        ForEach(years, id: \.self) { year in
                            Button(year) { onYear(year) }
                        }
                    } label: {
                        chip(selectedYear ?? "Year", isSet: selectedYear != nil)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                if selectedGenre != nil || selectedYear != nil {
                    Button("Clear", action: onClear)
                        .buttonStyle(.plain)
                        .microLabel(1.0)
                        .foregroundStyle(Palette.accent)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 12)
            .background(Palette.paperChrome)
        }
    }

    private var genreTitle: String {
        guard let selectedGenre else { return "Genre" }
        return genres.first { $0.slug == selectedGenre }?.name ?? "Genre"
    }

    private func chip(_ text: String, isSet: Bool) -> some View {
        Text(text)
            .microLabel(1.1, size: 9)
            .foregroundStyle(isSet ? Palette.inverseInk : Palette.inkMuted)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSet ? Palette.inverse : Color.clear)
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .contentShape(Rectangle())
    }
}

// MARK: - Playback

/// Every dublab page starts playback the same way: play this broadcast, or
/// toggle it if it is already loaded, with the surrounding list as the queue.
@MainActor
enum DublabPlayback {
    static func toggle(
        _ broadcast: DublabBroadcast,
        within list: [DublabBroadcast],
        using player: PlaybackCoordinator
    ) {
        guard let item = broadcast.mediaItem() else { return }
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

    static func isCurrent(_ broadcast: DublabBroadcast, in player: PlaybackCoordinator) -> Bool {
        player.isCurrent(broadcast.mediaID)
    }

    static func isPlaying(_ broadcast: DublabBroadcast, in player: PlaybackCoordinator) -> Bool {
        isCurrent(broadcast, in: player) && player.isPlaying
    }
}
