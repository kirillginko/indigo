//
//  MiniPlayerView.swift
//  Indigo
//
//  The compact window. Crate and DIG have to be reachable without reopening
//  the main window — a discovery you can't keep in the two seconds you have is
//  a discovery lost, and that is the whole product.
//
//  Drawn as a small copy of the player bar — the same shader, the same dark
//  ground — so the two read as one object at two sizes.
//

import SwiftUI
import SwiftData

struct MiniPlayerView: View {
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(NTSProvider.self) private var nts
    @Environment(KioskProvider.self) private var kiosk
    @Environment(LotProvider.self) private var lot
    @Environment(DublabProvider.self) private var dublab
    @Environment(AlharaProvider.self) private var alhara
    @Environment(CashmereProvider.self) private var cashmere
    @Environment(LYLProvider.self) private var lyl
    @Environment(IdaProvider.self) private var ida
    @Environment(Radio80000Provider.self) private var radio80000
    @Environment(N10ASProvider.self) private var n10as
    @Environment(PanikProvider.self) private var panik
    @Environment(RovrProvider.self) private var rovr
    @Environment(CrateService.self) private var crate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("mini.crateOpen") private var isCrateOpen = false

    private static let artworkSide: CGFloat = 76

    var body: some View {
        let _ = crate.revision
        let summary = NowPlayingSummary.make(
            item: player.current, showTitle: liveShow?.title, context: crate.context
        )

        VStack(alignment: .leading, spacing: 0) {
            identity(summary)
            Rule(color: Palette.outline.opacity(0.72))

            VStack(spacing: 6) {
                controls(summary)
                if summary.isLive {
                    liveStrip
                } else {
                    MiniScrubber()
                }
                playbackStatus(summary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Rule(color: Palette.outline.opacity(0.72))
            MiniCrateDrawer(isOpen: $isCrateOpen)
        }
        // The window follows the content's height, so opening the crate grows
        // it downward and closing it gives the room back.
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: 320, maxWidth: 520, alignment: .top)
        .background {
            ZStack {
                Color.black
                PlayerShaderBackdrop()
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(Palette.ink)
        // Legible as a dark object whatever the system appearance, exactly as
        // the player bar is.
        .environment(\.colorScheme, .dark)
        // The window hides its title bar, and the shader behind all this
        // already runs to the top edge. The strip is laid over that space
        // rather than put in the stack: the content keeps to the safe area,
        // so the window stays exactly as tall as what is in it.
        .overlay {
            titleStrip
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
        }
        // Where SoundCloud and Mixcloud play from when the main window is
        // closed. See `EmbedStandbySurface`.
        .background(alignment: .bottomTrailing) {
            EmbedStandbySurface(engine: player.embed)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: Identity

    private func identity(_ summary: NowPlayingSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkView(
                localKey: player.current?.artworkKey,
                remoteURL: liveShow?.artworkURL ?? player.current?.remoteArtworkURL,
                side: Self.artworkSide,
                glyphScale: 0.3,
                markURL: StationMark.logoURL(for: player.current?.sourceID)
            )
            .overlay(Rectangle().strokeBorder(Palette.outline.opacity(0.6), lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 5) {
                // Wrapped rather than a marquee: the window is narrow enough
                // that a scroll would never stop, and two lines fit.
                //
                // Identified so the second window can be driven in UI tests.
                // macOS exposes SwiftUI Text as the accessibility *value*
                // (uppercased, as drawn), so assertions read `.value`.
                Text(summary.primary.uppercased())
                    .font(Typeface.banner(15))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mini.primary")

                if let secondary = summary.secondary, !secondary.isEmpty {
                    Text(secondary)
                        .font(Typeface.mono(10))
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("mini.secondary")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// The window's title bar, drawn here. The real one is hidden so the
    /// shader can run behind this; the traffic lights are still the system's,
    /// sitting over the leading end.
    private var titleStrip: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 6)
            maximizeButton
                .padding(.trailing, 6)
        }
        .frame(height: Self.titleStripHeight)
        // A shade darker than the player under it, so the strip reads as the
        // window's edge rather than as more of the same field.
        .background(Color.black.opacity(0.45))
    }

    private static let titleStripHeight: CGFloat = 28

    // MARK: Controls

    /// The transport centred on the window, as it is in the bar; the keep
    /// actions sit over it on the trailing edge so they cannot push it off.
    private func controls(_ summary: NowPlayingSummary) -> some View {
        transport(summary)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) { actions(summary) }
    }

    private func transport(_ summary: NowPlayingSummary) -> some View {
        // All three always, as on the bar: a live show out of the crate
        // has the rest of the crate to skip to, and one with nothing either
        // side shows that by dimming rather than by the buttons vanishing.
        HStack(spacing: 14) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 11))
            }
            .buttonStyle(GlyphButtonStyle(size: 26))
            .disabled(!player.canSkipPrevious)
            .opacity(player.canSkipPrevious ? 1 : 0.25)

            Button { player.toggle() } label: {
                ZStack {
                    if player.isBuffering {
                        BufferingGlyph()
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11))
                    }
                }
            }
            .buttonStyle(SolidSquareButtonStyle(size: 30))
            .disabled(!player.hasSomethingLoaded)
            .opacity(player.hasSomethingLoaded ? 1 : 0.35)

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 11))
            }
            .buttonStyle(GlyphButtonStyle(size: 26))
            .disabled(!player.canSkipNext)
            .opacity(player.canSkipNext ? 1 : 0.25)
        }
    }

    private func actions(_ summary: NowPlayingSummary) -> some View {
        HStack(spacing: 6) {
            if let item = player.current {
                CrateGlyphButton(isCrated: crate.isCrated(nowPlaying: item, liveShow: liveShow)) {
                    crate.toggle(nowPlaying: item, liveShow: liveShow)
                }
            }
        }
    }

    private var liveStrip: some View {
        HStack(spacing: 10) {
            if let fraction = liveShow?.elapsedFraction() {
                ProgressTrack(fraction: fraction, tint: Palette.live)
            } else {
                Rectangle()
                    .fill(Palette.outline.opacity(0.35))
                    .frame(height: 2)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 16)
    }

    /// Under the seekbar, and always the same height: the window follows its
    /// content, so a line that came and went would resize it on every stall.
    private func playbackStatus(_ summary: NowPlayingSummary) -> some View {
        let text: String? = {
            if summary.isLive, player.streamError != nil { return "Error" }
            if player.isBuffering { return "Buffering" }
            return summary.isLive ? "On air" : nil
        }()
        return HStack(spacing: 6) {
            if player.isBuffering {
                BufferingGlyph()
                    .foregroundStyle(Palette.inkFaint)
            }
            Text(text ?? " ")
                .microLabel(1.0, size: 9)
                .foregroundStyle(player.streamError != nil && summary.isLive ? Palette.live : Palette.inkFaint)
        }
        .frame(height: 12)
        .frame(maxWidth: .infinity)
        .opacity(text == nil ? 0 : 1)
        .accessibilityHidden(text == nil)
    }

    /// Back to the full window, and the mini player out of the way.
    private var maximizeButton: some View {
        Button {
            openWindow(id: IndigoWindow.main)
            dismissWindow(id: IndigoWindow.mini)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(GlyphButtonStyle(size: 22))
        .help("Open the full player")
        .accessibilityLabel("Open the full player")
        .accessibilityIdentifier("mini.maximize")
    }

    // MARK: Helpers

    private var liveShow: RadioShow? {
        guard let item = player.current, item.isLive else { return nil }
        if item.sourceID == KioskProvider.providerID { return kiosk.now }
        if item.sourceID == LotProvider.providerID { return lot.now }
        if item.sourceID == DublabProvider.providerID { return dublab.now }
        if item.sourceID == AlharaProvider.providerID { return alhara.now(for: item.id) }
        if item.sourceID == CashmereProvider.providerID { return cashmere.now }
        if item.sourceID == LYLProvider.providerID { return lyl.now }
        // See `PlayerBarView.liveShow`: these four publish what is on and
        // were never asked.
        if item.sourceID == IdaProvider.providerID {
            return ida.channel(for: item.id).flatMap { ida.now(for: $0) }
        }
        if item.sourceID == Radio80000Provider.providerID { return radio80000.now }
        if item.sourceID == N10ASProvider.providerID { return n10as.now }
        if item.sourceID == PanikProvider.providerID { return panik.now }
        if item.sourceID == RovrProvider.providerID { return rovr.now }
        if item.sourceID == NTSProvider.providerID { return nts.state(for: item.id)?.now }
        return nil
    }
}

// MARK: - Scrubber

/// Its own view so the position ticking over redraws one row, not the window.
private struct MiniScrubber: View {
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        HStack(spacing: 9) {
            Text(TimeFormat.clock(player.hasSomethingLoaded ? player.position : nil))
                .font(Typeface.mono(9.5))
                .foregroundStyle(Palette.inkFaint)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 46, alignment: .leading)
            HairlineSlider(value: player.progress, enabled: player.canSeek) { fraction in
                player.seek(fraction: fraction)
            }
            Text(TimeFormat.clock(player.duration > 0 ? player.duration : nil))
                .font(Typeface.mono(9.5))
                .foregroundStyle(Palette.inkFaint)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

// MARK: - Crate drawer

/// The crate, one press away. Its own view, reading only the crate, so the
/// list is not rebuilt every time the scrubber moves.
private struct MiniCrateDrawer: View {
    @Binding var isOpen: Bool

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig
    @Environment(NTSBrowseStore.self) private var ntsBrowse
    @Environment(LotBrowseStore.self) private var lotBrowse
    @Environment(DublabBrowseStore.self) private var dublabBrowse
    @Environment(KioskBrowseStore.self) private var kioskBrowse
    @Environment(NoodsBrowseStore.self) private var noodsBrowse
    @Environment(AlharaBrowseStore.self) private var alharaBrowse
    @Environment(CashmereBrowseStore.self) private var cashmereBrowse
    @Environment(LYLBrowseStore.self) private var lylBrowse
    @Environment(IdaBrowseStore.self) private var idaBrowse
    @Environment(Radio80000BrowseStore.self) private var radio80000Browse
    @Environment(N10ASBrowseStore.self) private var n10asBrowse
    @Environment(PanikBrowseStore.self) private var panikBrowse
    @Environment(RovrBrowseStore.self) private var rovrBrowse
    @Environment(\.openWindow) private var openWindow

    @State private var items: [CrateItem] = []
    @AppStorage("mini.drawerTab") private var tab = MiniDrawerTab.crate
    /// Counted rather than fetched: the tab says how many tracks there are
    /// whether or not the library list has ever been opened.
    @Query private var libraryTracks: [Track]

    fileprivate static let rowHeight: CGFloat = 44
    fileprivate static let visibleRows: CGFloat = 5.5

    var body: some View {
        VStack(spacing: 0) {
            toggle
            if isOpen {
                Rule(color: Palette.outline.opacity(0.5))
                switch tab {
                case .crate: list
                case .library: MiniLibraryList()
                }
            }
        }
        .task(id: crate.revision) { reload() }
        .task(id: dig.revision) { reload() }
    }

    /// Two tabs and a chevron. A tab opens the drawer on its list; the one
    /// already showing, like the chevron, closes it.
    private var toggle: some View {
        HStack(spacing: 0) {
            tabButton(.crate, count: items.count)
                .accessibilityIdentifier("mini.crateToggle")
            VRule(color: Palette.outline.opacity(0.72))
            tabButton(.library, count: libraryTracks.count)
                .accessibilityIdentifier("mini.libraryToggle")
            Spacer(minLength: 6)
            Button {
                withAnimation(.easeOut(duration: 0.16)) { isOpen.toggle() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.inkMuted)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOpen ? "Hide list" : "Show list")
        }
        .frame(height: 30)
    }

    private func tabButton(_ which: MiniDrawerTab, count: Int) -> some View {
        let isShowing = isOpen && tab == which
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                if isShowing {
                    isOpen = false
                } else {
                    tab = which
                    isOpen = true
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(which.title)
                    .microLabel(1.8, size: 10)
                    .foregroundStyle(isShowing ? Palette.ink : Palette.inkMuted)
                Text("\(count)")
                    .microLabel(1.2, size: 9)
                    .foregroundStyle(Palette.inkFaint)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isShowing ? Palette.ink : Color.clear)
                    .frame(height: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isShowing ? "Hide \(which.title.lowercased())" : "Show \(which.title.lowercased())")
    }

    @ViewBuilder
    private var list: some View {
        if items.isEmpty {
            Text("Nothing crated yet")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
        } else {
            // A fixed height: the window sizes itself to its content, and a
            // scroll view has no height of its own to offer.
            let shown = min(CGFloat(items.count), Self.visibleRows)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        let source = crate.resolvedSources[item.id]
                        let current = isCurrent(source)
                        MiniCrateRow(
                            item: item,
                            isCurrent: current,
                            isPlaying: current && player.isPlaying,
                            height: Self.rowHeight,
                            play: { play(item) },
                            open: { open(item) },
                            remove: { crate.remove(item) }
                        )
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: shown * Self.rowHeight)
        }
    }

    private func reload() {
        items = crate.items()
        crate.refreshRowCache(digRevision: dig.revision) { dig.destination(for: $0) }
    }

    private func isCurrent(_ source: AudioSource?) -> Bool {
        guard case .play(let media) = source?.action else { return false }
        return player.isCurrent(media.id)
    }

    /// The crate's own rule: play what can be played, otherwise go to where
    /// it lives — which, from here, means bringing the main window forward.
    ///
    /// Resolved at the press, as the crate page does, rather than read from
    /// the row cache: a row drawn before the cache filled captured nothing,
    /// and pressing it did nothing.
    private func play(_ item: CrateItem) {
        switch SourceResolver(context: crate.context).best(item)?.action {
        case .play(let media):
            crate.play(item, as: media, on: player)
        case .openBroadcast(let page, _):
            appState.open(page)
            openWindow(id: IndigoWindow.main)
        case nil:
            // A show kept with no stream of its own: ask its station, which
            // has usually posted it since. See `CrateStreamResolver`.
            guard item.kind == .broadcast else {
                if !open(item) {
                    crate.notice = "\(item.displayTitle) has no playable source yet."
                }
                return
            }
            Task {
                if let media = await streams.media(for: item) {
                    crate.play(item, as: media, on: player)
                } else {
                    open(item)
                }
            }
        }
    }

    private var streams: CrateStreamResolver {
        CrateStreamResolver(
            crate: crate, nts: ntsBrowse, lot: lotBrowse, dublab: dublabBrowse,
            kiosk: kioskBrowse, noods: noodsBrowse, alhara: alharaBrowse,
            cashmere: cashmereBrowse, lyl: lylBrowse, ida: idaBrowse,
            radio80000: radio80000Browse, n10as: n10asBrowse, panik: panikBrowse,
            rovr: rovrBrowse
        )
    }

    /// The crate page's own routing — shows kept without a stream, artists
    /// and labels all go somewhere — then the main window, where it went.
    @discardableResult
    private func open(_ item: CrateItem) -> Bool {
        let opened = CrateNavigator(appState: appState, crate: crate, dig: dig, stations: streams.stations)
            .open(item)
        if opened { openWindow(id: IndigoWindow.main) }
        return opened
    }
}

enum MiniDrawerTab: String {
    case crate, library

    var title: String {
        switch self {
        case .crate: "Crate"
        case .library: "Library"
        }
    }
}

/// The local library, by artist and album, so a record plays through in
/// order. Its own view so the tracks are only read while the tab is showing.
private struct MiniLibraryList: View {
    @Environment(PlaybackCoordinator.self) private var player

    @Query(sort: [
        SortDescriptor(\Track.artistKey), SortDescriptor(\Track.albumKey),
        SortDescriptor(\Track.discNumber), SortDescriptor(\Track.trackNumber)
    ])
    private var tracks: [Track]

    var body: some View {
        if tracks.isEmpty {
            Text("No local music yet")
                .font(Typeface.mono(10))
                .foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
        } else {
            let shown = min(CGFloat(tracks.count), MiniCrateDrawer.visibleRows)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.persistentModelID) { offset, track in
                        let current = player.isCurrent(track.path)
                        MiniLibraryRow(
                            track: track,
                            isCurrent: current,
                            isPlaying: current && player.isPlaying,
                            height: MiniCrateDrawer.rowHeight
                        ) { play(from: offset) }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: shown * MiniCrateDrawer.rowHeight)
        }
    }

    /// The whole list is the queue, as on the Tracks page, so next carries
    /// on down it.
    private func play(from offset: Int) {
        if player.isCurrent(tracks[offset].path) {
            player.toggle()
        } else {
            player.play(tracks.mediaItems(), startingAt: offset)
        }
    }
}

private struct MiniLibraryRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let height: CGFloat
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(localKey: track.artworkKey, side: 30)
                .overlay(Rectangle().strokeBorder(
                    isCurrent ? Palette.accent : Palette.outline.opacity(0.5),
                    lineWidth: isCurrent ? 1.5 : Metrics.hairline
                ))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(Typeface.body(11.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
                    .lineLimit(1)
                Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Typeface.mono(9.5))
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: play) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(GlyphButtonStyle(size: 24))
            .opacity(isHovering || isCurrent ? 1 : 0.45)
            .accessibilityLabel(isPlaying ? "Pause \(track.title)" : "Play \(track.title)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: height)
        .background(isHovering ? Color.white.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .onHover { isHovering = $0 }
    }
}

private struct MiniCrateRow: View {
    let item: CrateItem
    let isCurrent: Bool
    let isPlaying: Bool
    let height: CGFloat
    let play: () -> Void
    let open: () -> Void
    let remove: () -> Void

    @State private var isHovering = false

    /// The crate page's shape: the row is a tap target and the play glyph is
    /// its own button. The whole row as one Button with a context menu on it
    /// swallowed the press.
    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(remoteURL: item.artworkURL, side: 30,
                        placeholder: .mosaic, mark: item.displayTitle)
                .overlay(Rectangle().strokeBorder(
                    isCurrent ? Palette.accent : Palette.outline.opacity(0.5),
                    lineWidth: isCurrent ? 1.5 : Metrics.hairline
                ))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(Typeface.body(11.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
                    .lineLimit(1)
                if let subtitle = item.displaySubtitle {
                    Text(subtitle)
                        .font(Typeface.mono(9.5))
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: play) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(GlyphButtonStyle(size: 24))
            .opacity(isHovering || isCurrent ? 1 : 0.45)
            .accessibilityLabel(isPlaying ? "Pause \(item.displayTitle)" : "Play \(item.displayTitle)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: height)
        .background(isHovering ? Color.white.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open in Indigo", action: open)
            Button("Remove from Crate", role: .destructive, action: remove)
        }
    }
}
