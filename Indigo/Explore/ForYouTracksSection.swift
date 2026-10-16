//
//  ForYouTracksSection.swift
//  Indigo
//
//  "Tracks to hear" on For You: a few tracks that can actually be played,
//  each from an artist the record connects to something the listener keeps
//  or plays. Not a second pipeline -- it is DIG Discover's own list
//  (`DigStore.discover`): the same starting points, the same verified
//  artists, the same playback checks, the same half-hour answer and the list
//  held from last time, so opening For You asks for nothing DIG has not
//  already asked for. Every row says "Play track" for a recording of the
//  track itself or "Hear in radio show" for the moment a tracklist says it
//  was played, and only a track checked to play is here at all.
//
//  The artist and show recommendations stay as they were, beside it.
//  Development and internal builds only (`ForYouTracksFeature`).
//

import SwiftUI

/// On the Mac, a band between For You's header and its map.
struct ForYouTracksSection: View {
    @Environment(DigStore.self) private var dig
    @Environment(AppState.self) private var appState
    @State private var opened = Date()
    /// Rows on For You; the rest are DIG's.
    static let shown = 4

    var body: some View {
        let state = dig.discover
        Group {
            if !state.tracks.isEmpty || state.working {
                DigSection(title: "Tracks to hear",
                           trailing: state.tracks.isEmpty ? "Listening around…" : "\(state.tracks.count) found") {
                    DiscoverList(tracks: Array(state.tracks.prefix(Self.shown)), opened: opened)
                    if state.tracks.count > Self.shown {
                        Button("All \(state.tracks.count) in DIG") { appState.select(.dig) }
                            .buttonStyle(.plain)
                            .font(Typeface.mono(11.5, weight: .medium))
                            .underline()
                            .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 18)
                .foregroundStyle(Palette.ink)
                .background(Color.white.opacity(0.94))
                .padding(.horizontal, 28).padding(.top, 18)
            }
        }
        .task { opened = Date(); await dig.refreshDiscover() }
    }
}

/// On the phone, one slide after the cover: four tracks, square, the picture
/// the play button, as DIG's own grid has them.
struct PhoneForYouTracksSlide: View {
    let insets: EdgeInsets
    @Environment(DigStore.self) private var dig
    @Environment(AppState.self) private var appState
    @State private var opened = Date()

    var body: some View {
        let tracks = dig.discover.tracks
        VStack(alignment: .leading, spacing: 14) {
            DigSection(title: "Tracks to hear", trailing: tracks.isEmpty ? "Listening around…" : nil) {
                DiscoverList(tracks: Array(tracks.prefix(4)), opened: opened)
            }
            if tracks.count > 4 {
                Button("All \(tracks.count) in DIG") { appState.select(.dig) }
                    .buttonStyle(.plain)
                    .font(Typeface.mono(12, weight: .medium))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, insets.top + 16)
        .padding(.bottom, insets.bottom + 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .environment(\.isPhoneLayout, true)
        .task { opened = Date(); await dig.refreshDiscover() }
    }
}
