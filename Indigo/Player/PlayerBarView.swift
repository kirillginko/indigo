//
//  PlayerBarView.swift
//  Indigo
//
//  One bar for every source. It reads the coordinator and never asks which
//  engine is running — only whether the current item is live.
//
//  Artwork, then what is on, then the transport, then the volume — the order
//  the eye already expects from every player.
//

import SwiftUI
import SwiftData

struct PlayerBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(NTSProvider.self) private var nts
    @Environment(KioskProvider.self) private var kiosk
    @Environment(LotProvider.self) private var lot
    @Environment(DublabProvider.self) private var dublab
    @Environment(AlharaProvider.self) private var alhara
    @Environment(CashmereProvider.self) private var cashmere
    @Environment(LYLProvider.self) private var lyl
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig

    var body: some View {
        ZStack {
            PlayerGradientBackdrop()

            HStack(spacing: 0) {
                identity
                    .frame(width: 356)
                VRule(color: Palette.outline.opacity(0.72))
                transport
                    .frame(maxWidth: .infinity)
                VRule(color: Palette.outline.opacity(0.72))
                volume
                    .frame(width: 168)
            }
        }
        // Keep the player legible as a dark object regardless of the system
        // appearance used by the surrounding window.
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
    }

    // MARK: - Identity

    /// Artwork first and flush to the edge, then what is playing — the order
    /// the eye already expects from every player.
    private var identity: some View {
        HStack(spacing: 10) {
            artworkButton

            title
                .layoutPriority(1)

            Spacer(minLength: 6)

            if let item = player.current {
                // Reading `revision` keeps the glyph in step with crating done
                // anywhere else in the app.
                let _ = crate.revision
                CrateGlyphButton(isCrated: crate.isCrated(nowPlaying: item, liveShow: liveShow)) {
                    crate.toggle(nowPlaying: item, liveShow: liveShow)
                }
            }
        }
        .padding(.trailing, 10)
    }

    private var artworkButton: some View {
        Group {
            if let item = player.current, destination(for: item) != nil {
                Button { open(item) } label: { artwork }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(primaryTitle(for: item))")
                    .help("Open now playing")
            } else {
                artwork
            }
        }
    }

    /// Flush to the leading edge and the full height of the bar, so it reads
    /// as the end of the row rather than a tile dropped onto it.
    private var artwork: some View {
        ArtworkView(
            localKey: player.current?.artworkKey,
            remoteURL: liveShow?.artworkURL ?? player.current?.remoteArtworkURL,
            side: Metrics.playerBarHeight,
            glyphScale: 0.26,
            // Several stations publish no picture of what is on air. Falling
            // back to the station's own mark is better than an empty square
            // in the one place the listener always has in view.
            markURL: StationMark.logoURL(for: player.current?.sourceID)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var title: some View {
        if let item = player.current, destination(for: item) != nil {
            Button { open(item) } label: { titleLines(item) }
                .buttonStyle(.plain)
                .help("Open now playing")
        } else {
            titleLines(player.current)
        }
    }

    private func titleLines(_ item: MediaItem?) -> some View {
        let spoken = item.map { primaryTitle(for: $0) } ?? "Nothing playing"
        let under = item.map { secondaryTitle(for: $0) } ?? "Pick a track or a station"
        return VStack(alignment: .leading, spacing: 2) {
            MarqueeText(text: spoken.uppercased(), font: Typeface.banner(15), speed: 22, gap: 46)
                .foregroundStyle(Palette.ink)
            Text(under)
                .font(Typeface.mono(9.5))
                .foregroundStyle(Palette.inkMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel("\(spoken). \(under)")
    }

    /// Lifted into `NowPlayingLink` so every source can be tested; the view
    /// supplies only the two things that need its context — the album a local
    /// file belongs to, and whatever NTS says is on air.
    private func destination(for item: MediaItem) -> NowPlayingLink? {
        if let link = NowPlayingLink.destination(
            for: item,
            localAlbumKey: { path in localTrack(path: path)?.albumKey },
            liveNTSEpisode: liveShow?.detailID.flatMap(NTSEpisodeRef.decode)
        ) { return link }

        // The Crate's last resort, and the bar's: a piece of music with no
        // page of its own still has the page about the music — where it was
        // heard, and what was heard beside it.
        let summary = NowPlayingSummary.make(
            item: item, showTitle: liveShow?.title, context: crate.context
        )
        guard let recording = summary.recording,
              let page = dig.recordingDestination(for: recording)
        else { return nil }
        return .detail(page)
    }

    private func localTrack(path: String) -> Track? {
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.path == path })
        descriptor.fetchLimit = 1
        return try? crate.context.fetch(descriptor).first
    }

    private func open(_ item: MediaItem) {
        switch destination(for: item) {
        case .route(let route): appState.select(route)
        case .detail(let page): appState.open(page)
        case .search(let route, let query):
            appState.select(route)
            appState.searchText = query
        case nil: break
        }
    }

    private func primaryTitle(for item: MediaItem) -> String {
        guard item.isLive else { return item.title }
        // A station shows the show that's on; a mixtape is its own headline.
        return liveShow?.title ?? item.title
    }

    private func secondaryTitle(for item: MediaItem) -> String {
        guard item.isLive else {
            return [item.subtitle, item.detail]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }

        var parts: [String] = []
        if liveShow != nil {
            parts.append(item.title)
            if let location = liveShow?.location { parts.append(location) }
            if let slot = liveShow?.slot { parts.append(slot) }
        } else {
            if let detail = item.detail { parts.append(detail) }
            if let subtitle = item.subtitle { parts.append(subtitle) }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What the station is broadcasting right now. The banner is a headline,
    /// so it has to name the show rather than the channel — which means asking
    /// whichever provider owns the stream, not only NTS.
    private var liveShow: RadioShow? {
        guard let item = player.current, item.isLive else { return nil }
        switch item.sourceID {
        case KioskProvider.providerID: return kiosk.now
        case LotProvider.providerID: return lot.now
        case DublabProvider.providerID: return dublab.now
        case AlharaProvider.providerID: return alhara.now(for: item.id)
        case CashmereProvider.providerID: return cashmere.now
        case LYLProvider.providerID: return lyl.now
        default: return nts.state(for: item.id)?.now
        }
    }

    // MARK: - Transport

    private var transport: some View {
        VStack(spacing: 5) {
            HStack(spacing: 18) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 12))
                }
                .buttonStyle(GlyphButtonStyle())
                .disabled(!player.canSkipPrevious)
                .opacity(player.canSkipPrevious ? 1 : 0.25)

                Button { player.toggle() } label: {
                    ZStack {
                        if player.isBuffering {
                            BufferingGlyph()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 12))
                        }
                    }
                }
                .buttonStyle(SolidSquareButtonStyle())
                .disabled(!player.hasSomethingLoaded)
                .opacity(player.hasSomethingLoaded ? 1 : 0.35)

                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 12))
                }
                .buttonStyle(GlyphButtonStyle())
                .disabled(!player.canSkipNext)
                .opacity(player.canSkipNext ? 1 : 0.25)
            }

            if player.isLive {
                liveStrip
            } else {
                scrubStrip
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: 560)
    }

    private var scrubStrip: some View {
        HStack(spacing: 10) {
            Text(TimeFormat.clock(player.hasSomethingLoaded ? player.position : nil))
                .font(Typeface.mono(9.5))
                .foregroundStyle(Palette.inkFaint)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 54, alignment: .leading)
                .monospacedDigit()
                .accessibilityIdentifier("player.elapsed")

            HairlineSlider(value: player.progress, enabled: player.canSeek) { fraction in
                player.seek(fraction: fraction)
            }

            Text(TimeFormat.clock(player.duration > 0 ? player.duration : nil))
                .font(Typeface.mono(9.5))
                .foregroundStyle(Palette.inkFaint)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 54, alignment: .trailing)
                .monospacedDigit()
                .accessibilityIdentifier("player.duration")
        }
    }

    private var liveStrip: some View {
        HStack(spacing: 10) {
            LiveBadge()
                .frame(width: 46, alignment: .leading)

            if let fraction = liveShow?.elapsedFraction() {
                ProgressTrack(fraction: fraction, tint: Palette.live)
            } else {
                Rectangle()
                    .fill(Palette.outline.opacity(0.35))
                    .frame(height: 2)
                    .frame(maxWidth: .infinity)
            }

            Text(player.streamError != nil ? "Error" : (player.isBuffering ? "Buffering" : "On air"))
                .microLabel(1.0, size: 9)
                .foregroundStyle(player.streamError != nil ? Palette.live : Palette.inkFaint)
                .frame(width: 62, alignment: .trailing)
        }
        .frame(height: 16)
    }

    // MARK: - Volume

    private var volume: some View {
        HStack(spacing: 10) {
            Button {
                player.setVolume(player.volume > 0 ? 0 : 0.8)
            } label: {
                Image(systemName: volumeGlyph)
                    .font(.system(size: 11))
                    .frame(width: 16)
            }
            .buttonStyle(GlyphButtonStyle(size: 20))

            HairlineSlider(value: player.volume) { player.setVolume($0) }

            Text("\(Int((player.volume * 100).rounded()))")
                .font(Typeface.mono(9.5))
                .foregroundStyle(Palette.inkFaint)
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)
        }
        .padding(.horizontal, 16)
    }

    private var volumeGlyph: String {
        switch player.volume {
        case ..<0.01: "speaker.slash"
        case ..<0.34: "speaker.wave.1"
        case ..<0.7: "speaker.wave.2"
        default: "speaker.wave.3"
        }
    }
}

/// The timeline lives below the controls, so only the small backdrop redraws.
private struct PlayerGradientBackdrop: View {
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion: TimeInterval = 0
    @State private var lastFrame: Date?
    @State private var energy: Float = 0

    private var animating: Bool { player.isPlaying && !player.isBuffering && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { timeline in
            GeometryReader { proxy in
                Rectangle().fill(.black)
                    .colorEffect(ShaderLibrary.playerFlowField(
                        .float2(proxy.size), .float(motion), .float(reduceMotion ? 0 : energy)
                    ))
            }
            .onChange(of: timeline.date) { _, date in
                guard animating else { lastFrame = nil; energy = 0; return }
                let delta = min(0.1, max(0, date.timeIntervalSince(lastFrame ?? date)))
                lastFrame = date
                let target = player.audioLevel()
                let response = target > energy ? 14.0 : 4.0
                energy += (target - energy) * Float(1 - exp(-delta * response))
                motion += delta * (1 + Double(energy) * 1.8)
            }
        }
        .onChange(of: animating) { _, _ in lastFrame = nil; energy = 0 }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: - Controls

/// Flat, square, draggable track used for both seeking and volume.
struct HairlineSlider: View {
    var value: Double
    var enabled: Bool = true
    var thickness: CGFloat = 3
    var onChange: (Double) -> Void

    @State private var dragValue: Double?
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            let shown = dragValue ?? value
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Palette.outline.opacity(0.35))
                Rectangle()
                    .fill(enabled ? Palette.ink : Palette.inkFaint.opacity(0.5))
                    .frame(width: max(0, min(1, shown)) * geo.size.width)
                if enabled && (isHovering || dragValue != nil) {
                    Rectangle()
                        .fill(Palette.ink)
                        .frame(width: 2, height: thickness + 6)
                        .offset(x: max(0, min(1, shown) * geo.size.width - 1))
                }
            }
            .frame(height: thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard enabled, geo.size.width > 0 else { return }
                        dragValue = min(1, max(0, gesture.location.x / geo.size.width))
                    }
                    .onEnded { gesture in
                        guard enabled, geo.size.width > 0 else { return }
                        let fraction = min(1, max(0, gesture.location.x / geo.size.width))
                        dragValue = nil
                        onChange(fraction)
                    }
            )
            .onHover { isHovering = $0 }
        }
        .frame(height: 16)
    }
}

/// Three dots cycling while a stream fills its buffer.
struct BufferingGlyph: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.28)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.28) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Rectangle()
                        .frame(width: 3, height: 3)
                        .opacity(index == step ? 1 : 0.3)
                }
            }
        }
    }
}
