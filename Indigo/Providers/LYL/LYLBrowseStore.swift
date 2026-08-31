//
//  LYLBrowseStore.swift
//  Indigo
//
//  The browsable side of LYL: the archive of episodes and the shows they
//  belong to. LYL publishes no search endpoint, so searching narrows what has
//  been loaded and the page says so; the shows directory, which does filter
//  server-side by style and studio, re-asks the station instead.
//

import Foundation
import Observation

@Observable
final class LYLBrowseStore {
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

    private(set) var episodes: [LYLEpisode] = []
    private(set) var archivePhase: Phase = .idle
    private(set) var isLoadingMore = false

    private(set) var shows: [LYLShow] = []
    private(set) var showsPhase: Phase = .idle
    private(set) var isLoadingMoreShows = false
    private(set) var studios: [LYLStudio] = []
    private(set) var styles: [LYLStyle] = []
    private(set) var selectedStyle: String?
    private(set) var selectedStudio: String?

    private(set) var showEpisodes: [String: [LYLEpisode]] = [:]
    private(set) var showDetails: [String: LYLShow] = [:]
    private(set) var loadingShows: Set<String> = []
    private(set) var showErrors: [String: String] = [:]

    private(set) var details: [String: LYLEpisode] = [:]
    private(set) var loadingDetails: Set<String> = []
    private(set) var detailErrors: [String: String] = [:]

    @ObservationIgnored private let api = LYLAPI()
    @ObservationIgnored private var archiveExhausted = false
    @ObservationIgnored private var showsExhausted = false
    /// Every episode a grid has rendered, so opening one is instant.
    @ObservationIgnored private var known: [String: LYLEpisode] = [:]

    private static let showPageSize = 60

    // MARK: - Archive

    func loadArchiveIfNeeded() async {
        guard episodes.isEmpty, archivePhase != .loading else { return }
        await loadArchive()
    }

    func loadArchive() async {
        archivePhase = .loading
        archiveExhausted = false
        do {
            let page = try await api.fetchEpisodes(limit: LYLAPI.pageSize, skip: 0)
            episodes = dedupe(page)
            remember(episodes)
            archiveExhausted = page.count < LYLAPI.pageSize
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
            let page = try await api.fetchEpisodes(limit: LYLAPI.pageSize, skip: episodes.count)
            let merged = dedupe(episodes + page)
            // A page that adds nothing is the end, whatever it claimed.
            guard merged.count > episodes.count else {
                archiveExhausted = true
                return
            }
            episodes = merged
            remember(page)
            archiveExhausted = page.count < LYLAPI.pageSize
        } catch is CancellationError {
        } catch {
            archiveExhausted = true
            archivePhase = .failed(message(for: error))
        }
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
            let index = try await api.fetchShows(
                limit: Self.showPageSize,
                skip: 0,
                styles: selectedStyle.map { [$0] } ?? [],
                studios: selectedStudio.map { [$0] } ?? []
            )
            shows = index.shows
            // These two come back with every page; keep the first answer.
            if studios.isEmpty { studios = index.studios }
            if styles.isEmpty { styles = index.styles }
            showsExhausted = index.shows.count < Self.showPageSize
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
            let index = try await api.fetchShows(
                limit: Self.showPageSize,
                skip: shows.count,
                styles: selectedStyle.map { [$0] } ?? [],
                studios: selectedStudio.map { [$0] } ?? []
            )
            var seen = Set(shows.map(\.slug))
            let fresh = index.shows.filter { seen.insert($0.slug).inserted }
            guard !fresh.isEmpty else {
                showsExhausted = true
                return
            }
            shows += fresh
            showsExhausted = index.shows.count < Self.showPageSize
        } catch is CancellationError {
        } catch {
            showsExhausted = true
            showsPhase = .failed(message(for: error))
        }
    }

    /// Style and studio narrow the directory at the station rather than on
    /// screen, so changing either starts the walk again.
    func setStyle(_ name: String?) {
        guard selectedStyle != name else { return }
        selectedStyle = name
        Task { await loadShows() }
    }

    func setStudio(_ name: String?) {
        guard selectedStudio != name else { return }
        selectedStudio = name
        Task { await loadShows() }
    }

    func clearShowFilters() {
        guard selectedStyle != nil || selectedStudio != nil else { return }
        selectedStyle = nil
        selectedStudio = nil
        Task { await loadShows() }
    }

    func show(slug: String) -> LYLShow? {
        showDetails[slug] ?? shows.first { $0.slug == slug }
    }

    func episodes(ofShow slug: String) -> [LYLEpisode] { showEpisodes[slug] ?? [] }
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

    // MARK: - Episodes

    func remember(_ episodes: [LYLEpisode]) {
        for episode in episodes { known[episode.slug] = episode }
    }

    func episode(slug: String) -> LYLEpisode? { details[slug] ?? known[slug] }
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

    private func dedupe(_ episodes: [LYLEpisode]) -> [LYLEpisode] {
        var seen = Set<String>()
        return episodes.filter { seen.insert($0.slug).inserted }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
