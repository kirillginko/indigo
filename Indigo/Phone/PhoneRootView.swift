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
//  Layers, in one view: the page; the full player, over it when open; and
//  the web player that archived episodes and uploads play through. There is
//  one web view, and taken out of the window WebKit suspends it, so it is
//  never moved anywhere else -- only resized, placed and stacked. Parked, it
//  sits under the page's opaque ground, as wide as the screen at 16:9:
//  YouTube picks its stream for the player's size (it would not play at all
//  under 200 points tall), so parked small an upload played, and maximised
//  it showed, at its lowest quality. Maximised from the full player, it is
//  laid over everything, the whole screen, with one button back to the
//  thumbnail; it plays throughout.
//

#if os(iOS)
import SwiftUI
import UIKit

struct PhoneRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player
    /// The video over the whole screen.
    @State private var videoFullScreen = false
    @State private var keyboardUp = false
    @State private var showsNowPlaying = false
    @State private var shellHeight: CGFloat = 0
    @State private var opened = false
    /// The window's size, for parking the web player in its corner. Measured
    /// rather than read from a GeometryReader: inside one, the full player's
    /// ground could not reach under the status bar and the home indicator.
    @State private var size: CGSize = .zero

    private var videoUp: Bool {
        videoFullScreen && player.embedProvider == .youtube
    }

    var body: some View {
        ZStack {
            if videoUp {
                Color.black.ignoresSafeArea()
                    .zIndex(3)
            }
            // In an overlay of a view that takes the screen's size, so the
            // web view -- parked as wide as the screen, or turned with a
            // video -- can never make the layout wider: after a video was
            // turned on its side, it kept the landscape width and the whole
            // phone layout stayed stretched when it stood back up.
            Color.clear
                .overlay(alignment: .topLeading) { embedLayer(in: size) }
                .clipped()
                .zIndex(videoUp ? 4 : 0)
            page
                .zIndex(1)
            if showsNowPlaying {
                PhoneNowPlayingView(maximize: { videoFullScreen = true }) { close() }
                    // Down by the whole screen and then some: its ground runs
                    // up under the status bar, and moved by its own height
                    // only, that top strip -- close button and all -- was
                    // left sitting at the bottom of the screen.
                    .transition(.offset(y: size.height + 160))
                    .zIndex(2)
            }
            if videoUp {
                // Swiped down anywhere, the video goes back to its thumbnail,
                // as the full player closes; the web view takes no touches.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                        if value.translation.height > 70 { videoFullScreen = false }
                    })
                    .zIndex(4.5)
                minimizeButton
                    .zIndex(5)
                videoControls
                    .zIndex(5)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: videoUp)
        // Nothing left to show full screen when the upload ends or something
        // else plays.
        .onChange(of: player.embedProvider) { _, provider in
            if provider != .youtube { videoFullScreen = false }
        }
        // Full screen, a video turns to landscape; back, the phone stands up.
        .onChange(of: videoUp) { _, up in OrientationLock.allowsLandscape(up) }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        // Not dependent on the full player: changed as it opened and closed,
        // every page laid itself out again mid-slide, and the player sat at
        // the bottom of the screen until they were done.
        .modifier(RootChrome(bottomInset: keyboardUp ? 0 : shellHeight, hostsEmbedPlayer: false))
        // The page's dark ground to the screen's edges, under the status bar
        // and the home indicator too, and light status-bar text over it: the
        // phone is dark throughout.
        .background { IndigoGlassBackground.content.ignoresSafeArea() }
        .preferredColorScheme(.dark)
        // The home bar fades until the screen is touched near it.
        .persistentSystemOverlays(.hidden)
        .environment(\.colorScheme, .dark)
        .environment(\.isPhoneLayout, true)
        .animation(.easeOut(duration: 0.2), value: keyboardUp)
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
                        // The home bar's strip under the tabs in the headers'
                        // shade, as the status bar's is above them.
                        .background(alignment: .bottom) {
                            IndigoGlassBackground.header
                                .frame(height: 0)
                                .ignoresSafeArea(edges: .bottom)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Opaque, so the parked web player under it cannot show.
            .background { IndigoGlassBackground.content.ignoresSafeArea() }
    }

    /// The one web view: parked under the page, or the whole screen.
    private func embedLayer(in size: CGSize) -> some View {
        let parked = CGSize(width: max(size.width, 356), height: max(size.width, 356) * 9 / 16)
        // Up, it stops above the controls: YouTube sets its captions along
        // the bottom of its frame, and over the whole screen they covered
        // the seek bar's times.
        let up = CGSize(width: size.width, height: max(200, size.height - controlsHeight))
        return EmbedPlayerSurface(engine: player.embed)
            .frame(width: videoUp ? up.width : parked.width,
                   height: videoUp ? up.height : parked.height)
            .position(videoUp
                      ? CGPoint(x: size.width / 2, y: up.height / 2)
                      : CGPoint(x: size.width / 2, y: size.height - parked.height / 2))
            .allowsHitTesting(false)
            .accessibilityHidden(!videoUp)
    }

    private var isLandscape: Bool { size.width > size.height }

    /// The room kept under the full-screen video for its controls: on its
    /// side, one slim row, so the picture keeps the height.
    private var controlsHeight: CGFloat { isLandscape ? 64 : 150 }

    /// Along the bottom of the full-screen video: play and pause, and the
    /// seek bar -- stacked upright, side by side in landscape.
    private var videoControls: some View {
        VStack(spacing: 14) {
            Spacer()
            if isLandscape {
                HStack(spacing: 18) {
                    playPause(side: 44)
                    PhoneScrubber()
                }
            } else {
                playPause(side: 60)
                PhoneScrubber()
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, isLandscape ? 8 : 18)
    }

    private func playPause(side: CGFloat) -> some View {
        Button { player.toggle() } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: side * 0.46, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: side, height: side)
                .background(Chip.black, ignoresSafeAreaEdges: [])
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    /// Back to the thumbnail; the video plays on. Top left, where the full
    /// player's close button is (the top right is the Debug sync button's).
    private var minimizeButton: some View {
        VStack {
            HStack {
                Button { videoFullScreen = false } label: {
                    PhoneRoundGlyph(symbol: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimise the video")
                Spacer()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// Only the player slides; nothing else is animated with it.
    private func close() {
        withAnimation(.spring(duration: 0.35)) { showsNowPlaying = false }
    }

    private func openPlayer() {
        withAnimation(.spring(duration: 0.35)) { showsNowPlaying = true }
    }

    private var shell: some View {
        VStack(spacing: 8) {
            PhoneMiniPlayer { openPlayer() }
            PhoneTabBar(
                selected: PhoneTab.of(appState.route),
                searching: appState.route == .dig,
                select: { tab in appState.select(tab.route) },
                search: { appState.select(.dig) }
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        // Down into the home bar's strip, which the bar fades out of: kept
        // clear, it was an empty band under the tabs.
        .padding(.bottom, -14)
    }
}
#endif
