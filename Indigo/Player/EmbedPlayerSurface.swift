//
//  EmbedPlayerSurface.swift
//  Indigo
//
//  Hosts the embed engine's web view inside the window. WebKit suspends media
//  in a view that isn't in a window, so this stays mounted for the life of the
//  app rather than living on the episode page — otherwise archived audio would
//  stop the moment you navigated away from it.
//

import SwiftUI
import WebKit

#if os(macOS)
struct EmbedPlayerSurface: NSViewRepresentable {
    let engine: EmbedAudioEngine

    func makeNSView(context: Context) -> WKWebView { engine.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// A place for the embed's web view to wait when the main window is closed.
///
/// The main window's `EmbedPlayerSurface` is the web view's home, and closing
/// that window takes it out of every window — where WebKit suspends it, so a
/// SoundCloud or Mixcloud show started from the mini player never made a
/// sound. This adopts the web view only while nothing visible holds it; when
/// the main window comes back, SwiftUI puts the web view into it again and
/// this is left empty. Never both: a view has one superview.
struct EmbedStandbySurface: NSViewRepresentable {
    let engine: EmbedAudioEngine

    func makeNSView(context: Context) -> StandbyView { StandbyView(engine: engine) }
    func updateNSView(_ view: StandbyView, context: Context) { view.adoptIfOrphaned() }

    final class StandbyView: NSView {
        private let engine: EmbedAudioEngine
        private var observers: [NSObjectProtocol] = []

        init(engine: EmbedAudioEngine) {
            self.engine = engine
            super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            // Faint rather than hidden, as the main window parks it: WebKit
            // throttles a view it believes nobody can see.
            alphaValue = 0.02
            // Closing a window orphans the web view; a window appearing may
            // be this one becoming visible. The switch between the two
            // players does both at once, in either order, so both are heard.
            observers = [NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification]
                .map { name in
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        // A closing window still owns the web view until it
                        // is gone, so look on the next turn of the run loop.
                        DispatchQueue.main.async { self?.adoptIfOrphaned() }
                    }
                }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            adoptIfOrphaned()
        }

        func adoptIfOrphaned() {
            guard let window, window.isVisible, let webView = engine.webView else { return }
            if let home = webView.window, home.isVisible || home.isMiniaturized { return }
            webView.removeFromSuperview()
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }
    }
}
#else
struct EmbedPlayerSurface: UIViewRepresentable {
    let engine: EmbedAudioEngine

    func makeUIView(context: Context) -> WKWebView { engine.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// There is no separate mini player window on iOS to keep a closed main
/// window's player alive in, so there is nothing to stand by.
struct EmbedStandbySurface: View {
    let engine: EmbedAudioEngine
    var body: some View { EmptyView() }
}
#endif
