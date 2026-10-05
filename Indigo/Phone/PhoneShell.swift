//
//  PhoneShell.swift
//  Indigo
//
//  What stays at the bottom of the phone: the player, and below it the tabs
//  and the round search button. For You, Live, Shows and Crate are tabs;
//  search opens Dig.
//

import SwiftUI

enum PhoneTab: CaseIterable, Hashable {
    case forYou, live, shows, crate

    /// The page the tab opens at.
    var route: Route {
        switch self {
        case .forYou: .forYou
        case .live: .live
        case .shows: .shows
        case .crate: .crate
        }
    }

    var symbol: String {
        switch self {
        case .forYou: "sparkle"
        case .live: "dot.radiowaves.left.and.right"
        case .shows: "square.grid.2x2.fill"
        case .crate: "square.stack.fill"
        }
    }

    var label: String {
        switch self {
        case .forYou: "For You"
        case .live: "Live"
        case .shows: "Shows"
        case .crate: "Crate"
        }
    }

    /// Which tab a page belongs to: a station's live page to Live, its shows,
    /// archives and the like to Shows. Dig belongs to search, not a tab.
    static func of(_ route: Route) -> PhoneTab? {
        switch route {
        case .explore, .forYou: .forYou
        case .live, .station, .kioskStation, .noodsStation, .lotStation, .dublabStation, .alharaStation,
             .cashmereStation, .lylStation, .idaStation, .radio80000Station, .panikStation, .rovrStation,
             .n10asStation:
            .live
        case .crate, .tracks, .albums, .artists: .crate
        case .dig: nil
        default: .shows
        }
    }
}

/// Four tabs in one floating capsule, and search in its own circle beside it.
struct PhoneTabBar: View {
    let selected: PhoneTab?
    let searching: Bool
    let select: (PhoneTab) -> Void
    let search: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(PhoneTab.allCases, id: \.self) { tab in
                    Button { select(tab) } label: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 21, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background {
                                if tab == selected {
                                    Capsule().fill(.white.opacity(0.16)).padding(3)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.label)
                    .accessibilityAddTraits(tab == selected ? .isSelected : [])
                }
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))

            Button(action: search) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 21, weight: .semibold))
                    .frame(width: 62, height: 62)
                    .background {
                        if searching { Circle().fill(.white.opacity(0.16)).padding(3) }
                    }
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
        }
        .foregroundStyle(.white)
    }
}

/// What is playing, above the tabs: its picture, its name in a box, previous,
/// play and pause, next. Tapped, it opens the full player. Nothing playing,
/// it is not there.
struct PhoneMiniPlayer: View {
    let open: () -> Void
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        if let item = player.current {
            LiveShowReader(providerID: item.sourceID, stationID: item.id) { show in
                HStack(spacing: 10) {
                    ArtworkView(
                        localKey: item.artworkKey,
                        remoteURL: show?.artworkURL ?? item.remoteArtworkURL,
                        side: 46,
                        glyphScale: 0.3,
                        markURL: StationMark.logoURL(for: item.sourceID)
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        Text(NowPlayingLines.primary(item, show))
                            .font(Typeface.mono(12.5, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Chip.black)
                        Text(NowPlayingSummary.sourceLabel(for: item))
                            .font(Typeface.mono(10))
                            .tracking(1)
                            .lineLimit(1)
                            .foregroundStyle(Chip.ink)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Chip.green)
                    }
                    Spacer(minLength: 0)
                    transport("backward.fill", label: "Previous", size: 15) { player.previous() }
                    transport(player.isPlaying ? "pause.fill" : "play.fill",
                              label: player.isPlaying ? "Pause" : "Play", size: 20) { player.toggle() }
                    transport("forward.fill", label: "Next", size: 15) { player.next() }
                }
                .padding(.leading, 7)
                .padding(.trailing, 6)
                .frame(height: 60)
                .foregroundStyle(.white)
                .background { PlayerShaderBackdrop() }
                .clipped()
                .overlay(Rectangle().strokeBorder(.white.opacity(0.12)))
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens the player")
            }
        }
    }
}

private extension PhoneMiniPlayer {
    func transport(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 38, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The two lines that name what is playing: for a station, the show on air
/// over the station; otherwise the item over its artist and album.
enum NowPlayingLines {
    static func primary(_ item: MediaItem, _ show: RadioShow?) -> String {
        item.isLive ? (show?.title ?? item.title) : item.title
    }

    static func secondary(_ item: MediaItem, _ show: RadioShow?) -> String {
        if item.isLive {
            return [show == nil ? nil : item.title, show?.location]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return [item.subtitle, item.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The full player, the whole screen: the picture, square -- for an upload,
/// its thumbnail, with a button in the corner to watch it full screen; what
/// is playing in IDA's boxes; the seek bar; the transport -- over the
/// player's moving field. Closed with its button or a swipe down; closed,
/// whatever plays goes on playing.
struct PhoneNowPlayingView: View {
    var maximize: () -> Void = {}
    var close: () -> Void = {}
    @Environment(PlaybackCoordinator.self) private var player
    @State private var drag: CGFloat = 0

    private var isVideo: Bool { player.embedProvider == .youtube }

    var body: some View {
        ZStack {
            if let item = player.current {
                LiveShowReader(providerID: item.sourceID, stationID: item.id) { show in
                    VStack(spacing: 22) {
                        Spacer(minLength: 0)
                        picture(item, show)
                        VStack(spacing: 10) {
                            ChipFlow {
                                // An upload's source says nothing the
                                // thumbnail does not.
                                if !isVideo {
                                    Chip(text: NowPlayingSummary.sourceLabel(for: item), tone: .lead, size: 13, uppercase: true)
                                }
                                Chip(text: NowPlayingLines.primary(item, show), size: 18)
                            }
                            let secondary = NowPlayingLines.secondary(item, show)
                            if !secondary.isEmpty {
                                ChipFlow { Chip(text: secondary, size: 13) }
                            }
                        }
                        .padding(.horizontal, 20)
                        PhoneScrubber()
                            .padding(.horizontal, 28)
                        HStack(spacing: 44) {
                            transportButton("backward.fill", label: "Previous", size: 26) { player.previous() }
                            transportButton(player.isPlaying ? "pause.fill" : "play.fill",
                                            label: player.isPlaying ? "Pause" : "Play", size: 40) { player.toggle() }
                            transportButton("forward.fill", label: "Next", size: 26) { player.next() }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 24)
                }
            } else {
                Chip(text: "Nothing playing", size: 13)
            }
            VStack {
                Button(action: close) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close the player")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The ground as a background, to the screen's edges: drawn in the
        // stack, the field (which measures itself) stopped at the safe area
        // and left black bands under the status bar and the home indicator.
        .background { PlayerShaderBackdrop().ignoresSafeArea() }
        .foregroundStyle(.white)
        .offset(y: drag)
        .gesture(
            DragGesture()
                .onChanged { drag = max(0, $0.translation.height) }
                .onEnded { value in
                    if value.translation.height > 140 || value.predictedEndTranslation.height > 320 {
                        close()
                    } else {
                        withAnimation(.spring(duration: 0.3)) { drag = 0 }
                    }
                }
        )
    }

    /// The artwork, square; for an upload its thumbnail, with the way to
    /// watch it full screen in the corner.
    private func picture(_ item: MediaItem, _ show: RadioShow?) -> some View {
        ArtworkView(
            localKey: item.artworkKey,
            remoteURL: show?.artworkURL ?? item.remoteArtworkURL,
            side: 300,
            glyphScale: 0.3,
            markURL: StationMark.logoURL(for: item.sourceID)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .overlay(alignment: .topTrailing) {
            if isVideo {
                Button(action: maximize) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Watch the video full screen")
            }
        }
    }

    private func transportButton(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Where in the episode or track the player is, and dragging to move there.
/// A live stream cannot be moved through, so it says LIVE instead.
struct PhoneScrubber: View {
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            if player.canSeek {
                VStack(spacing: 6) {
                    HairlineSlider(value: player.progress, enabled: true, thickness: 4) { fraction in
                        player.seek(fraction: fraction)
                    }
                    HStack {
                        Text(TimeFormat.clock(player.position))
                        Spacer()
                        Text(TimeFormat.clock(player.duration))
                    }
                    .font(Typeface.mono(11))
                    .foregroundStyle(.white.opacity(0.75))
                    .monospacedDigit()
                }
            } else if player.current?.isLive == true {
                HStack(spacing: 6) {
                    Circle().fill(Color(red: 1, green: 0.3, blue: 0.2)).frame(width: 7, height: 7)
                    Text("LIVE").microLabel(1.8, size: 11)
                }
            }
        }
    }
}
