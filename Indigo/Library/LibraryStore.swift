//
//  LibraryStore.swift
//  Indigo
//
//  Owns the chosen music folder (persisted as a security-scoped bookmark) and
//  drives background scans. Views read the indexed result through @Query; this
//  object only deals with access, progress, and errors.
//

import Foundation
import SwiftData
import SwiftUI

#if os(macOS)
import AppKit
#endif

@Observable
final class LibraryStore {
    enum ScanState: Equatable {
        case idle
        case scanning(ScanProgress)
        case failed(String)

        var isScanning: Bool { if case .scanning = self { true } else { false } }
    }

    private enum Keys {
        static let bookmark = "library.rootBookmark"
        static let displayPath = "library.rootDisplayPath"
        static let generation = "library.scanGeneration"
    }

    private(set) var rootURL: URL?
    private(set) var scanState: ScanState = .idle
    private(set) var lastSummary: ScanSummary?
    /// Non-fatal message shown as a dismissible strip.
    var notice: String?
    /// Drives `.fileImporter` on platforms without NSOpenPanel.
    var isPresentingImporter = false

    private let container: ModelContainer
    private let defaults: UserDefaults
    private var securityScopedURL: URL?
    private var scanTask: Task<Void, Never>?

    /// `defaults` is injectable so tests never touch the user's real settings.
    init(container: ModelContainer, defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
    }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    var hasLibrary: Bool { rootURL != nil }

    var rootDisplayName: String {
        rootURL?.lastPathComponent ?? defaults.string(forKey: Keys.displayPath) ?? "No folder"
    }

    // MARK: - Restoring

    /// Reopens the previously chosen folder. Called once at launch.
    func restore() {
        guard let data = defaults.data(forKey: Keys.bookmark) else {
            // Tracks may still be indexed from a previous run, but without a
            // bookmark none of them can be opened. Say so rather than letting
            // every click fail.
            if defaults.string(forKey: Keys.displayPath) != nil {
                notice = "Indigo needs permission to read your music folder again. Choose it to start playing."
            }
            return
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: Self.resolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            // A bookmark-resolved URL carries no access of its own, so here a
            // failed claim really does mean permission is gone.
            guard claimScope(url, requiresScope: true) else {
                notice = LibraryError.accessDenied.errorDescription
                return
            }
            rootURL = url
            if isStale { persistBookmark(for: url) }
            scan()
        } catch {
            notice = "Couldn't reopen the last music folder. Choose it again."
        }
    }

    // MARK: - Choosing

    func chooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder Indigo should index."
        panel.directoryURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adopt(url)
        #else
        isPresentingImporter = true
        #endif
    }

    func handleImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            adopt(url)
        case .failure:
            notice = "Couldn't open that folder."
        }
    }

    /// Entry point for every folder source: the open panel, the file importer,
    /// and tests.
    ///
    /// A URL the user just picked already carries access, granted by the system
    /// when it showed the panel. `startAccessingSecurityScopedResource()`
    /// returns false for such a URL — that is normal, not a denial, so a fresh
    /// pick must never be rejected on it.
    func adopt(_ url: URL) {
        _ = claimScope(url, requiresScope: false)
        rootURL = url
        defaults.set(url.path, forKey: Keys.displayPath)
        persistBookmark(for: url)
        scan()
    }

    // MARK: - Scanning

    func scan() {
        guard let root = rootURL else { return }
        guard FileManager.default.fileExists(atPath: root.path) else {
            scanState = .failed(LibraryError.folderMissing.errorDescription ?? "Folder missing")
            return
        }

        scanTask?.cancel()
        let generation = nextGeneration()
        scanState = .scanning(ScanProgress())

        let indexer = LibraryIndexer(modelContainer: container)

        // Progress crosses back over an AsyncStream rather than a captured
        // closure, so the indexer never holds a reference to this object.
        let (progressStream, progressFeed) = AsyncStream<ScanProgress>.makeStream()
        let progressTask = Task { @MainActor [weak self] in
            for await progress in progressStream {
                guard let self, self.scanState.isScanning else { continue }
                self.scanState = .scanning(progress)
            }
        }

        scanTask = Task { [weak self] in
            defer {
                progressFeed.finish()
                progressTask.cancel()
            }
            do {
                let summary = try await indexer.scan(
                    root: root,
                    generation: generation,
                    onProgress: { progressFeed.yield($0) }
                )
                guard !Task.isCancelled else { return }
                self?.finishScan(with: summary)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.scanState = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanState = .idle
    }

    private func finishScan(with summary: ScanSummary) {
        lastSummary = summary
        scanState = .idle
        if summary.unreadable > 0 {
            notice = "\(summary.unreadable) file\(summary.unreadable == 1 ? "" : "s") couldn't be read and \(summary.unreadable == 1 ? "was" : "were") indexed by filename."
        }
    }

    private func nextGeneration() -> Int {
        let next = defaults.integer(forKey: Keys.generation) + 1
        defaults.set(next, forKey: Keys.generation)
        return next
    }

    // MARK: - Security-scoped access

    private static var creationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    private static var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    /// Starts a security scope if the URL has one to give. Returns false only
    /// when `requiresScope` is set and no scope could be started.
    private func claimScope(_ url: URL, requiresScope: Bool) -> Bool {
        if securityScopedURL == url { return true }

        let started = url.startAccessingSecurityScopedResource()
        if requiresScope && !started { return false }

        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = started ? url : nil
        return true
    }

    private func persistBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: Self.creationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: Keys.bookmark)
        } catch {
            // Surface the real reason — a silent failure here means the folder
            // has to be picked again after every launch.
            notice = """
                Indigo can index this folder now, but won't be able to reopen it \
                automatically: \(error.localizedDescription)
                """
        }
    }
}
