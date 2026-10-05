//
//  PhoneLiveView.swift
//  Indigo
//
//  The phone's Live tab: every station, what is on it now, and its page one
//  tap away. A list for now; full-screen slides come next.
//

import SwiftUI

struct PhoneLiveView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                PhonePageTitle("Live")
                StationDirectory { entries in
                    ForEach(entries) { entry in
                        Button { appState.select(entry.route) } label: {
                            PhoneStationRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        Rule(color: Palette.outline)
                    }
                }
            }
        }
    }
}

private struct PhoneStationRow: View {
    let entry: StationEntry
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        LiveShowReader(providerID: entry.station.providerID, stationID: entry.station.id) { show in
            HStack(alignment: .top, spacing: 14) {
                ArtworkView(
                    remoteURL: show?.artworkURL,
                    side: 72,
                    glyphScale: 0.3,
                    markURL: StationMark.logoURL(for: entry.station.providerID)
                )
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(entry.station.name)
                            .font(Typeface.mono(13, weight: .medium))
                        if player.isCurrent(entry.station.id) && player.isPlaying {
                            Text("LIVE")
                                .microLabel(1.6, size: 9)
                                .foregroundStyle(Palette.inverseInk)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Palette.inverse)
                        }
                    }
                    Text(show?.title ?? entry.station.strapline)
                        .font(Typeface.mono(12))
                        .foregroundStyle(Palette.ink.opacity(0.75))
                        .lineLimit(2)
                    Text(entry.location)
                        .font(Typeface.mono(10.5))
                        .foregroundStyle(Palette.inkFaint)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
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
