//
//  NoodsBrowseStore.swift
//  Indigo
//
//  Paging state for everything browsable on Noods: the Discover landing page,
//  the three feeds, the genre filter, the residents index and the collections.
//

import Foundation
import Observation

@Observable
final class NoodsBrowseStore {
    /// A list that grows a page at a time.
    nonisolated struct Feed<Item: Identifiable & Sendable>: Sendable {
        var items: [Item] = []
        var page = 0
        var hasNextPage = true
        var total: Int?
        var isLoading = false
        var error: String?
        var hasLoadedOnce = false

        var hasMore: Bool { hasLoadedOnce ? hasNextPage : true }
    }

    // MARK: State

    /// Discover — the landing page's two curated lists.
    private(set) var featuredPicks: [NoodsShow] = []
    private(set) var latestPicks: [NoodsShow] = []
    private(set) var discoverPhase: Phase = .idle

    var selectedFeed: NoodsFeed = .featured
    private(set) var feeds: [NoodsFeed: Feed<NoodsShow>] = [:]

    // Filter
    private(set) var genreGroups: [NoodsGenreGroup] = []
    private(set) var genresPhase: Phase = .idle
    private(set) var selectedGenres: Set<String> = []
    private(set) var filtered = Feed<NoodsShow>()

    // Residents
    private(set) var promotedResidents: [NoodsResidentRef] = []
    private(set) var residents: [NoodsResidentRef] = []
    private(set) var residentsPhase: Phase = .idle
    private(set) var residentDetails: [String: NoodsResident] = [:]
    private(set) var residentErrors: [String: String] = [:]
    private(set) var loadingResidents: Set<String> = []

    // Collections
    private(set) var collections: [NoodsCollection] = []
    private(set) var collectionsPhase: Phase = .idle
    private(set) var collectionDetails: [String: NoodsCollection] = [:]

    // Show detail
    private(set) var showDetails: [String: NoodsShowDetail] = [:]
    private(set) var showErrors: [String: String] = [:]
    private(set) var loadingShows: Set<String> = []

    nonisolated enum Phase: Equatable, Sendable {
        case idle, loading, loaded
        case failed(String)

        var isLoading: Bool { self == .loading }
        var error: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    @ObservationIgnored private let api = NoodsAPI()

    // MARK: - Discover

    func loadDiscoverIfNeeded() async {
        guard featuredPicks.isEmpty, latestPicks.isEmpty, discoverPhase != .loading else { return }
        await loadDiscover()
    }

    func loadDiscover() async {
        discoverPhase = .loading
        do {
            let response = try await api.fetchDiscover()
            featuredPicks = (response.featured ?? []).compactMap { $0.asShow() }
            latestPicks = (response.latest ?? []).compactMap { $0.asShow() }
            discoverPhase = .loaded
        } catch is CancellationError {
            discoverPhase = .idle
        } catch {
            discoverPhase = .failed(message(for: error))
        }
    }

    // MARK: - Feeds

    func feed(_ feed: NoodsFeed) -> Feed<NoodsShow> {
        feeds[feed] ?? Feed<NoodsShow>()
    }

    func loadFeedIfNeeded(_ feed: NoodsFeed) async {
        guard !self.feed(feed).hasLoadedOnce else { return }
        await loadMore(feed)
    }

    func loadMore(_ feed: NoodsFeed) async {
        var state = self.feed(feed)
        guard !state.isLoading, state.hasMore else { return }
        state.isLoading = true
        state.error = nil
        feeds[feed] = state

        do {
            let response = try await api.fetchFeed(feed, page: state.page + 1)
            var updated = self.feed(feed)
            let incoming = (response.posts ?? []).compactMap { $0.asShow() }
            updated.items.append(contentsOf: dedupe(updated.items, incoming))
            updated.page += 1
            updated.hasNextPage = response.pagination?.hasNextPage ?? false
            updated.hasLoadedOnce = true
            updated.isLoading = false
            feeds[feed] = updated
        } catch is CancellationError {
            var updated = self.feed(feed)
            updated.isLoading = false
            feeds[feed] = updated
        } catch {
            var updated = self.feed(feed)
            updated.isLoading = false
            updated.hasLoadedOnce = true
            updated.error = message(for: error)
            feeds[feed] = updated
        }
    }

    // MARK: - Filter

    func loadGenresIfNeeded() async {
        guard genreGroups.isEmpty, genresPhase != .loading else { return }
        genresPhase = .loading
        do {
            let response = try await api.fetchGenres()
            var grouped: [String: [String]] = [:]
            var order: [String] = []
            for entry in response {
                guard let name = entry.name, !name.isEmpty else { continue }
                let parent = entry.parent?.isEmpty == false ? entry.parent! : "Other"
                if grouped[parent] == nil { order.append(parent) }
                grouped[parent, default: []].append(HTMLText.decode(name))
            }
            genreGroups = order.map { NoodsGenreGroup(name: $0, genres: grouped[$0] ?? []) }
            genresPhase = .loaded
        } catch is CancellationError {
            genresPhase = .idle
        } catch {
            genresPhase = .failed(message(for: error))
        }
    }

    func isSelected(_ genre: String) -> Bool { selectedGenres.contains(genre) }

    /// Toggling resets the feed: the server ORs the selected genres, so the
    /// result set changes wholesale rather than narrowing.
    func toggle(genre: String) {
        if selectedGenres.contains(genre) {
            selectedGenres.remove(genre)
        } else {
            selectedGenres.insert(genre)
        }
        filtered = Feed<NoodsShow>()
        Task { await loadMoreFiltered() }
    }

    func clearGenres() {
        selectedGenres.removeAll()
        filtered = Feed<NoodsShow>()
    }

    func loadMoreFiltered() async {
        guard !selectedGenres.isEmpty, !filtered.isLoading, filtered.hasMore else { return }
        filtered.isLoading = true
        filtered.error = nil
        let genres = selectedGenres.sorted()
        let page = filtered.page + 1

        do {
            let response = try await api.filter(genres: genres, page: page)
            // The selection may have changed while this was in flight.
            guard genres == selectedGenres.sorted() else { return }
            let incoming = (response.shows ?? []).compactMap { $0.asShow() }
            filtered.items.append(contentsOf: dedupe(filtered.items, incoming))
            filtered.page = response.page ?? page
            filtered.total = response.totalShows
            filtered.hasNextPage = (response.pages ?? 1) > filtered.page
            filtered.hasLoadedOnce = true
        } catch is CancellationError {
        } catch {
            filtered.error = message(for: error)
            filtered.hasLoadedOnce = true
        }
        filtered.isLoading = false
    }

    // MARK: - Residents

    func loadResidentsIfNeeded() async {
        guard residents.isEmpty, residentsPhase != .loading else { return }
        residentsPhase = .loading
        do {
            let response = try await api.fetchResidents()
            promotedResidents = (response.promotedResidents ?? []).compactMap { $0.asRef() }
            // `children` is the A–Z grouping and `unsorted` the flat list;
            // the grouping carries the needle letters, so it wins where present.
            let grouped = (response.children ?? []).flatMap { $0 }.compactMap { $0.asRef() }
            let flat = (response.unsorted ?? []).compactMap { $0.asRef() }
            residents = dedupe([], grouped.isEmpty ? flat : grouped)
            residentsPhase = .loaded
        } catch is CancellationError {
            residentsPhase = .idle
        } catch {
            residentsPhase = .failed(message(for: error))
        }
    }

    func resident(path: String) -> NoodsResident? { residentDetails[path] }
    func residentError(path: String) -> String? { residentErrors[path] }
    func isLoadingResident(_ path: String) -> Bool { loadingResidents.contains(path) }

    func loadResidentIfNeeded(path: String) async {
        guard residentDetails[path] == nil, !loadingResidents.contains(path) else { return }
        await loadResident(path: path)
    }

    func loadResident(path: String) async {
        loadingResidents.insert(path)
        residentErrors[path] = nil
        do {
            let dto = try await api.fetchResident(slug: NoodsPath.slug(path), page: 1)
            residentDetails[path] = dto.asResident(path: path)
        } catch is CancellationError {
        } catch {
            residentErrors[path] = message(for: error)
        }
        loadingResidents.remove(path)
    }

    /// Residents page their back catalogue, so a long-running show doesn't
    /// arrive all at once.
    func loadMoreResidentShows(path: String) async {
        guard let current = residentDetails[path], current.nextPage != nil,
              !loadingResidents.contains(path) else { return }
        loadingResidents.insert(path)
        let page = (current.shows.count / NoodsAPI.feedPageSize) + 1

        do {
            let dto = try await api.fetchResident(slug: NoodsPath.slug(path), page: page + 1)
            let more = dto.asResident(path: path)
            residentDetails[path] = NoodsResident(
                path: current.path,
                name: current.name,
                schedule: current.schedule,
                location: current.location,
                about: current.about,
                artworkURL: current.artworkURL,
                shows: current.shows + dedupe(current.shows, more.shows),
                nextPage: more.nextPage,
                similar: current.similar.isEmpty ? more.similar : current.similar
            )
        } catch is CancellationError {
        } catch {
            residentErrors[path] = message(for: error)
        }
        loadingResidents.remove(path)
    }

    // MARK: - Collections

    func loadCollectionsIfNeeded() async {
        guard collections.isEmpty, collectionsPhase != .loading else { return }
        collectionsPhase = .loading
        do {
            let response = try await api.fetchCollections()
            collections = (response.collections ?? [:])
                .compactMap { $0.value.asCollection(path: $0.key) }
                .sorted { ($0.airedAt ?? .distantPast) > ($1.airedAt ?? .distantPast) }
            collectionsPhase = .loaded
        } catch is CancellationError {
            collectionsPhase = .idle
        } catch {
            collectionsPhase = .failed(message(for: error))
        }
    }

    func collection(path: String) -> NoodsCollection? {
        collectionDetails[path] ?? collections.first { $0.path == path }
    }

    /// The index carries no show list, so a collection is fetched when opened.
    func loadCollectionIfNeeded(path: String) async {
        guard collectionDetails[path] == nil else { return }
        do {
            let dto = try await api.fetchCollection(slug: NoodsPath.slug(path))
            if let detail = dto.asCollection(path: path) { collectionDetails[path] = detail }
        } catch is CancellationError {
        } catch {
            // The index entry still renders; only the show list is missing.
        }
    }

    // MARK: - Show detail

    func showDetail(path: String) -> NoodsShowDetail? { showDetails[path] }
    func showError(path: String) -> String? { showErrors[path] }
    func isLoadingShow(_ path: String) -> Bool { loadingShows.contains(path) }

    func loadShowIfNeeded(path: String) async {
        guard showDetails[path] == nil, !loadingShows.contains(path) else { return }
        loadingShows.insert(path)
        showErrors[path] = nil
        do {
            let dto = try await api.fetchShow(slug: NoodsPath.slug(path))
            if let detail = dto.asDetail(path: path) {
                showDetails[path] = detail
            } else {
                showErrors[path] = "Noods didn't return anything for this show."
            }
        } catch is CancellationError {
        } catch {
            showErrors[path] = message(for: error)
        }
        loadingShows.remove(path)
    }

    // MARK: - Helpers

    private func dedupe<Item: Identifiable>(_ existing: [Item], _ incoming: [Item]) -> [Item] {
        var known = Set(existing.map(\.id))
        return incoming.filter { known.insert($0.id).inserted }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
