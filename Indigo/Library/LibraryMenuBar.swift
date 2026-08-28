//
//  LibraryMenuBar.swift
//  Indigo
//
//  Where the music folder lives, and what indexing is doing to it. This used
//  to sit at the foot of the sidebar, taking up room in every session to say
//  something that matters in about three of them — so it moved out to the
//  menu bar, where the icon can carry the state passively and the detail is
//  one click away.
//

#if os(macOS)
import SwiftUI

/// The menu itself. Plain text rows read as disabled items, which is exactly
/// what they are: status, not actions.
struct LibraryMenuBarContent: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Text(headline)
        if let detail {
            Text(detail)
        }

        Divider()

        if !library.rootURLs.isEmpty {
            ForEach(library.rootURLs, id: \.path) { folder in
                Menu(folder.lastPathComponent) {
                    Text(folder.path)
                    Divider()
                    Button("Remove Folder", role: .destructive) {
                        library.removeFolder(folder)
                    }
                }
            }
            Divider()
        }

        Button("Add Music Folders…") {
            library.chooseFolder()
        }
        Button("Rescan Library") {
            library.scan()
        }
        .disabled(!library.hasLibrary || library.scanState.isScanning)
    }

    private var headline: String {
        switch library.scanState {
        case .scanning: "Indexing \(library.rootDisplayName)"
        case .failed: "Library unavailable"
        case .idle: library.hasLibrary ? library.rootDisplayName : "No folders chosen"
        }
    }

    private var detail: String? {
        switch library.scanState {
        case .scanning(let progress):
            progress.filesTotal > 0
                ? "\(progress.filesProcessed.formatted(.number)) of \(progress.filesTotal.formatted(.number)) files"
                : "Reading folder…"
        case .failed(let message):
            message
        case .idle:
            library.hasLibrary ? nil : "Add one or more folders to index"
        }
    }
}

/// The icon in the menu bar. It changes with the scan so a long index or a
/// folder that has gone missing is visible without opening anything.
struct LibraryMenuBarLabel: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        switch library.scanState {
        case .scanning: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle"
        case .idle: library.hasLibrary ? "music.note.list" : "folder.badge.questionmark"
        }
    }
}
#endif
