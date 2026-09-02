//
//  IndigoApp.swift
//  Indigo
//

import SwiftUI
import SwiftData

/// Window identifiers, so opening one by name isn't a loose string.
enum IndigoWindow {
    static let main = "indigo.main"
    static let mini = "indigo.mini"
}

@main
struct IndigoApp: App {
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
    @State private var library = LibraryStore(container: Persistence.container)
    @State private var crate = CrateService(context: Persistence.container.mainContext)
    @State private var dig = DigStore(context: Persistence.container.mainContext)

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
                .environment(library)
                .environment(crate)
                .environment(dig)
                .modelContainer(Persistence.container)
                .frame(minWidth: 900, minHeight: 580)
                .task {
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
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            PlaybackCommands(player: player, library: library)
            CommandGroup(after: .toolbar) {
                Button("Find") { appState.requestSearchFocus() }
                    .keyboardShortcut("f", modifiers: .command)
                MiniPlayerCommand()
            }
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
                .environment(library)
                .environment(crate)
                .environment(dig)
                .modelContainer(Persistence.container)
        }
        .defaultSize(width: 320, height: 210)
        .windowResizability(.contentSize)

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
