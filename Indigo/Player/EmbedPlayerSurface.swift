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
#else
struct EmbedPlayerSurface: UIViewRepresentable {
    let engine: EmbedAudioEngine

    func makeUIView(context: Context) -> WKWebView { engine.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
