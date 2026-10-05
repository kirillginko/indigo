//
//  PhoneRootView.swift
//  Indigo
//
//  The phone's window: the page full screen, and at the bottom the player and
//  the tabs. The sidebar layout squeezed onto a phone cut the sidebar off at
//  the left and left most of the app out of reach.
//
//  Pages are the same pages, through `PageContent`, and navigate the same way
//  -- a tab selects a route, a link opens a detail page over it -- so nothing
//  inside them knows which layout it is in. The bottom of the window is kept
//  for the player and tabs: pages are inset above them, and while the
//  keyboard is up they step aside, so search is never typed under a tab bar.
//
//  Three layers, in one view: the page; the full player, over it when open;
//  and the web player that archived episodes and uploads play through. There
//  is one web view, and taken out of the window WebKit suspends it, so it is
//  never moved anywhere else -- only resized, placed and stacked. Parked, it
//  sits under the page's opaque ground at 356x200, the smallest a YouTube
//  player will play at (at 320x180 uploads would not play at all). With the
//  video on, it sits over the full player, in the artwork's place. Close the
//  player and it goes back under the page, still playing.
//

#if os(iOS)
import SwiftUI
import UIKit

struct PhoneRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player
    @AppStorage("phone.showsVideo") private var showsVideo = true
    @State private var keyboardUp = false
    @State private var showsNowPlaying = false
    @State private var shellHeight: CGFloat = 0
    /// Where the full player keeps its artwork, in this view's space.
    @State private var videoFrame: CGRect = .zero
    @State private var opened = false
    /// The window's size, for parking the web player in its corner. Measured
    /// rather than read from a GeometryReader: inside one, the full player's
    /// ground could not reach under the status bar and the home indicator.
    @State private var size: CGSize = .zero

    private static let space = PlayerVideoFrame.space
    private static let parked = CGSize(width: 356, height: 200)

    private var videoUp: Bool {
        showsNowPlaying && showsVideo && player.embedProvider == .youtube && videoFrame.width > 0
    }

    var body: some View {
        ZStack {
            embedLayer(in: size)
                .zIndex(videoUp ? 3 : 0)
            page
                .zIndex(1)
            if showsNowPlaying {
                PhoneNowPlayingView(showsVideo: $showsVideo) { close() }
                    .onPreferenceChange(PlayerVideoFrame.Key.self) { videoFrame = $0 }
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
            }
        }
        .coordinateSpace(name: Self.space)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .modifier(RootChrome(bottomInset: keyboardUp || showsNowPlaying ? 0 : shellHeight, hostsEmbedPlayer: false))
        // The page's dark ground to the screen's edges, under the status bar
        // and the home indicator too, and light status-bar text over it: the
        // phone is dark throughout.
        .background { IndigoGlassBackground.content.ignoresSafeArea() }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: keyboardUp)
        .animation(.spring(duration: 0.35), value: showsNowPlaying)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
        }
        // A radio app first: the phone opens on Live.
        .onAppear {
            guard !opened else { return }
            opened = true
            appState.select(.live)
        }
    }

    private var page: some View {
        PageContent()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !keyboardUp {
                    shell
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shellHeight = $0 }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Opaque, so the parked web player under it cannot show.
            .background { IndigoGlassBackground.content.ignoresSafeArea() }
    }

    /// The one web view: parked under the page, or over the full player.
    private func embedLayer(in size: CGSize) -> some View {
        EmbedPlayerSurface(engine: player.embed)
            .frame(width: videoUp ? videoFrame.width : Self.parked.width,
                   height: videoUp ? videoFrame.height : Self.parked.height)
            .position(videoUp
                      ? CGPoint(x: videoFrame.midX, y: videoFrame.midY)
                      : CGPoint(x: size.width - Self.parked.width / 2, y: size.height - Self.parked.height / 2))
            .allowsHitTesting(false)
            .accessibilityHidden(!videoUp)
    }

    private func close() {
        showsNowPlaying = false
    }

    private var shell: some View {
        VStack(spacing: 8) {
            PhoneMiniPlayer { showsNowPlaying = true }
            PhoneTabBar(
                selected: PhoneTab.of(appState.route),
                searching: appState.route == .dig,
                select: { tab in appState.select(tab.route) },
                search: { appState.select(.dig) }
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}
#endif
