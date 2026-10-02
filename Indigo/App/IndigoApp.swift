//
//  IndigoApp.swift
//  Indigo
//

import SwiftUI
import CoreData
import SwiftData

/// Window identifiers, so opening one by name isn't a loose string.
enum IndigoWindow {
    static let main = "indigo.main"
    static let mini = "indigo.mini"
}

/// The entry point. A debug build checks first whether a run was asked for by
/// name -- the CloudKit schema seed -- so that it happens before `IndigoApp`'s
/// properties open the listener's stores. Without the argument, and always in a
/// release build, it is the app, unchanged.
@main
enum Launcher {
    static func main() {
        #if DEBUG
        if CommandLine.arguments.contains(CloudKitSeedGuard.argument) {
            MainActor.assumeIsolated { CloudKitSeedRunner.runAndExit() }
        }
        if CommandLine.arguments.contains(SyncRehearsalRunner.argument) {
            MainActor.assumeIsolated { SyncRehearsalRunner.runAndExit() }
        }
        if CommandLine.arguments.contains(TwoDeviceSyncRunner.argument) {
            MainActor.assumeIsolated { TwoDeviceSyncRunner.runAndExit() }
        }
        if CommandLine.arguments.contains(CounterRehearsalRunner.argument) {
            MainActor.assumeIsolated { CounterRehearsalRunner.runAndExit() }
        }
        if CommandLine.arguments.contains(CloudKitCountRunner.argument) || CommandLine.arguments.contains(CloudKitCountRunner.cleanArgument) {
            MainActor.assumeIsolated { CloudKitCountRunner.runAndExit() }
        }
        #endif
        IndigoApp.main()
    }
}

struct IndigoApp: App {
    /// The author of this process's own writes to the store, so the history
    /// observer can tell them from an import.
    static let writerAuthor = "indigo.app"

    init() {
        // Before the first view draws, so nothing renders in the fallback face.
        Typeface.registerBundledFonts()
    }

    @State private var appState = AppState()
    @State private var player = PlaybackCoordinator()
    @State private var nts = NTSProvider()
    @State private var browse = NTSBrowseStore(context: Persistence.container.mainContext)
    @State private var kiosk = KioskProvider()
    @State private var kioskBrowse = KioskBrowseStore()
    @State private var noods = NoodsProvider()
    @State private var noodsBrowse = NoodsBrowseStore()
    @State private var lot = LotProvider()
    @State private var lotBrowse = LotBrowseStore()
    @State private var dublab = DublabProvider()
    @State private var dublabBrowse = DublabBrowseStore()
    @State private var alhara = AlharaProvider()
    @State private var alharaBrowse = AlharaBrowseStore()
    @State private var cashmere = CashmereProvider()
    @State private var cashmereBrowse = CashmereBrowseStore()
    @State private var lyl = LYLProvider()
    @State private var lylBrowse = LYLBrowseStore()
    @State private var ida = IdaProvider()
    @State private var idaBrowse = IdaBrowseStore()
    @State private var radio80000 = Radio80000Provider()
    @State private var radio80000Browse = Radio80000BrowseStore()
    @State private var panik = PanikProvider()
    @State private var panikBrowse = PanikBrowseStore()
    @State private var rovr = RovrProvider()
    @State private var rovrBrowse = RovrBrowseStore()
    @State private var youtubeChannels = YouTubeChannelStore()
    @State private var n10as = N10ASProvider()
    @State private var n10asBrowse = N10ASBrowseStore()
    @State private var storeFailure = Persistence.openFailure
    @State private var library = LibraryStore(container: Persistence.container)
    @State private var crate = CrateService(context: Persistence.container.mainContext)
    @State private var dig = DigStore(context: Persistence.container.mainContext)
    /// Writes down what gets listened to. Held here rather than inside the
    /// player because the player has no store, and must not acquire one.
    @State private var witness = PlaybackWitness(context: Persistence.container.mainContext)

    var body: some Scene {
        WindowGroup(id: IndigoWindow.main) {
            RootView()
                .environment(appState)
                .environment(player)
                .environment(nts)
                .environment(browse)
                .environment(kiosk)
                .environment(kioskBrowse)
                .environment(noods)
                .environment(noodsBrowse)
                .environment(lot)
                .environment(lotBrowse)
                .environment(dublab)
                .environment(dublabBrowse)
                .environment(alhara)
                .environment(alharaBrowse)
                .environment(cashmere)
                .environment(cashmereBrowse)
                .environment(lyl)
                .environment(lylBrowse)
                .environment(ida)
                .environment(idaBrowse)
                .environment(radio80000)
                .environment(radio80000Browse)
                .environment(panik)
                .environment(panikBrowse)
                .environment(rovr)
                .environment(rovrBrowse)
                .environment(youtubeChannels)
                .environment(n10as)
                .environment(n10asBrowse)
                .environment(library)
                .environment(crate)
                .environment(dig)
                .modelContainer(Persistence.container)
                .alert(
                    "Your library couldn't be opened",
                    isPresented: Binding(
                        get: { storeFailure != nil },
                        set: { if !$0 { storeFailure = nil } }),
                    presenting: storeFailure
                ) { _ in
                    Button("OK", role: .cancel) {}
                } message: { failure in
                    Text("Nothing has been deleted. Until it opens, this session is not being saved, so anything you add will be gone when you quit.\n\n\(failure.explanation.map { $0 + "\n\n" } ?? "")\(failure.url.path)")
                }
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 580)
                #endif
                #if os(iOS) && DEBUG
                // The iPhone interface is not laid out yet; this is how its
                // store and sync are seen. Attached last, so it sits on the
                // screen and not on a layout wider than it. See
                // `SyncDiagnosticsView`.
                .modifier(ScreenCornerSyncButton())
                #endif
                .task {
                    // Rows another writer made -- once the listener's data
                    // syncs, CloudKit's import -- are found through the store's
                    // history and merged by key. See `HistoryObserver`.
                    guard !Persistence.isRunningTests, Persistence.userDataWritable else { return }
                    let context = Persistence.container.mainContext
                    context.author = Self.writerAuthor
                    let observer = HistoryObserver(context: context, ownAuthor: Self.writerAuthor)
                    observer.process()
                    for await _ in NotificationCenter.default.notifications(
                        named: .NSPersistentStoreRemoteChange
                    ) {
                        observer.process()
                    }
                }
                .task {
                    // Gives a row crated before it kept its own snapshot the
                    // snapshot. Not under test, which runs against the
                    // listener's real store, and not while that store is
                    // unopened: it writes the crate.
                    if !Persistence.isRunningTests, Persistence.userDataWritable {
                        UserDataDedupe(context: Persistence.container.mainContext).all()
                    }
                    witness.watch(player)
                    // Keep the picture backlog out of the way while a stream
                    // opens. See `DigStore.holdBackgroundWork`.
                    player.onPlaybackStarting = { [dig] in dig.holdBackgroundWork() }
                    player.onPlaybackSettled = { [dig] in dig.releaseBackgroundHold() }
                    // What EXPLORE showed last time, before anything is
                    // recomputed. A page that opens empty and grows its
                    // headline a second later has loaded twice.
                    dig.restoreExploreOffers()
                    // One-shot repair of rows that stored an artist as their
                    // own label. Off the main actor and off the critical path:
                    // nothing below waits for it, and it finds nothing to do
                    // on every launch after the first.
                    // Not under test, where this window is the test host and
                    // `Persistence.container` is the listener's real store.
                    //
                    // Found the hard way: running the suite swept 109 artists
                    // and 1,484 portrait rows in a live store, because the
                    // XCTest host launches this app and therefore this task.
                    // A repair that is correct is still not something a test
                    // run should do to somebody's data.
                    if !Persistence.isRunningTests {
                        Task.detached {
                            await BandcampEnricher.repairSelfPublishedLabels(
                                in: Persistence.container
                            )
                            // Pictures for the shows EXPLORE offers, which
                            // the appearance rows never kept. Its own task
                            // because it is paced across half a minute of
                            // requests and nothing below should wait on it.
                            Task {
                                let gained = await ShowArtworkBackfill.run(
                                    using: browse, context: Persistence.container.mainContext
                                )
                                // The cards are drawn from an answer kept for
                                // fifteen minutes and persisted across
                                // launches, so a picture that arrives after it
                                // was worked out would not be seen until it
                                // expired. See `invalidateExploreOffers`.
                                if gained > 0 { await dig.invalidateExploreOffers() }
                            }
                            // And the Discogs "no picture" pictures, for the
                            // same reasons and on the same terms. See
                            // `SpacerSweep`.
                            let swept = await SpacerSweep.run(in: Persistence.container)
                            if !swept.isEmpty {
                                Trace.note(
                                    "spacer.sweep artists=\(swept.artists) "
                                        + "portraits=\(swept.portraits) "
                                        + "releases=\(swept.releases)"
                                )
                            }
                        }
                    }
                    library.restore()
                    nts.startPolling()
                    kiosk.startPolling()
                    lot.startPolling()
                    dublab.startPolling()
                    alhara.startPolling()
                    cashmere.startPolling()
                    lyl.startPolling()
                    ida.startPolling()
                    radio80000.startPolling()
                    panik.startPolling()
                    rovr.startPolling()
                    n10as.startPolling()
                    // Warm both remote catalogues concurrently so station
                    // pages open with metadata and artwork URLs already ready.
                    async let kioskLibrary: Void = kioskBrowse.loadLibraryIfNeeded()
                    async let kioskMoods: Void = kioskBrowse.loadMoodsIfNeeded()
                    async let noodsDiscover: Void = noodsBrowse.loadDiscoverIfNeeded()
                    async let lotIndex: Void = lotBrowse.loadIndexIfNeeded()
                    async let dublabArchive: Void = dublabBrowse.loadArchiveIfNeeded()
                    _ = await (kioskLibrary, kioskMoods, noodsDiscover, lotIndex, dublabArchive)
                }
        }
        .defaultSize(width: 1140, height: 760)
        #if os(macOS)
        // The full player is what opens. Left to restoration, launch brings
        // back whichever windows were up at the last quit — which, after
        // switching to the mini player, was the mini player alone.
        .defaultLaunchBehavior(.presented)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            PlaybackCommands(player: player, library: library)
            CommandGroup(after: .toolbar) {
                Button("Find") { appState.requestSearchFocus() }
                    .keyboardShortcut("f", modifiers: .command)
                MiniPlayerCommand()
                #if DEBUG
                SyncTestCommand()
                #endif
            }
        }
        #endif

        #if os(macOS) && DEBUG
        Window("Sync Test", id: "sync-test") {
            SyncDiagnosticsView()
                .modelContainer(Persistence.container)
        }
        #endif

        #if os(macOS)
        // A separate window rather than a panel: it has to survive the main
        // window being closed, which is the point of a mini player.
        Window("Mini Player", id: IndigoWindow.mini) {
            MiniPlayerView()
                .indigoDefaultTypography()
                .environment(appState)
                .environment(player)
                .environment(nts)
                .environment(browse)
                .environment(kiosk)
                .environment(kioskBrowse)
                .environment(noods)
                .environment(noodsBrowse)
                .environment(lot)
                .environment(lotBrowse)
                .environment(dublab)
                .environment(dublabBrowse)
                .environment(alhara)
                .environment(alharaBrowse)
                .environment(cashmere)
                .environment(cashmereBrowse)
                .environment(lyl)
                .environment(lylBrowse)
                .environment(ida)
                .environment(idaBrowse)
                .environment(radio80000)
                .environment(radio80000Browse)
                .environment(panik)
                .environment(panikBrowse)
                .environment(rovr)
                .environment(rovrBrowse)
                .environment(youtubeChannels)
                .environment(n10as)
                .environment(n10asBrowse)
                .environment(library)
                .environment(crate)
                .environment(dig)
                .modelContainer(Persistence.container)
        }
        .defaultSize(width: 320, height: 210)
        .windowResizability(.contentSize)
        // No title bar of its own: the view draws a short strip in its
        // place, so the shader runs to the top edge. Dragging anywhere on the
        // background still moves the window.
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        // Only ever opened on purpose: by the switch, or by ⇧⌘M.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // The music folder lives here rather than at the foot of the sidebar:
        // it is a setting and a progress report, not part of browsing.
        MenuBarExtra {
            LibraryMenuBarContent()
                .indigoDefaultTypography()
                .environment(library)
        } label: {
            LibraryMenuBarLabel()
                .environment(library)
        }
        #endif
    }
}

#if os(macOS) && DEBUG
/// Opens the sync diagnostics and two-device test actions.
private struct SyncTestCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Sync Test") { openWindow(id: "sync-test") }
            .keyboardShortcut("y", modifiers: [.command, .shift])
    }
}
#endif

#if os(macOS)
/// Lives in its own view so it can reach `openWindow`, which a `Commands`
/// builder has no environment for.
private struct MiniPlayerCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Mini Player") { openWindow(id: IndigoWindow.mini) }
            .keyboardShortcut("m", modifiers: [.command, .shift])
    }
}
#endif

#if os(macOS)
/// Menu-bar equivalents for the transport, so the keyboard works even when the
/// media keys are grabbed by another app.
struct PlaybackCommands: Commands {
    let player: PlaybackCoordinator
    let library: LibraryStore

    var body: some Commands {
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!player.hasSomethingLoaded)
            Button("Next") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!player.canSkipNext)
            Button("Previous") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!player.canSkipPrevious)
            Divider()
            Button("Add Music Folders…") { library.chooseFolder() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Rescan Library") { library.scan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!library.hasLibrary)
        }
    }
}
#endif
