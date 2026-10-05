//
//  RootChrome.swift
//  Indigo
//
//  What every layout of the window carries, whatever it puts where: the parked
//  web player archived episodes play through, the notices, the work that must
//  outlive every page, and the folder importer. `bottomInset` is the height of
//  whatever the layout keeps at the bottom -- the player bar, or a phone's
//  player and tabs -- so notices and a brought-out video sit above it.
//

import SwiftUI
import UniformTypeIdentifiers

struct RootChrome: ViewModifier {
    var bottomInset: CGFloat
    /// Park the web player behind the page rather than over it. The phone's:
    /// an iPhone's web view does not take the 2% opacity, and parked at
    /// 320x180 it showed as a dark block in the corner. Under the page's
    /// opaque ground it is still in the window, which is all playback needs,
    /// and the phone has no video panel to bring it out to.
    var parksPlayerBehind = false

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(DigStore.self) private var dig
    @Environment(CrateService.self) private var crate
    @AppStorage(YouTubeVideoPanel.storageKey) private var showsYouTubeVideo = false

    /// The player's size parked behind the page. YouTube picks its stream for
    /// the player's size, and on an iPhone its smallest streams carry its
    /// thinnest audio: parked at a point square, uploads played at their
    /// worst. 320x180 picks a 360p-class stream. Parked over the page (Mac,
    /// iPad) it stays a point, so it cannot show.
    private static let parked = CGSize(width: 320, height: 180)

    func body(content: Content) -> some View {
        content
            .indigoDefaultTypography()
            .background(Palette.paper)
            .foregroundStyle(Palette.ink)
            // Parked, not hidden from WebKit: the widget has to remain in the
            // window for archived episodes to keep playing across navigation.
            //
            // A YouTube video can be brought out above the player, at the
            // smallest 16:9 size YouTube's player accepts (200 points tall),
            // with the glyph beside the crate button. Parked by default: the
            // listener is here for the music. SoundCloud and Mixcloud are audio
            // and have no picture to show. One view either way: the web view
            // cannot be in two places, and moving it keeps whatever is playing.
            .background(alignment: .bottomTrailing) {
                if parksPlayerBehind {
                    EmbedPlayerSurface(engine: player.embed)
                        .frame(width: Self.parked.width, height: Self.parked.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !parksPlayerBehind {
                    let showsVideo = player.embedProvider == .youtube && showsYouTubeVideo
                    EmbedPlayerSurface(engine: player.embed)
                        .frame(width: showsVideo ? 356 : 1, height: showsVideo ? 200 : 1)
                        .background(Color.black)
                        .overlay {
                            if showsVideo {
                                Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline)
                            }
                        }
                        .opacity(showsVideo ? 1 : 0.02)
                        .allowsHitTesting(false)
                        .accessibilityHidden(!showsVideo)
                        .padding(.trailing, showsVideo ? 16 : 0)
                        .padding(.bottom, showsVideo ? bottomInset + 16 : 0)
                }
            }
            .overlay(alignment: .bottom) { noticeOverlay }
            // Owned here because this view outlives every page. Started from a
            // detail page it was cancelled by the first navigation and, thanks
            // to its own start-once guard, never ran again -- which is why rows
            // filled in for a few seconds after launch and then stopped.
            .task { await dig.fillPortraitsInBackground() }
            // Debug builds only, and it writes to a file rather than the log --
            // see `MainThreadWatchdog`.
            .task { MainThreadWatchdog.shared.start() }
            #if !os(macOS)
            .fileImporter(
                isPresented: Binding(
                    get: { library.isPresentingImporter },
                    set: { library.isPresentingImporter = $0 }
                ),
                allowedContentTypes: [.folder],
                allowsMultipleSelection: true
            ) { result in
                library.handleImporterResult(result)
            }
            #endif
    }

    /// Errors surface here -- inline, dismissible, never modal.
    @ViewBuilder
    private var noticeOverlay: some View {
        VStack(spacing: 0) {
            // Stays for as long as the session cannot save. Not dismissible:
            // dismissing it would be agreeing to lose what comes next.
            if !Persistence.userDataWritable {
                NoticeStrip(text: Persistence.userDataNotice)
                Rule(color: Palette.outline)
            }
            if let notice = crate.notice {
                NoticeStrip(text: notice) { crate.notice = nil }
                Rule(color: Palette.outline)
            }
            if let notice = library.notice {
                NoticeStrip(text: notice) { library.notice = nil }
                Rule(color: Palette.outline)
            }
            if let notice = player.notice {
                NoticeStrip(text: notice) { player.notice = nil }
                Rule(color: Palette.outline)
            }
        }
        .padding(.bottom, bottomInset)
        .animation(.easeOut(duration: 0.15), value: library.notice)
        .animation(.easeOut(duration: 0.15), value: player.notice)
    }
}
