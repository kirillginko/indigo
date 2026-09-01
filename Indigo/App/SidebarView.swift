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
}

/// The sidebar reads like descending through a record collection: every band
/// has its own gradient, and each successive band begins a little deeper.
private enum SidebarBand: Int {
    case library, radio, nts, kiosk, noods, lot, dublab, alhara, cashmere, lyl, explore

    var depth: Double { Double(rawValue) / 10.0 }
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
    /// Somewhere to keep the fold that is not view state, so writing to it
    /// during a read does not invalidate anything.
    @State private var held = LibraryCounts()

    private final class LibraryCounts {
        var trackCount = -1
        var value: (tracks: Int, albums: Int, artists: Int) = (0, 0, 0)
    }

    @State private var isLibraryExpanded = true
    @State private var isRadioExpanded = true
    @State private var isExploreExpanded = true
    @State private var expandedRadios: Set<RadioSidebarGroup> = [.nts]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            wordmark
            Rule(color: Palette.outline)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    directoryHeader("Library", expanded: isLibraryExpanded, band: .library) {
                        isLibraryExpanded.toggle()
                    }
                    // Read once. Three reads meant three fetches.
                    let library = counts
                    if isLibraryExpanded {
                        row(.tracks, label: "Tracks", trailing: count(library.tracks), band: .library)
                        row(.albums, label: "Albums", trailing: count(library.albums), band: .library)
                        row(.artists, label: "Artists", trailing: count(library.artists), band: .library)
                    }

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

                    directoryHeader("Explore", expanded: isExploreExpanded, band: .explore) {
                        isExploreExpanded.toggle()
                    }
                    if isExploreExpanded {
                        row(.crate, label: "Crate", trailing: crateCount, band: .explore)
                        row(.dig, label: "Dig", trailing: nil, band: .explore)
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // The darkest band is also the sidebar's floor. When directories are
        // collapsed, the newly exposed space continues the colour story all
        // the way down instead of revealing the neutral chrome background.
        .background(bandGradient(.explore))
        .onChange(of: appState.route) { _, route in
            if route == .tracks || route == .albums || route == .artists {
                isLibraryExpanded = true
            }
            if route == .crate || route == .dig {
                isExploreExpanded = true
            }
            if let group = radioGroup(for: route) {
                isRadioExpanded = true
                expandedRadios.insert(group)
            }
        }
    }

    // MARK: Pieces

    private func bandGradient(_ band: SidebarBand) -> some View {
        let depth = band.depth
        return LinearGradient(
            colors: [
                Color(hue: 0.60 + depth * 0.12,
                      saturation: 0.28 + depth * 0.40,
                      brightness: 0.68 - depth * 0.52),
                Color(hue: 0.62 + depth * 0.11,
                      saturation: 0.36 + depth * 0.38,
                      brightness: 0.55 - depth * 0.44)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

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

    private func directoryHeader(
        _ title: String,
        expanded: Bool,
        band: SidebarBand,
        toggle: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(Typeface.body(12.5, weight: .bold))
                    .textCase(.uppercase)
                    // Nimbus needs much less air than the mono labels. A
                    // restrained track keeps the directory names crisp
                    // without turning them into utility metadata.
                    .tracking(0.65)
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.white.opacity(0.72))
            .padding(.horizontal, 14)
            .padding(.top, 15)
            .padding(.bottom, 9)
            .background(bandGradient(band))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(title)")
    }

    private var radioDirectoryHeader: some View {
        directoryHeader("Radio", expanded: isRadioExpanded, band: .radio) {
            isRadioExpanded.toggle()
        }
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
                            .font(Typeface.body(13, weight: .bold))
                            .tracking(0.1)
                            .foregroundStyle(Color.white.opacity(active ? 1 : 0.82))
                        if isPlaying {
                            LivePulseDot()
                        }
                    }
                    Text(location)
                        .font(Typeface.mono(8.5))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.white.opacity(0.62))
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .background(bandGradient(band(for: group)))
            .overlay(Color.white.opacity(active ? 0.045 : 0))
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
        indent: CGFloat = 0,
        band explicitBand: SidebarBand? = nil
    ) -> some View {
        let selected = appState.route == route && appState.detail == nil
        let resolvedBand = explicitBand ?? radioGroup(for: route).map(band(for:))
        let foreground = Color.white.opacity(0.9)
        let secondaryForeground = Color.white.opacity(0.52)
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
            .background {
                if selected {
                    Palette.inverse
                } else if let resolvedBand {
                    bandGradient(resolvedBand)
                        .overlay(Color.white.opacity(indent > 0 ? 0.012 : 0))
                }
            }
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

    private func band(for group: RadioSidebarGroup) -> SidebarBand {
        switch group {
        case .nts: .nts
        case .kiosk: .kiosk
        case .noods: .noods
        case .lot: .lot
        case .dublab: .dublab
        case .alhara: .alhara
        case .cashmere: .cashmere
        case .lyl: .lyl
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

    /// The counts beside Tracks, Albums and Artists.
    ///
    /// This was computed, and `body` read it three times — once per row — so
    /// one redraw fetched the whole `Track` table three times and walked it
    /// three times, building two sets each pass. On the main thread, in the
    /// sidebar, which is on screen on every page of the app.
    ///
    /// Sampling the running app put ninety of a hundred and four samples of
    /// the sidebar's `body` inside this one getter, in a synchronous
    /// CoreData fetch. That is a stutter every page pays, and it is why
    /// scrolling caught while anything at all was being written.
    ///
    /// The walk is now kept until the library actually changes, and `body`
    /// reads the answer once.
    private var counts: (tracks: Int, albums: Int, artists: Int) {
        let all = tracks
        if held.trackCount == all.count { return held.value }
        var albums = Set<String>()
        var artists = Set<String>()
        for track in all {
            albums.insert(track.albumKey)
            artists.insert(track.artistKey)
        }
        let answer = (all.count, albums.count, artists.count)
        held.trackCount = all.count
        held.value = answer
        return answer
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
