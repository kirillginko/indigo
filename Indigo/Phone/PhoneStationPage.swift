//
//  PhoneStationPage.swift
//  Indigo
//
//  A station on the phone, the page behind a Live slide's info button: what
//  is on now, the picture the width of the screen with its words in boxes in
//  the Live slide's order -- city, show, genres -- then a play box, the slot,
//  what is on next, what the show and the station are, and every show the
//  station keeps, as the Shows tab's grid.
//
//  One page for all thirteen stations, from what every station gives: its
//  directory entry, its stream, and what is on now and next. Off the phone
//  each station keeps its own page.
//

import SwiftUI

extension Route {
    /// Whether this is a station's own page.
    var isStation: Bool {
        switch self {
        case .station, .kioskStation, .noodsStation, .lotStation, .dublabStation, .alharaStation,
             .cashmereStation, .lylStation, .idaStation, .radio80000Station, .panikStation,
             .rovrStation, .n10asStation:
            true
        default:
            false
        }
    }
}

/// Finds the station a route names, and its stream; nil if none matches.
struct PhoneStationRoute<Fallback: View>: View {
    let route: Route
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        StationDirectory { entries, playable in
            if let entry = entries.first(where: { $0.route == route }) {
                PhoneStationPage(entry: entry, item: playable(entry))
            } else {
                fallback()
            }
        }
    }
}

struct PhoneStationPage: View {
    let entry: StationEntry
    let item: MediaItem?

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player

    private var isPlaying: Bool { item.map { player.isCurrent($0.id) && player.isPlaying } ?? false }
    private var city: String {
        entry.location.split(separator: ",").first.map(String.init) ?? entry.location
    }

    var body: some View {
        LiveShowReader(providerID: entry.station.providerID, stationID: entry.station.id) { show, next in
            ScrollView {
                VStack(spacing: 0) {
                    PhoneDetailHero(
                        kind: city,
                        title: show?.title ?? entry.station.name,
                        subtitle: show == nil ? nil : entry.station.name,
                        imageURL: show?.artworkURL,
                        genres: show?.genres ?? []
                    )
                    VStack(alignment: .leading, spacing: 22) {
                        nowAndNext(show, next)
                        about(show)
                        sections
                        shows
                    }
                    .padding(.vertical, 18)
                    .padding(.horizontal, PhoneLayout.margin)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .top) { topBar }
            .foregroundStyle(.white)
        }
        .onAppear { PhoneFeeds.shared.lastStationRoute = entry.route }
    }

    // MARK: Parts

    /// Back to Live, which keeps the station that was on screen; and the
    /// station's name with its red dot.
    private var topBar: some View {
        HStack {
            Button { appState.select(.live) } label: { PhoneBackGlyph() }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Live")
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1, green: 0.3, blue: 0.2)).frame(width: 7, height: 7)
                Text(entry.station.name)
                    .font(Typeface.mono(14))
                    .tracking(1.2)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 18)
            .frame(height: 46)
            // Rounded, on the player's moving field, as the mini player is.
            .background { PlayerShaderBackdrop() }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            Spacer()
            Color.clear.frame(width: 46, height: 46)
        }
        .padding(.horizontal, 16)
        .foregroundStyle(.white)
    }

    private func nowAndNext(_ show: RadioShow?, _ next: RadioShow?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item {
                Button {
                    if player.isCurrent(item.id) { player.toggle() } else { player.playRadio(item) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14))
                        Text(isPlaying ? "Pause" : "Play live")
                            .font(Typeface.mono(15))
                            .tracking(1.4)
                            .textCase(.uppercase)
                    }
                    .foregroundStyle(Chip.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Chip.green)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let slot = show?.slot {
                ChipFlow {
                    Chip(text: slot, tone: .sheen, size: 12.5)
                    Chip(text: "On now", size: 12.5, uppercase: true)
                }
                .frame(maxWidth: .infinity)
            }
            if let next {
                NextUpRows(next: next)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func about(_ show: RadioShow?) -> some View {
        let summary = show?.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A strapline that only says the city again says nothing.
        let strapline = entry.station.strapline.caseInsensitiveCompare(city) == .orderedSame
            ? "" : entry.station.strapline
        if (summary?.isEmpty == false) || !strapline.isEmpty {
            DigSection(title: "About") {
                VStack(alignment: .leading, spacing: 10) {
                    if let summary, !summary.isEmpty {
                        Text(summary)
                            .font(Typeface.mono(12.5))
                            .lineSpacing(3)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !strapline.isEmpty {
                        Text(strapline)
                            .font(Typeface.mono(11.5))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        }
    }

    /// Everything else the Mac lists under the station, as boxes to open.
    @ViewBuilder
    private var sections: some View {
        let found = PhoneStationSection.of(providerID: entry.station.providerID)
        if !found.isEmpty {
            DigSection(title: "Browse") {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(found) { section in
                        Button { appState.select(section.route) } label: {
                            HStack(spacing: 8) {
                                Text(section.title)
                                    .font(Typeface.mono(14))
                                    .tracking(1.2)
                                    .textCase(.uppercase)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .background(Chip.black)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Every show the station keeps: the Shows tab's grid for it, edge to edge.
    @ViewBuilder
    private var shows: some View {
        if let key = PhoneShowsView.key(forProvider: entry.station.providerID) {
            DigSection(title: "Shows") {
                PhoneShowsView(embeddedStation: key)
                    .padding(.horizontal, -PhoneLayout.margin)
            }
        }
    }
}
