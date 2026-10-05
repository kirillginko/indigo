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

private struct PhoneLiveSlide: View {
    let entry: StationEntry
    let item: MediaItem?
    let insets: EdgeInsets
    let openStation: () -> Void

    @Environment(PlaybackCoordinator.self) private var player

    /// IDA's green, a shade darker than the wordmark's mid.
    private static let playGreen = Color(red: 0.36, green: 0.49, blue: 0.36)

    private var isPlaying: Bool { item.map { player.isCurrent($0.id) && player.isPlaying } ?? false }

    var body: some View {
        LiveShowReader(providerID: entry.station.providerID, stationID: entry.station.id) { show in
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
                    details(show)
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
            // Nothing published for what is on: the wordmark's still green,
            // with the station's mark on it.
            ZStack {
                Image("MineralGround").resizable().scaledToFill()
                ArtworkView(
                    side: 120, glyphScale: 0.3,
                    markURL: StationMark.logoURL(for: entry.station.providerID),
                    showsGround: false
                )
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: openStation) {
                Image(systemName: "info")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(entry.station.name)")
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1, green: 0.3, blue: 0.2)).frame(width: 7, height: 7)
                Text(entry.station.name)
                    .font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            Spacer()
            // Balances the info button, so the station's name sits centred.
            Color.clear.frame(width: 46, height: 46)
        }
    }

    /// Only what helps decide whether to listen: what is on, who and what it
    /// sounds like, and the button.
    private func details(_ show: RadioShow?) -> some View {
        VStack(spacing: 14) {
            Text(show?.title ?? entry.station.strapline)
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.4), radius: 8)
            chips(show)
            playButton
        }
    }

    /// Who is playing and what it sounds like, as IDA tags them.
    @ViewBuilder
    private func chips(_ show: RadioShow?) -> some View {
        // NTS names its show as its host; a host already in the title is said.
        let host = show?.host.flatMap { host in
            show?.title.localizedCaseInsensitiveContains(host) == true ? nil : host
        }
        let words = ([host].compactMap { $0 } + (show?.genres ?? []))
            .filter { !$0.isEmpty }
            .prefix(2)
        if !words.isEmpty {
            HStack(spacing: 2) {
                ForEach(Array(words), id: \.self) { word in
                    Text(word)
                        .font(Typeface.mono(12.5))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.72))
                }
            }
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
struct PhoneShowsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                PhonePageTitle("Shows")
                ForEach(ShowsDirectory.entries) { entry in
                    Button { appState.select(entry.route) } label: {
                        HStack {
                            Text(entry.station)
                                .font(Typeface.mono(14, weight: .medium))
                            Spacer()
                            Text(entry.label)
                                .font(Typeface.mono(12))
                                .foregroundStyle(Palette.inkFaint)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.inkFaint)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rule(color: Palette.outline)
                }
            }
        }
    }
}

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
