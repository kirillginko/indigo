//
//  SidebarView.swift
//  Indigo
//
//  Uppercase monospaced index down the left edge. Selection is a full-bleed
//  inverted block rather than a rounded pill — the whole app is square.
//

import SwiftUI
import SwiftData

private enum RadioSidebarGroup: CaseIterable, Hashable {
    case nts, kiosk, noods, lot
}

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(NTSProvider.self) private var nts
    @Environment(KioskProvider.self) private var kiosk
    @Environment(NoodsProvider.self) private var noods
    @Environment(LotProvider.self) private var lot
    @Environment(CrateService.self) private var crate
    @Environment(PlaybackCoordinator.self) private var player

    @Query private var tracks: [Track]
    @State private var expandedRadios = Set(RadioSidebarGroup.allCases)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            wordmark
            Rule(color: Palette.outline)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("Library")
                    row(.tracks, label: "Tracks", trailing: count(counts.tracks))
                    row(.albums, label: "Albums", trailing: count(counts.albums))
                    row(.artists, label: "Artists", trailing: count(counts.artists))

                    radioSection("NTS", group: .nts)
                    if expandedRadios.contains(.nts) {
                        ForEach(nts.stations) { station in
                            row(
                                .station(station.id),
                                label: station.name,
                                trailing: player.isCurrent(station.id) ? "live" : nil,
                                isLive: player.isCurrent(station.id) && player.isPlaying,
                                indent: 10
                            )
                        }
                        row(.ntsMixtapes, label: "Mixtapes",
                            trailing: nil, isLive: isPlayingMixtape, indent: 10)
                        row(.ntsLatest, label: "Latest", trailing: nil, indent: 10)
                        row(.ntsShows, label: "Shows", trailing: nil, indent: 10)
                    }

                    radioSection("Kiosk", group: .kiosk)
                    if expandedRadios.contains(.kiosk) {
                        row(
                            .kioskStation,
                            label: "Live",
                            trailing: player.isCurrent(kiosk.station.id) ? "live" : nil,
                            isLive: player.isCurrent(kiosk.station.id) && player.isPlaying,
                            indent: 10
                        )
                        row(.kioskMoods, label: "Moods", trailing: nil, indent: 10)
                        row(.kioskShows, label: "Shows", trailing: nil, indent: 10)
                    }

                    radioSection("Noods", group: .noods)
                    if expandedRadios.contains(.noods) {
                        row(
                            .noodsStation,
                            label: "Live",
                            trailing: player.isCurrent(noods.station.id) ? "live" : nil,
                            isLive: player.isCurrent(noods.station.id) && player.isPlaying,
                            indent: 10
                        )
                        row(.noodsShows, label: "Discover", trailing: nil, indent: 10)
                        row(.noodsFilter, label: "Filter", trailing: nil, indent: 10)
                        row(.noodsResidents, label: "Residents", trailing: nil, indent: 10)
                        row(.noodsCollections, label: "Collections", trailing: nil, indent: 10)
                    }

                    radioSection("The Lot", group: .lot)
                    if expandedRadios.contains(.lot) {
                        row(
                            .lotStation,
                            label: "Live",
                            trailing: player.isCurrent(lot.station.id) ? "live" : nil,
                            isLive: player.isCurrent(lot.station.id) && player.isPlaying,
                            indent: 10
                        )
                        row(.lotIndex, label: "Index", trailing: nil, indent: 10)
                        row(.lotShows, label: "Shows", trailing: nil, indent: 10)
                    }

                    section("Collection")
                    row(.crate, label: "Crate", trailing: crateCount)
                    row(.dig, label: "Dig", trailing: nil)
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.paperChrome)
        .onChange(of: appState.route) { _, route in
            if let group = radioGroup(for: route) { expandedRadios.insert(group) }
        }
    }

    // MARK: Pieces

    private var wordmark: some View {
        HStack(spacing: 6) {
            Text("Indigo")
                .microLabel(2.4, size: 11)
                .foregroundStyle(Palette.inverseInk)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Palette.inverse)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, Metrics.titleBarInset + 14)
        .padding(.bottom, 14)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .microLabel(1.6)
            .foregroundStyle(Palette.inkFaint)
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 7)
    }

    private func radioSection(_ title: String, group: RadioSidebarGroup) -> some View {
        let expanded = expandedRadios.contains(group)
        let active = radioGroup(for: appState.route) == group
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                if expanded { expandedRadios.remove(group) }
                else { expandedRadios.insert(group) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(title).microLabel(1.6)
                if active {
                    Circle().fill(Palette.accent).frame(width: 4, height: 4)
                }
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(active ? Palette.ink : Palette.inkFaint)
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(title)")
    }

    private func row(
        _ route: Route,
        label: String,
        trailing: String?,
        isLive: Bool = false,
        indent: CGFloat = 0
    ) -> some View {
        let selected = appState.route == route && appState.detail == nil
        return Button {
            appState.select(route)
        } label: {
            HStack(spacing: 8) {
                if isLive {
                    Circle()
                        .fill(selected ? Palette.inverseInk : Palette.live)
                        .frame(width: 5, height: 5)
                }
                Text(label)
                    .font(Typeface.body(12.5, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .microLabel(0.9)
                        .foregroundStyle(selected ? Palette.inverseInk.opacity(0.7) : Palette.inkFaint)
                }
            }
            .foregroundStyle(selected ? Palette.inverseInk : Palette.ink)
            .padding(.leading, 14 + indent)
            .padding(.trailing, 14)
            .frame(height: Metrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.inverse : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func radioGroup(for route: Route) -> RadioSidebarGroup? {
        switch route {
        case .station, .ntsLatest, .ntsShows, .ntsMixtapes, .ntsSearch: .nts
        case .kioskStation, .kioskMoods, .kioskShows: .kiosk
        case .noodsStation, .noodsShows, .noodsFilter, .noodsResidents, .noodsCollections: .noods
        case .lotStation, .lotIndex, .lotShows: .lot
        default: nil
        }
    }

    private func comingSoonRow(_ label: String) -> some View {
        HStack {
            Text(label)
                .font(Typeface.body(12.5))
                .foregroundStyle(Palette.inkFaint)
            Spacer(minLength: 4)
            Text("Soon")
                .microLabel(0.9)
                .foregroundStyle(Palette.inkFaint.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mixtapes stream like a station, so the sidebar shows the same live dot.
    private var isPlayingMixtape: Bool {
        guard player.isPlaying, let id = player.current?.id else { return false }
        return id.hasPrefix("nts.mixtape.")
    }

    /// Reading `revision` keeps the sidebar count live as things are crated.
    private var crateCount: String? {
        let _ = crate.revision
        return count(crate.count)
    }

    private func count(_ value: Int) -> String? {
        value > 0 ? value.formatted(.number) : nil
    }

    /// One pass over the index — cheaper than building full album/artist groups.
    private var counts: (tracks: Int, albums: Int, artists: Int) {
        var albums = Set<String>()
        var artists = Set<String>()
        for track in tracks {
            albums.insert(track.albumKey)
            artists.insert(track.artistKey)
        }
        return (tracks.count, albums.count, artists.count)
    }
}

/// Flat 2pt progress line, no rounding.
struct ProgressTrack: View {
    var fraction: Double
    var tint: Color = Palette.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.outline.opacity(0.4))
                Rectangle()
                    .fill(tint)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 2)
    }
}
