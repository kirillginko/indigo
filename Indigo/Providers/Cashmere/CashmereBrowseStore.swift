//
//  CashmereBrowseStore.swift
//  Indigo
//
//  The browsable side of Cashmere: the archive of episodes and the shows they
//  belong to. Searching and narrowing re-ask the station rather than filtering
//  the page, so the whole archive is reachable.
//

import Foundation
import Observation

@Observable
final class CashmereBrowseStore {
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

    // MARK: State

    private(set) var episodes: [CashmereEpisode] = []
    private(set) var archivePhase: Phase = .idle
    private(set) var isLoadingMore = false
    private(set) var search = ""

    private(set) var shows: [CashmereShow] = []
    private(set) var showsPhase: Phase = .idle

    private(set) var showEpisodes: [String: [CashmereEpisode]] = [:]
    private(set) var loadingShows: Set<String> = []
    private(set) var showErrors: [String: String] = [:]

    private(set) var details: [String: CashmereEpisode] = [:]
    private(set) var loadingDetails: Set<String> = []
    private(set) var detailErrors: [String: String] = [:]

    @ObservationIgnored private let api = CashmereAPI()
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var hasMore = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// Every episode a grid has rendered, so opening one is instant.
    @ObservationIgnored private var known: [String: CashmereEpisode] = [:]

    deinit {
        searchTask?.cancel()
    }

    /// One character is a typo, not a search. Kept static so the rule can be
    /// checked without standing up a store and the debounce behind it.
    static func isSearchTerm(_ term: String) -> Bool {
        term.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    var isSearching: Bool { Self.isSearchTerm(search) }

    // MARK: - Archive

    func loadArchiveIfNeeded() async {
        guard episodes.isEmpty, archivePhase != .loading else { return }
        await reloadArchive()
    }

    func reloadArchive() async {
        archivePhase = .loading
        do {
            let page = try await api.fetchEpisodes(search: isSearching ? search : nil)
            episodes = dedupe(page.episodes)
            remember(episodes)
            cursor = page.cursor
            hasMore = page.hasMore
            archivePhase = .loaded
        } catch is CancellationError {
            archivePhase = .idle
        } catch {
            archivePhase = .failed(message(for: error))
        }
    }

    var canLoadMore: Bool { hasMore && cursor != nil && !isLoadingMore }

    func loadMore() async {
        guard canLoadMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.fetchEpisodes(
                after: cursor,
                search: isSearching ? search : nil
            )
            let merged = dedupe(episodes + page.episodes)
            // A page that adds nothing is the end, whatever the cursor claims.
            guard merged.count > episodes.count else {
                hasMore = false
                return
            }
            episodes = merged
            remember(page.episodes)
            cursor = page.cursor
            hasMore = page.hasMore
        } catch is CancellationError {
        } catch {
            hasMore = false
            archivePhase = .failed(message(for: error))
        }
    }

    /// Debounced so typing doesn't fire a request per keystroke.
    func updateSearch(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != search else { return }
        searchTask?.cancel()
        search = trimmed

        // Below two characters this is not a search, it is the archive again.
        guard Self.isSearchTerm(trimmed) || trimmed.isEmpty else { return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.reloadArchive()
        }
    }

    // MARK: - Shows

    func loadShowsIfNeeded() async {
        guard shows.isEmpty, showsPhase != .loading else { return }
        await loadShows()
    }

    func loadShows() async {
        showsPhase = .loading
        do {
            var collected: [CashmereShow] = []
            var after: String?
            // Cashmere runs about a hundred shows; walking them whole is what
            // makes searching them honest.
            for _ in 0..<8 {
                let page = try await api.fetchShows(after: after)
                collected += page.shows
                after = page.cursor
                if !page.hasMore || page.shows.isEmpty { break }
            }
            shows = collected.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            showsPhase = shows.isEmpty
                ? .failed("Cashmere isn't publishing any shows right now.")
                : .loaded
        } catch is CancellationError {
            showsPhase = .idle
        } catch {
            showsPhase = .failed(message(for: error))
        }
    }

    func show(slug: String) -> CashmereShow? { shows.first { $0.slug == slug } }
    func episodes(ofShow slug: String) -> [CashmereEpisode] { showEpisodes[slug] ?? [] }
    func isLoadingShow(_ slug: String) -> Bool { loadingShows.contains(slug) }
    func showError(_ slug: String) -> String? { showErrors[slug] }

    func loadShowIfNeeded(slug: String) async {
        guard showEpisodes[slug] == nil, !loadingShows.contains(slug) else { return }
        loadingShows.insert(slug)
        showErrors[slug] = nil
        defer { loadingShows.remove(slug) }

        do {
            let page = try await api.fetchEpisodes(first: 100, showSlug: slug)
            let sorted = page.episodes.sorted {
                ($0.airedAt ?? .distantPast) > ($1.airedAt ?? .distantPast)
            }
            showEpisodes[slug] = sorted
            remember(sorted)
        } catch is CancellationError {
        } catch {
            showErrors[slug] = message(for: error)
        }
    }

    // MARK: - Episodes

    func remember(_ episodes: [CashmereEpisode]) {
        for episode in episodes {
            // A listing entry must never overwrite one that has its prose.
            if let existing = known[episode.slug], existing.summary != nil, episode.summary == nil {
                continue
            }
            known[episode.slug] = episode
        }
    }

    func episode(slug: String) -> CashmereEpisode? { details[slug] ?? known[slug] }
    func isLoadingDetail(_ slug: String) -> Bool { loadingDetails.contains(slug) }
    func detailError(_ slug: String) -> String? { detailErrors[slug] }

    /// The listing leaves out the prose, so a detail page asks again even when
    /// it already has the tile's version.
    func loadDetailIfNeeded(slug: String) async {
        guard details[slug] == nil, !loadingDetails.contains(slug) else { return }
        loadingDetails.insert(slug)
        detailErrors[slug] = nil
        defer { loadingDetails.remove(slug) }

        do {
            let episode = try await api.fetchEpisode(slug: slug)
            details[slug] = episode
            remember([episode])
        } catch is CancellationError {
        } catch {
            // The listing entry is still a real page: title, artwork, date and
            // something to play.
            if known[slug] == nil { detailErrors[slug] = message(for: error) }
        }
    }

    // MARK: - Helpers

    private func dedupe(_ episodes: [CashmereEpisode]) -> [CashmereEpisode] {
        var seen = Set<String>()
        return episodes.filter { seen.insert($0.slug).inserted }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
