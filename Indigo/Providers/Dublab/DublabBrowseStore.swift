//
//  DublabBrowseStore.swift
//  Indigo
//
//  The browsable side of dublab: the archive — twenty-seven thousand
//  broadcasts going back to 1999 — and the roster of DJs behind it.
//
//  Nothing here is held whole except the DJ roster, which is small enough to
//  search honestly. The archive is walked a page at a time, and narrowing it
//  by genre, by year or by search re-asks the station rather than filtering
//  what happens to be on screen.
//

import Foundation
import Observation

@Observable
final class DublabBrowseStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)

        var isLoading: Bool { self == .loading }
        var error: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    /// What the archive is currently being asked for. Changing any of it
    /// starts the walk again from the first page.
    nonisolated struct ArchiveQuery: Equatable, Sendable {
        var search = ""
        var genre: String?
        var year: String?

        var isSearching: Bool { search.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }
        var isFiltered: Bool { genre != nil || year != nil || isSearching }
    }

    // MARK: State

    private(set) var broadcasts: [DublabBroadcast] = []
    private(set) var archivePhase: Phase = .idle
    private(set) var archiveTotal = 0
    private(set) var isLoadingMore = false
    private(set) var query = ArchiveQuery()

    private(set) var genres: [DublabGenre] = []
    private(set) var years: [String] = []

    private(set) var djs: [DublabDJ] = []
    private(set) var djsPhase: Phase = .idle

    private(set) var djDetails: [String: DublabDJ] = [:]
    private(set) var djBroadcasts: [String: [DublabBroadcast]] = [:]
    private(set) var loadingDJs: Set<String> = []
    private(set) var djErrors: [String: String] = [:]

    private(set) var broadcastErrors: [String: String] = [:]
    private(set) var loadingBroadcasts: Set<String> = []

    @ObservationIgnored private let api = DublabAPI()
    /// Every broadcast seen anywhere, so opening one from a grid needs no
    /// round trip and a detail page always has something to show.
    @ObservationIgnored private var known: [String: DublabBroadcast] = [:]
    @ObservationIgnored private var nextPage = 1
    @ObservationIgnored private var pageCount = 1
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    // MARK: - The archive

    func loadArchiveIfNeeded() async {
        guard broadcasts.isEmpty, archivePhase != .loading else { return }
        await reloadArchive()
    }

    func reloadArchive() async {
        archivePhase = .loading
        nextPage = 1
        do {
            let page = try await fetchArchivePage(1)
            broadcasts = dedupe(page.broadcasts)
            remember(broadcasts)
            archiveTotal = page.total
            pageCount = page.pageCount
            nextPage = 2
            archivePhase = .loaded
        } catch is CancellationError {
            archivePhase = .idle
        } catch {
            archivePhase = .failed(message(for: error))
        }
    }

    var canLoadMore: Bool { nextPage <= pageCount && !isLoadingMore }

    func loadMore() async {
        guard canLoadMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await fetchArchivePage(nextPage)
            let merged = dedupe(broadcasts + page.broadcasts)
            // A page that adds nothing is the end of the archive, whatever the
            // page count claims.
            guard merged.count > broadcasts.count else {
                pageCount = nextPage - 1
                return
            }
            broadcasts = merged
            remember(page.broadcasts)
            archiveTotal = max(archiveTotal, page.total)
            pageCount = page.pageCount
            nextPage += 1
        } catch is CancellationError {
        } catch {
            // A paging failure is not worth wiping a loaded page for; stop
            // walking and let the listener retry.
            pageCount = nextPage - 1
            archivePhase = .failed(message(for: error))
        }
    }

    private func fetchArchivePage(_ page: Int) async throws -> DublabArchivePage {
        query.isSearching
            ? try await api.search(query.search, page: page)
            : try await api.fetchArchive(page: page, genre: query.genre, year: query.year)
    }

    // MARK: Narrowing

    func setGenre(_ slug: String?) {
        guard query.genre != slug else { return }
        query.genre = slug
        Task { await reloadArchive() }
    }

    func setYear(_ year: String?) {
        guard query.year != year else { return }
        query.year = year
        Task { await reloadArchive() }
    }

    func clearFilters() {
        guard query.isFiltered else { return }
        query = ArchiveQuery()
        Task { await reloadArchive() }
    }

    /// Debounced so typing doesn't fire a request per keystroke.
    func updateSearch(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query.search else { return }
        searchTask?.cancel()
        query.search = trimmed

        // Below two characters this is not a search, it is the archive again.
        guard trimmed.count >= 2 || trimmed.isEmpty else { return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.reloadArchive()
        }
    }

    func loadFiltersIfNeeded() async {
        guard genres.isEmpty else { return }
        guard let filters = try? await api.fetchArchiveFilters() else { return }
        genres = filters.genres.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        years = filters.years
    }

    // MARK: - DJs

    func loadDJsIfNeeded() async {
        guard djs.isEmpty, djsPhase != .loading else { return }
        await loadDJs()
    }

    func loadDJs() async {
        djsPhase = .loading
        do {
            djs = try await api.fetchDJs()
            djsPhase = djs.isEmpty
                ? .failed("dublab isn't publishing a roster right now.")
                : .loaded
        } catch is CancellationError {
            djsPhase = .idle
        } catch {
            djsPhase = .failed(message(for: error))
        }
    }

    func dj(slug: String) -> DublabDJ? {
        djDetails[slug] ?? djs.first { $0.slug == slug }
    }

    func isLoadingDJ(_ slug: String) -> Bool { loadingDJs.contains(slug) }
    func djError(_ slug: String) -> String? { djErrors[slug] }
    func broadcasts(byDJ slug: String) -> [DublabBroadcast] { djBroadcasts[slug] ?? [] }

    func loadDJIfNeeded(slug: String) async {
        guard djDetails[slug] == nil, !loadingDJs.contains(slug) else { return }
        loadingDJs.insert(slug)
        djErrors[slug] = nil
        defer { loadingDJs.remove(slug) }

        do {
            async let detail = api.fetchDJ(slug: slug)
            async let run = api.fetchBroadcasts(artist: slug)
            let (dj, broadcasts) = try await (detail, run)
            djDetails[slug] = dj
            let sorted = broadcasts.sorted { ($0.airedAt ?? .distantPast) > ($1.airedAt ?? .distantPast) }
            djBroadcasts[slug] = sorted
            remember(sorted)
        } catch is CancellationError {
        } catch {
            // The roster entry is still a real page — name, portrait, and
            // whatever of their run is already in hand.
            if djs.contains(where: { $0.slug == slug }) {
                djBroadcasts[slug] = known.values
                    .filter { $0.artistSlugs.contains(slug) }
                    .sorted { ($0.airedAt ?? .distantPast) > ($1.airedAt ?? .distantPast) }
            } else {
                djErrors[slug] = message(for: error)
            }
        }
    }

    // MARK: - Broadcasts

    /// Keeps every broadcast a grid has rendered, so opening one is instant.
    func remember(_ broadcasts: [DublabBroadcast]) {
        for broadcast in broadcasts { known[broadcast.slug] = broadcast }
    }

    func broadcast(slug: String) -> DublabBroadcast? { known[slug] }
    func isLoadingBroadcast(_ slug: String) -> Bool { loadingBroadcasts.contains(slug) }
    func broadcastError(_ slug: String) -> String? { broadcastErrors[slug] }

    /// Only reaches the network for a broadcast that was never on screen —
    /// a cold open out of the crate, say.
    func loadBroadcastIfNeeded(slug: String) async {
        guard known[slug] == nil, !loadingBroadcasts.contains(slug) else { return }
        loadingBroadcasts.insert(slug)
        broadcastErrors[slug] = nil
        defer { loadingBroadcasts.remove(slug) }

        do {
            remember([try await api.fetchBroadcast(slug: slug)])
        } catch is CancellationError {
        } catch {
            broadcastErrors[slug] = message(for: error)
        }
    }

    // MARK: - Helpers

    private func dedupe(_ broadcasts: [DublabBroadcast]) -> [DublabBroadcast] {
        var seen = Set<String>()
        return broadcasts.filter { seen.insert($0.slug).inserted }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
