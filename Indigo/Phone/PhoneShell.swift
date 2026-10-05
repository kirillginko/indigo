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

/// What is playing, above the tabs: its picture, its two lines, play and
/// pause. Tapped, it opens the full player. Nothing playing, it is not there.
struct PhoneMiniPlayer: View {
    let open: () -> Void
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        if let item = player.current {
            LiveShowReader(providerID: item.sourceID, stationID: item.id) { show in
                HStack(spacing: 12) {
                    ArtworkView(
                        localKey: item.artworkKey,
                        remoteURL: show?.artworkURL ?? item.remoteArtworkURL,
                        side: 44,
                        glyphScale: 0.3,
                        markURL: StationMark.logoURL(for: item.sourceID)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NowPlayingLines.primary(item, show))
                            .font(Typeface.mono(13, weight: .medium))
                            .lineLimit(1)
                        Text(NowPlayingLines.secondary(item, show))
                            .font(Typeface.mono(10.5))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    transport("backward.fill", label: "Previous", size: 15) { player.previous() }
                    transport(player.isPlaying ? "pause.fill" : "play.fill",
                              label: player.isPlaying ? "Pause" : "Play", size: 20) { player.toggle() }
                    transport("forward.fill", label: "Next", size: 15) { player.next() }
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .frame(height: 60)
                .foregroundStyle(.white)
                .background { PlayerShaderBackdrop() }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
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

/// The full player: the picture large, the two lines, and the transport, over
/// the player's moving field.
struct PhoneNowPlayingView: View {
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        ZStack {
            PlayerShaderBackdrop().ignoresSafeArea()
            if let item = player.current {
                LiveShowReader(providerID: item.sourceID, stationID: item.id) { show in
                    VStack(spacing: 28) {
                        Spacer(minLength: 0)
                        ArtworkView(
                            localKey: item.artworkKey,
                            remoteURL: show?.artworkURL ?? item.remoteArtworkURL,
                            side: 300,
                            glyphScale: 0.3,
                            markURL: StationMark.logoURL(for: item.sourceID)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                        VStack(spacing: 8) {
                            Text(NowPlayingLines.primary(item, show))
                                .font(.system(size: 22, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                            Text(NowPlayingLines.secondary(item, show))
                                .font(Typeface.mono(12))
                                .foregroundStyle(.white.opacity(0.75))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 24)
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
                Text("Nothing playing")
                    .font(Typeface.mono(13))
            }
        }
        .foregroundStyle(.white)
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
