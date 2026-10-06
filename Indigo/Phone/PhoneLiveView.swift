//
//  PhoneLiveView.swift
//  Indigo
//
//  The phone's Live tab: one station to a screen, its picture full-bleed,
//  swiped up to the next. What is on air, who is playing it, and one big
//  button to listen. Swiping only moves between stations -- a stream starts
//  on Play, never on a swipe -- and whatever is playing keeps playing while
//  the others are looked at.
//

import SwiftUI

struct PhoneLiveView: View {
    @Environment(AppState.self) private var appState
    @Bindable private var feeds = PhoneFeeds.shared

    var body: some View {
        // Read before the slides spread to the screen's edges, so their
        // words keep clear of the status bar above and the tabs below.
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            StationDirectory { entries, playable in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            PhoneLiveSlide(entry: entry, item: playable(entry), insets: insets) {
                                appState.select(entry.route)
                            }
                            .containerRelativeFrame([.horizontal, .vertical])
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                // Kept outside the page, so a return to Live is a return to
                // the station that was on screen.
                .scrollPosition(id: $feeds.liveID)
            }
            .ignoresSafeArea()
        }
    }
}

/// Also For You's slides of what is on now, when there is nothing to suggest.
struct PhoneLiveSlide: View {
    let entry: StationEntry
    let item: MediaItem?
    let insets: EdgeInsets
    let openStation: () -> Void

    @Environment(PlaybackCoordinator.self) private var player

    /// IDA's green, a shade darker than the wordmark's mid.
    private static let playGreen = Color(red: 0.36, green: 0.49, blue: 0.36)

    private var isPlaying: Bool { item.map { player.isCurrent($0.id) && player.isPlaying } ?? false }

    var body: some View {
        LiveShowReader(providerID: entry.station.providerID, stationID: entry.station.id) { show, next in
            ZStack {
                // Square artwork, made as large as the screen's longer side
                // and cropped at the other: full-bleed, as the station's
                // picture should be, not a square with bands above and below.
                GeometryReader { proxy in
                    picture(show, side: max(proxy.size.width, proxy.size.height))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .clipped()
                // Dark at the top and the bottom, where the words are.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.65), location: 0),
                        .init(color: .clear, location: 0.28),
                        .init(color: .clear, location: 0.45),
                        .init(color: .black.opacity(0.85), location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                VStack(spacing: 0) {
                    topBar
                        .padding(.top, insets.top + 8)
                        .padding(.horizontal, 16)
                    Spacer(minLength: 0)
                    details(show, next)
                        .padding(.horizontal, 22)
                        .padding(.bottom, insets.bottom + 22)
                }
            }
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func picture(_ show: RadioShow?, side: CGFloat) -> some View {
        if let artwork = show?.artworkURL {
            ArtworkView(remoteURL: artwork, side: side, glyphScale: 0.3,
                        markURL: StationMark.logoURL(for: entry.station.providerID))
        } else {
            // Nothing published for what is on: the player's moving field,
            // with the station's mark on it.
            ZStack {
                PlayerShaderBackdrop()
                // In the upper part of the screen, clear of the words below.
                ArtworkView(
                    side: 120, glyphScale: 0.3,
                    markURL: StationMark.logoURL(for: entry.station.providerID),
                    showsGround: false
                )
                .offset(y: -side * 0.2)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: openStation) {
                Image(systemName: "info")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(Chip.black, ignoresSafeAreaEdges: [])
                    .overlay(Rectangle().strokeBorder(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(entry.station.name)")
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1, green: 0.3, blue: 0.2)).frame(width: 7, height: 7)
                Text(entry.station.name)
                    .font(Typeface.mono(14))
                    .tracking(1.2)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(Chip.black, ignoresSafeAreaEdges: [])
            .overlay(Rectangle().strokeBorder(.white.opacity(0.14)))
            Spacer()
            // Balances the info button, so the station's name sits centred.
            Color.clear.frame(width: 46, height: 46)
        }
    }

    /// Only what helps decide whether to listen, in IDA's boxes, in the order
    /// every slide keeps: where and who, what is on, what it sounds like, what
    /// is next on a line of its own, and the button last, always in the same
    /// place at the bottom.
    /// One row each, the same on every station: where, what is on, its
    /// genres, when the next show starts, and what it is.
    private func details(_ show: RadioShow?, _ next: RadioShow?) -> some View {
        let city = entry.location.split(separator: ",").first.map(String.init) ?? entry.location
        let genres = Array((show?.genres ?? []).filter { !$0.isEmpty }.prefix(3))
        // With nothing published, the strapline -- unless it only says the
        // city again.
        let title = show?.title ?? (entry.station.strapline.caseInsensitiveCompare(city) == .orderedSame
                                     ? nil : entry.station.strapline)
        return VStack(spacing: 8) {
            ChipFlow { Chip(text: city, tone: .lead, size: 13, uppercase: true) }
            if let title {
                ChipFlow { Chip(text: title, size: 19) }
            }
            if !genres.isEmpty {
                ChipFlow {
                    ForEach(genres, id: \.self) { Chip(text: $0, size: 12.5, uppercase: true) }
                }
            }
            if let next {
                ChipFlow {
                    if let time = next.startsAt?.formatted(date: .omitted, time: .shortened) {
                        Chip(text: time, tone: .sheen, size: 12.5)
                    }
                    Chip(text: "Next up", size: 12.5, uppercase: true)
                }
                ChipFlow { Chip(text: next.title, size: 15) }
            }
            playButton
                .padding(.top, 10)
        }
    }

    private var playButton: some View {
        Button {
            guard let item else { return }
            if player.isCurrent(item.id) { player.toggle() } else { player.playRadio(item) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                Text(isPlaying ? "PAUSE" : "PLAY")
                    .font(Typeface.mono(16, weight: .medium))
                    .tracking(2)
            }
            .foregroundStyle(Color(red: 0.06, green: 0.1, blue: 0.07))
            .frame(maxWidth: 260)
            .frame(height: 54)
            .background(Self.playGreen)
        }
        .buttonStyle(.plain)
        .disabled(item == nil)
        .accessibilityLabel(isPlaying ? "Pause \(entry.station.name)" : "Play \(entry.station.name)")
    }
}

/// The phone's Shows tab: each station's shows, and the archives. A list for
/// now; one grid across every station comes next.
/// A page's name, centred at the top, as the phone's pages carry it.
struct PhonePageTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 20, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 16)
    }
}
