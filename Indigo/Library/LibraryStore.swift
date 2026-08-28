import Foundation
import SwiftData
import SwiftUI

#if os(macOS)
import AppKit
#endif

@Observable
final class LibraryStore {
    enum ScanState: Equatable {
        case idle, scanning(ScanProgress), failed(String)
        var isScanning: Bool { if case .scanning = self { true } else { false } }
    }

    private enum Keys {
        static let bookmark = "library.rootBookmark"
        static let displayPath = "library.rootDisplayPath"
        static let bookmarks = "library.rootBookmarks"
        static let displayPaths = "library.rootDisplayPaths"
        static let generation = "library.scanGeneration"
    }

    private(set) var rootURLs: [URL] = []
    private(set) var scanState: ScanState = .idle
    private(set) var lastSummary: ScanSummary?
    var notice: String?
    var isPresentingImporter = false

    private let container: ModelContainer
    private let defaults: UserDefaults
    private var securityScopedURLs: [URL] = []
    private var scanTask: Task<Void, Never>?

    init(container: ModelContainer, defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
    }

    deinit { for url in securityScopedURLs { url.stopAccessingSecurityScopedResource() } }

    var rootURL: URL? { rootURLs.first }
    var hasLibrary: Bool { !rootURLs.isEmpty }
    var rootDisplayName: String {
        switch rootURLs.count {
        case 0: "No folders"
        case 1: rootURLs[0].lastPathComponent
        default: "\(rootURLs.count) folders"
        }
    }

    func restore() {
        let saved = defaults.array(forKey: Keys.bookmarks) as? [Data]
            ?? defaults.data(forKey: Keys.bookmark).map { [$0] }
            ?? []
        guard !saved.isEmpty else {
            if defaults.string(forKey: Keys.displayPath) != nil
                || defaults.stringArray(forKey: Keys.displayPaths) != nil {
                notice = "Indigo needs permission to read your music folders again. Add them to continue."
            }
            return
        }

        var restored: [URL] = []
        var shouldRepersist = defaults.array(forKey: Keys.bookmarks) == nil
        for data in saved {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: Self.resolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), claimScope(url, requiresScope: true) else { continue }
            if !restored.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                restored.append(url)
            }
            shouldRepersist = shouldRepersist || stale
        }
        guard !restored.isEmpty else {
            notice = "Couldn't reopen the music folders. Add them again to restore access."
            return
        }
        rootURLs = restored.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        if shouldRepersist { persistBookmarks() }
        scan()
    }

    func chooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add Folders"
        panel.message = "Choose one or more folders to add to Indigo."
        panel.directoryURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        adopt(panel.urls)
        #else
        isPresentingImporter = true
        #endif
    }

    func handleImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): adopt(urls)
        case .failure: notice = "Couldn't open those folders."
        }
    }

    func adopt(_ url: URL) { adopt([url]) }

    func adopt(_ urls: [URL]) {
        for url in urls {
            _ = claimScope(url, requiresScope: false)
            if !rootURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                rootURLs.append(url)
            }
        }
        rootURLs.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        persistBookmarks()
        scan()
    }

    func removeFolder(_ url: URL) {
        rootURLs.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        if let index = securityScopedURLs.firstIndex(where: {
            $0.standardizedFileURL == url.standardizedFileURL
        }) {
            securityScopedURLs[index].stopAccessingSecurityScopedResource()
            securityScopedURLs.remove(at: index)
        }
        persistBookmarks()
        scan()
    }

    func scan() {
        scanTask?.cancel()
        let roots = rootURLs
        let generation = nextGeneration()
        scanState = .scanning(ScanProgress())
        let indexer = LibraryIndexer(modelContainer: container)
        let (stream, feed) = AsyncStream<ScanProgress>.makeStream()
        let progressTask = Task { @MainActor [weak self] in
            for await progress in stream {
                guard let self, self.scanState.isScanning else { continue }
                self.scanState = .scanning(progress)
            }
        }

        scanTask = Task { [weak self] in
            defer { feed.finish(); progressTask.cancel() }
            do {
                let summary = try await indexer.scan(
                    roots: roots,
                    generation: generation,
                    onProgress: { feed.yield($0) }
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

    private func claimScope(_ url: URL, requiresScope: Bool) -> Bool {
        if securityScopedURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            return true
        }
        let started = url.startAccessingSecurityScopedResource()
        if requiresScope && !started { return false }
        if started { securityScopedURLs.append(url) }
        return true
    }

    private func persistBookmarks() {
        var bookmarks: [Data] = []
        for url in rootURLs {
            do {
                bookmarks.append(try url.bookmarkData(
                    options: Self.creationOptions,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ))
            } catch {
                notice = "Indigo can index \(url.lastPathComponent) now, but may need permission again later."
            }
        }
        defaults.set(bookmarks, forKey: Keys.bookmarks)
        defaults.set(rootURLs.map(\.path), forKey: Keys.displayPaths)
        defaults.removeObject(forKey: Keys.bookmark)
        defaults.removeObject(forKey: Keys.displayPath)
    }
}
