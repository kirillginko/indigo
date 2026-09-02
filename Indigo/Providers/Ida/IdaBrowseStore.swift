//
//  IdaBrowseStore.swift
//  Indigo
//
//  The browsable side of IDA: twenty thousand archived episodes and the five
//  hundred shows they belong to.
//
//  IDA publishes no search endpoint, so searching narrows what has been loaded
//  and the page says so. Genre is different: it narrows at the station, which
//  is the only way a tag reaches past the first few pages of an archive this
//  size — so changing it starts the walk again.
//

import Foundation
import Observation

@Observable
final class IdaBrowseStore {
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

    private(set) var episodes: [IdaEpisode] = []
    private(set) var archivePhase: Phase = .idle
    private(set) var isLoadingMore = false
    private(set) var selectedGenres: Set<String> = []

    private(set) var shows: [IdaShow] = []
    private(set) var showsPhase: Phase = .idle
    private(set) var isLoadingMoreShows = false
    private(set) var selectedShowGenres: Set<String> = []

    private(set) var genres: [IdaGenre] = []

    private(set) var showEpisodes: [String: [IdaEpisode]] = [:]
    private(set) var showDetails: [String: IdaShow] = [:]
    private(set) var loadingShows: Set<String> = []
    private(set) var showErrors: [String: String] = [:]

    private(set) var details: [String: IdaEpisode] = [:]
    private(set) var loadingDetails: Set<String> = []
    private(set) var detailErrors: [String: String] = [:]

    @ObservationIgnored private let api = IdaAPI()
    @ObservationIgnored private var archiveExhausted = false
    @ObservationIgnored private var showsExhausted = false
    /// Every episode a grid has rendered, so opening one is instant.
    @ObservationIgnored private var known: [String: IdaEpisode] = [:]

    // MARK: - Archive

    func loadArchiveIfNeeded() async {
        guard episodes.isEmpty, archivePhase != .loading else { return }
        await loadArchive()
    }

    func loadArchive() async {
        archivePhase = .loading
        archiveExhausted = false
        do {
            let page = try await api.fetchEpisodes(
                limit: IdaAPI.pageSize, skip: 0, genres: selectedGenres
            )
            episodes = dedupe(page)
            remember(episodes)
            archiveExhausted = page.count < IdaAPI.pageSize
            archivePhase = .loaded
        } catch is CancellationError {
            archivePhase = .idle
        } catch {
            archivePhase = .failed(message(for: error))
        }
    }

    var canLoadMore: Bool { !archiveExhausted && !isLoadingMore && !episodes.isEmpty }

    func loadMore() async {
        guard canLoadMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.fetchEpisodes(
                limit: IdaAPI.pageSize, skip: episodes.count, genres: selectedGenres
            )
            let merged = dedupe(episodes + page)
            // A page that adds nothing is the end, whatever it claimed.
            guard merged.count > episodes.count else {
                archiveExhausted = true
                return
            }
            episodes = merged
            remember(page)
            archiveExhausted = page.count < IdaAPI.pageSize
        } catch is CancellationError {
        } catch {
            archiveExhausted = true
            archivePhase = .failed(message(for: error))
        }
    }

    /// Genre narrows the archive at the station rather than on screen — with
    /// twenty thousand episodes behind it, filtering the loaded page would be
    /// filtering a rounding error. So changing the selection starts the walk
    /// again rather than hiding rows already on screen.
    func setGenres(_ names: Set<String>) {
        guard selectedGenres != names else { return }
        selectedGenres = names
        Task { await loadArchive() }
    }

    // MARK: - Shows

    func loadShowsIfNeeded() async {
        guard shows.isEmpty, showsPhase != .loading else { return }
        await loadShows()
    }

    func loadShows() async {
        showsPhase = .loading
        showsExhausted = false
        do {
            let page = try await api.fetchShows(
                limit: IdaAPI.showPageSize, skip: 0, genres: selectedShowGenres
            )
            shows = page
            showsExhausted = page.count < IdaAPI.showPageSize
            showsPhase = .loaded
        } catch is CancellationError {
            showsPhase = .idle
        } catch {
            showsPhase = .failed(message(for: error))
        }
    }

    var canLoadMoreShows: Bool { !showsExhausted && !isLoadingMoreShows && !shows.isEmpty }

    func loadMoreShows() async {
        guard canLoadMoreShows else { return }
        isLoadingMoreShows = true
        defer { isLoadingMoreShows = false }
        do {
            let page = try await api.fetchShows(
                limit: IdaAPI.showPageSize, skip: shows.count, genres: selectedShowGenres
            )
            var seen = Set(shows.map(\.slug))
            let fresh = page.filter { seen.insert($0.slug).inserted }
            guard !fresh.isEmpty else {
                showsExhausted = true
                return
            }
            shows += fresh
            showsExhausted = page.count < IdaAPI.showPageSize
        } catch is CancellationError {
        } catch {
            showsExhausted = true
            showsPhase = .failed(message(for: error))
        }
    }

    func setShowGenres(_ names: Set<String>) {
        guard selectedShowGenres != names else { return }
        selectedShowGenres = names
        Task { await loadShows() }
    }

    func show(slug: String) -> IdaShow? {
        showDetails[slug] ?? shows.first { $0.slug == slug }
    }

    func episodes(ofShow slug: String) -> [IdaEpisode] { showEpisodes[slug] ?? [] }
    func isLoadingShow(_ slug: String) -> Bool { loadingShows.contains(slug) }
    func showError(_ slug: String) -> String? { showErrors[slug] }

    func loadShowIfNeeded(slug: String) async {
        guard showEpisodes[slug] == nil, !loadingShows.contains(slug) else { return }
        loadingShows.insert(slug)
        showErrors[slug] = nil
        defer { loadingShows.remove(slug) }

        do {
            async let detail = api.fetchShow(slug: slug)
            async let run = api.fetchEpisodes(showSlug: slug)
            let (show, episodes) = try await (detail, run)
            showDetails[slug] = show
            showEpisodes[slug] = episodes
            remember(episodes)
        } catch is CancellationError {
        } catch {
            if shows.contains(where: { $0.slug == slug }) {
                showEpisodes[slug] = []
            } else {
                showErrors[slug] = message(for: error)
            }
        }
    }

    // MARK: - Genres

    /// Asked once and kept: IDA's vocabulary runs to several hundred tags and
    /// does not change between launches.
    func loadGenresIfNeeded() async {
        guard genres.isEmpty else { return }
        guard let loaded = try? await api.fetchGenres() else { return }
        genres = loaded
    }

    // MARK: - Episodes

    func remember(_ episodes: [IdaEpisode]) {
        for episode in episodes { known[episode.slug] = episode }
    }

    func episode(slug: String) -> IdaEpisode? { details[slug] ?? known[slug] }
    func isLoadingDetail(_ slug: String) -> Bool { loadingDetails.contains(slug) }
    func detailError(_ slug: String) -> String? { detailErrors[slug] }

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
            // The listing entry is a real page already; only a cold open with
            // nothing in hand is a failure worth showing.
            if known[slug] == nil { detailErrors[slug] = message(for: error) }
        }
    }

    // MARK: - Helpers

    private func dedupe(_ episodes: [IdaEpisode]) -> [IdaEpisode] {
        var seen = Set<String>()
        return episodes.filter { seen.insert($0.slug).inserted }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
