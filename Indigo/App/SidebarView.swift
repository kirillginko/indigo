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
    case nts, kiosk, noods, lot, dublab, alhara, cashmere, lyl

    var shade: Double {
        guard let index = Self.allCases.firstIndex(of: self) else { return 0 }
        return Double(index) / Double(max(Self.allCases.count - 1, 1))
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(NTSProvider.self) private var nts
    @Environment(KioskProvider.self) private var kiosk
    @Environment(NoodsProvider.self) private var noods
    @Environment(LotProvider.self) private var lot
    @Environment(DublabProvider.self) private var dublab
    @Environment(AlharaProvider.self) private var alhara
    @Environment(CashmereProvider.self) private var cashmere
    @Environment(LYLProvider.self) private var lyl
    @Environment(CrateService.self) private var crate
    @Environment(PlaybackCoordinator.self) private var player

    @Query private var tracks: [Track]
    @State private var isRadioExpanded = true
    @State private var expandedRadios: Set<RadioSidebarGroup> = [.nts]
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

                    radioDirectoryHeader
                    if isRadioExpanded {
                    radioSection("NTS", location: "London, UK", group: .nts)
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

                    radioSection("Kiosk Radio", location: "Brussels, Belgium", group: .kiosk)
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

                    radioSection("Noods Radio", location: "Bristol, UK", group: .noods)
                    if expandedRadios.contains(.noods) {
                        row(
                            .noodsStation,
                            label: "Live",
                            trailing: player.isCurrent(noods.station.id) ? "live" : nil,
                            isLive: player.isCurrent(noods.station.id) && player.isPlaying,
                            indent: 10
                        )
                        row(.noodsShows, label: "Discover", trailing: nil, indent: 10)
                        row(.noodsResidents, label: "Residents", trailing: nil, indent: 10)
                        row(.noodsCollections, label: "Collections", trailing: nil, indent: 10)
                    }

                    radioSection("The Lot Radio", location: "Brooklyn, New York", group: .lot)
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

                    radioSection("dublab", location: "Los Angeles, USA", group: .dublab)
                    if expandedRadios.contains(.dublab) {
                        row(
                            .dublabStation,
                            label: "Live",
                            trailing: player.isCurrent(dublab.station.id) ? "live" : nil,
                            isLive: player.isCurrent(dublab.station.id) && player.isPlaying,
                            indent: 10
                        )
                        row(.dublabArchive, label: "Archive", trailing: nil, indent: 10)
                        row(.dublabDJs, label: "DJs", trailing: nil, indent: 10)
                    }

                    radioSection("Radio alHara", location: "Bethlehem, Palestine", group: .alhara)
                    if expandedRadios.contains(.alhara) {
                        // alHara publishes only its channels — no archive and
                        // no roster — so the group is the channels themselves.
                        ForEach(alhara.visibleStations) { station in
                            row(
                                .alharaStation(station.id),
                                label: station.name,
                                trailing: player.isCurrent(station.id) ? "live" : nil,
                                isLive: player.isCurrent(station.id) && player.isPlaying,
                                indent: 10
                            )
                        }
                        row(.alharaArchive, label: "Archive", trailing: nil, indent: 10)
                    }

                    radioSection("Cashmere Radio", location: "Berlin, Germany", group: .cashmere)
                    if expandedRadios.contains(.cashmere) {
                        row(
                            .cashmereStation,
                            label: "Live",
                            trailing: player.isCurrent(cashmere.station.id) ? "live" : nil,
                            isLive: player.isCurrent(cashmere.station.id) && player.isPlaying,
                            indent: 10
                        )
                        row(.cashmereArchive, label: "Archive", trailing: nil, indent: 10)
                        row(.cashmereShows, label: "Shows", trailing: nil, indent: 10)
                    }

                    radioSection("LYL Radio", location: "Lyon, France", group: .lyl)
                    if expandedRadios.contains(.lyl) {
                        row(
                            .lylStation,
                            label: "Live",
                            trailing: player.isCurrent(lyl.station.id) ? "live" : nil,
                            isLive: player.isCurrent(lyl.station.id) && player.isPlaying,
                            indent: 10
                        )
                        row(.lylArchive, label: "Archive", trailing: nil, indent: 10)
                        row(.lylShows, label: "Shows", trailing: nil, indent: 10)
                    }
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
            if let group = radioGroup(for: route) {
                isRadioExpanded = true
                expandedRadios.insert(group)
            }
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

    private var radioDirectoryHeader: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                isRadioExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Text("Radio").microLabel(1.6)
                Spacer(minLength: 4)
                Image(systemName: isRadioExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Palette.inkFaint)
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isRadioExpanded ? "Collapse" : "Expand") radio stations")
    }

    private func radioSection(_ title: String, location: String, group: RadioSidebarGroup) -> some View {
        let expanded = expandedRadios.contains(group)
        let active = radioGroup(for: appState.route) == group
        let isPlaying = isRadioGroupPlaying(group)
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                if expanded { expandedRadios.remove(group) }
                else { expandedRadios.insert(group) }
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(Typeface.mono(10.5, weight: .semibold))
                            .foregroundStyle(radioForeground(for: group).opacity(active ? 1 : 0.82))
                        if isPlaying {
                            LivePulseDot()
                        }
                    }
                    Text(location)
                        .font(Typeface.mono(8.5))
                        .foregroundStyle(radioForeground(for: group).opacity(0.58))
                }
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(radioForeground(for: group).opacity(0.62))
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .background(radioShade(for: group))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(title)")
    }

    /// The original dark indigo family, now stretched across a wider value
    /// range so adjacent stations remain unmistakably separate.
    private func radioShade(for group: RadioSidebarGroup?) -> Color {
        let shade = group?.shade ?? 0
        return Color(
            hue: 0.68,
            saturation: 0.42 + (shade * 0.10),
            brightness: 0.43 - (shade * 0.29)
        )
    }

    private func radioForeground(for group: RadioSidebarGroup?) -> Color {
        Color.white
    }

    private func row(
        _ route: Route,
        label: String,
        trailing: String?,
        isLive: Bool = false,
        indent: CGFloat = 0
    ) -> some View {
        let selected = appState.route == route && appState.detail == nil
        let group = indent > 0 ? radioGroup(for: route) : nil
        let foreground = group.map { radioForeground(for: $0) } ?? Palette.ink
        let secondaryForeground = group.map { radioForeground(for: $0).opacity(0.55) } ?? Palette.inkFaint
        return Button {
            appState.select(route)
        } label: {
            HStack(spacing: 8) {
                Text(label)
                    .font(Typeface.body(12.5, weight: selected ? .semibold : .regular))
                if isLive {
                    LivePulseDot()
                }
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .microLabel(0.9)
                        .foregroundStyle(
                            selected ? Palette.inverseInk.opacity(0.7) : secondaryForeground
                        )
                }
            }
            .foregroundStyle(selected ? Palette.inverseInk : foreground)
            .padding(.leading, 14 + indent)
            .padding(.trailing, 14)
            .frame(height: Metrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected
                    ? Palette.inverse
                    : (indent > 0 ? radioShade(for: group) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func radioGroup(for route: Route) -> RadioSidebarGroup? {
        switch route {
        case .station, .ntsLatest, .ntsShows, .ntsMixtapes, .ntsSearch: .nts
        case .kioskStation, .kioskMoods, .kioskShows: .kiosk
        case .noodsStation, .noodsShows, .noodsResidents, .noodsCollections: .noods
        case .lotStation, .lotIndex, .lotShows: .lot
        case .dublabStation, .dublabArchive, .dublabDJs: .dublab
        case .alharaStation, .alharaArchive: .alhara
        case .cashmereStation, .cashmereArchive, .cashmereShows: .cashmere
        case .lylStation, .lylArchive, .lylShows: .lyl
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

    private func isRadioGroupPlaying(_ group: RadioSidebarGroup) -> Bool {
        guard player.isPlaying else { return false }
        switch group {
        case .nts:
            return nts.stations.contains { player.isCurrent($0.id) } || isPlayingMixtape
        case .kiosk:
            return player.isCurrent(kiosk.station.id)
        case .noods:
            return player.isCurrent(noods.station.id)
        case .lot:
            return player.isCurrent(lot.station.id)
        case .dublab:
            return player.isCurrent(dublab.station.id)
        case .alhara:
            return alhara.visibleStations.contains { player.isCurrent($0.id) }
        case .cashmere:
            return player.isCurrent(cashmere.station.id)
        case .lyl:
            return player.isCurrent(lyl.station.id)
        }
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

private struct LivePulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.live.opacity(0.8), lineWidth: 1)
                .frame(width: 11, height: 11)
                .scaleEffect(reduceMotion ? 1 : (isPulsing ? 1.55 : 0.65))
                .opacity(reduceMotion ? 0 : (isPulsing ? 0 : 0.8))
            Circle()
                .fill(Palette.live)
                .frame(width: 6, height: 6)
        }
        .frame(width: 12, height: 12)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.05).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
        .accessibilityHidden(true)
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
