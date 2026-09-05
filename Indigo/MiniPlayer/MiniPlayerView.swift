//
//  MiniPlayerView.swift
//  Indigo
//
//  The compact window. Crate and DIG have to be reachable without reopening
//  the main window — a discovery you can't keep in the two seconds you have is
//  a discovery lost, and that is the whole product.
//

import SwiftUI
import SwiftData

struct MiniPlayerView: View {
    @Environment(AppState.self) private var appState
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
    @Environment(PanikProvider.self) private var panik
    @Environment(RovrProvider.self) private var rovr
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = crate.revision
        let summary = NowPlayingSummary.make(
            item: player.current, showTitle: liveShow?.title, context: crate.context
        )

        VStack(alignment: .leading, spacing: 0) {
            header(summary)
            Rule(color: Palette.outline)

            VStack(alignment: .leading, spacing: 12) {
                titles(summary)
                if !summary.status.isEmpty {
                    StatusRow(items: summary.status)
                }
                if !summary.isLive, player.hasSomethingLoaded {
                    scrubber
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
            Rule(color: Palette.outline)
            controls(summary)
        }
        .frame(minWidth: 300, minHeight: 196)
        .background(Palette.paper)
        .foregroundStyle(Palette.ink)
    }

    // MARK: Header

    private func header(_ summary: NowPlayingSummary) -> some View {
        HStack(spacing: 8) {
            Text(summary.source)
                .microLabel(1.8, size: 10)
                .foregroundStyle(Palette.ink)
                // Identified so the second window can be driven in UI tests.
                // macOS exposes SwiftUI Text as the accessibility *value*
                // (uppercased, as drawn), so assertions read `.value`.
                .accessibilityIdentifier("mini.source")
            Spacer(minLength: 8)
            if summary.isLive {
                LiveBadge()
            } else if player.isBuffering {
                Text("Buffering")
                    .microLabel(1.2, size: 9)
                    .foregroundStyle(Palette.inkFaint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func titles(_ summary: NowPlayingSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.primary)
                .microLabel(1.6, size: 13)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mini.primary")
            if let secondary = summary.secondary, !secondary.isEmpty {
                Text(secondary)
                    .font(Typeface.mono(10.5))
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mini.secondary")
            }
        }
    }

    private var scrubber: some View {
        HStack(spacing: 9) {
            Text(TimeFormat.clock(player.position))
                .font(Typeface.mono(9.5))
                .foregroundStyle(Palette.inkFaint)
                .monospacedDigit()
                .frame(width: 46, alignment: .leading)
            HairlineSlider(value: player.progress, enabled: player.canSeek) { fraction in
                player.seek(fraction: fraction)
            }
            Text(TimeFormat.clock(player.duration > 0 ? player.duration : nil))
                .font(Typeface.mono(9.5))
                .foregroundStyle(Palette.inkFaint)
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
    }

    // MARK: Controls

    private func controls(_ summary: NowPlayingSummary) -> some View {
        HStack(spacing: 10) {
            if !summary.isLive {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 11))
                }
                .buttonStyle(GlyphButtonStyle(size: 26))
                .disabled(!player.canSkipPrevious)
                .opacity(player.canSkipPrevious ? 1 : 0.25)
            }

            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(SolidSquareButtonStyle(size: 30))
            .disabled(!player.hasSomethingLoaded)
            .opacity(player.hasSomethingLoaded ? 1 : 0.35)

            if !summary.isLive {
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 11))
                }
                .buttonStyle(GlyphButtonStyle(size: 26))
                .disabled(!player.canSkipNext)
                .opacity(player.canSkipNext ? 1 : 0.25)
            }

            Spacer(minLength: 6)

            if let item = player.current {
                CrateButton(isCrated: crate.isCrated(nowPlaying: item, liveShow: liveShow)) {
                    crate.toggle(nowPlaying: item, liveShow: liveShow)
                }
                if let destination = digDestination(summary) {
                    DigButton {
                        appState.open(destination)
                        // DIG needs the main window; bring it forward rather
                        // than navigating somewhere nobody can see.
                        openWindow(id: IndigoWindow.main)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: Helpers

    /// A crated local track can be dug into straight away; anything else needs
    /// an identity first, which is what makes the button appear or not.
    private func digDestination(_ summary: NowPlayingSummary) -> DetailPage? {
        if let recording = summary.recording { return dig.destination(for: recording) }
        guard player.current?.kind == .track,
              let artist = player.current?.subtitle, !artist.isEmpty
        else { return nil }
        return .digArtist(mbid: nil, name: artist)
    }

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
        if item.sourceID == PanikProvider.providerID { return panik.now }
        if item.sourceID == RovrProvider.providerID { return rovr.now }
        if item.sourceID == NTSProvider.providerID { return nts.state(for: item.id)?.now }
        return nil
    }
}
