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

#if os(iOS)
import SwiftUI
import UIKit

struct PhoneRootView: View {
    @Environment(AppState.self) private var appState
    @State private var keyboardUp = false
    @State private var showsNowPlaying = false
    @State private var shellHeight: CGFloat = 0
    @State private var opened = false

    var body: some View {
        PageContent()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !keyboardUp {
                    shell
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shellHeight = $0 }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .modifier(RootChrome(bottomInset: keyboardUp ? 0 : shellHeight))
            // The page's dark ground to the screen's edges, under the status
            // bar and the home indicator too, and light status-bar text over
            // it: the phone is dark throughout.
            .background { IndigoGlassBackground.content.ignoresSafeArea() }
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)
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
            .sheet(isPresented: $showsNowPlaying) {
                PhoneNowPlayingView()
                    .presentationDragIndicator(.visible)
                    .environment(\.colorScheme, .dark)
            }
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
