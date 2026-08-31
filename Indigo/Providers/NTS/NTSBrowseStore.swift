//
//  NTSBrowseStore.swift
//  Indigo
//
//  Paging state for the browsable side of NTS. Every NTS list endpoint returns
//  12 items per request, so everything here is an append-as-you-go feed.
//

import Foundation
import Observation
import SwiftData

@Observable
final class NTSBrowseStore {
    /// A list that grows by one page at a time.
    nonisolated struct Feed<Item: Identifiable & Sendable>: Sendable {
        var items: [Item] = []
        var total: Int?
        var isLoading = false
        var error: String?
        var hasLoadedOnce = false

        var hasMore: Bool {
            guard let total else { return !hasLoadedOnce }
            return items.count < total
        }
    }

    enum EpisodeFeed: String, CaseIterable, Hashable {
        case recentlyAdded = "recently-added"
        case ntsPicks = "nts-picks"

        var title: String {
            switch self {
            case .recentlyAdded: "Recently Added"
            case .ntsPicks: "NTS Picks"
            }
        }
    }

    // MARK: State

    var selectedFeed: EpisodeFeed = .recentlyAdded
    private(set) var episodeFeeds: [EpisodeFeed: Feed<NTSEpisodeSummary>] = [:]
    private(set) var shows = Feed<NTSShowSummary>()
    private(set) var mixtapes = Feed<NTSMixtape>()

    /// Live search against the NTS API — not a filter over what's on screen.
    private(set) var searchResults = Feed<NTSSearchResult>()
    private(set) var activeQuery = ""
    private(set) var activeScope: NTSSearchScope = .all

    /// Episodes of one show, keyed by show alias.
    private(set) var showEpisodes: [String: Feed<NTSEpisodeSummary>] = [:]
    /// Fully loaded episode pages, keyed by "show/episode".
    private(set) var episodeDetails: [String: NTSEpisodeDetail] = [:]
    private(set) var episodeDetailErrors: [String: String] = [:]
    private(set) var loadingEpisodeDetails: Set<String> = []

    @ObservationIgnored private let api = NTSAPI()
    @ObservationIgnored private let context: ModelContext?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(context: ModelContext? = nil) {
        self.context = context
    }

    // MARK: Episode feeds

    func feed(_ feed: EpisodeFeed) -> Feed<NTSEpisodeSummary> {
        episodeFeeds[feed] ?? Feed<NTSEpisodeSummary>()
    }

    func loadFeedIfNeeded(_ feed: EpisodeFeed) async {
        guard !self.feed(feed).hasLoadedOnce else { return }
        await loadMore(feed)
    }

    func loadMore(_ feed: EpisodeFeed) async {
        var state = self.feed(feed)
        guard !state.isLoading, state.hasMore else { return }

        state.isLoading = true
        state.error = nil
        episodeFeeds[feed] = state

        do {
            let page = try await api.fetchCollection(feed.rawValue, offset: state.items.count)
            var updated = self.feed(feed)
            updated.items.append(contentsOf: dedupe(updated.items, page.results.compactMap { $0.asSummary() }))
            updated.total = page.total
            updated.isLoading = false
            updated.hasLoadedOnce = true
            episodeFeeds[feed] = updated
        } catch is CancellationError {
            var updated = self.feed(feed)
            updated.isLoading = false
            episodeFeeds[feed] = updated
        } catch {
            var updated = self.feed(feed)
            updated.isLoading = false
            updated.hasLoadedOnce = true
            updated.error = message(for: error)
            episodeFeeds[feed] = updated
        }
    }

    // MARK: Shows

    func loadShowsIfNeeded() async {
        guard !shows.hasLoadedOnce else { return }
        await loadMoreShows()
    }

    func loadMoreShows() async {
        guard !shows.isLoading, shows.hasMore else { return }
        shows.isLoading = true
        shows.error = nil

        do {
            let page = try await api.fetchShows(offset: shows.items.count)
            shows.items.append(contentsOf: dedupe(shows.items, page.results.compactMap { $0.asSummary() }))
            shows.total = page.total
            shows.hasLoadedOnce = true
        } catch is CancellationError {
        } catch {
            shows.error = message(for: error)
            shows.hasLoadedOnce = true
        }
        shows.isLoading = false
    }

    // MARK: One show's episodes

    func episodes(of showAlias: String) -> Feed<NTSEpisodeSummary> {
        showEpisodes[showAlias] ?? Feed<NTSEpisodeSummary>()
    }

    func loadEpisodesIfNeeded(of showAlias: String) async {
        guard !episodes(of: showAlias).hasLoadedOnce else { return }
        await loadMoreEpisodes(of: showAlias)
    }

    func loadMoreEpisodes(of showAlias: String) async {
        var state = episodes(of: showAlias)
        guard !state.isLoading, state.hasMore else { return }

        state.isLoading = true
        state.error = nil
        showEpisodes[showAlias] = state

        do {
            let page = try await api.fetchEpisodes(showAlias: showAlias, offset: state.items.count)
            var updated = episodes(of: showAlias)
            updated.items.append(contentsOf: dedupe(updated.items, page.results.compactMap { $0.asSummary() }))
            updated.total = page.total
            updated.isLoading = false
            updated.hasLoadedOnce = true
            showEpisodes[showAlias] = updated
        } catch is CancellationError {
            var updated = episodes(of: showAlias)
            updated.isLoading = false
            showEpisodes[showAlias] = updated
        } catch {
            var updated = episodes(of: showAlias)
            updated.isLoading = false
            updated.hasLoadedOnce = true
            updated.error = message(for: error)
            showEpisodes[showAlias] = updated
        }
    }

    /// The summary we already hold for a show, if the user arrived from a list.
    func knownShow(_ alias: String) -> NTSShowSummary? {
        shows.items.first { $0.alias == alias }
    }

    // MARK: Episode detail (the tracklist lives here)

    func detail(show: String, episode: String) -> NTSEpisodeDetail? {
        episodeDetails["\(show)/\(episode)"]
    }

    func detailError(show: String, episode: String) -> String? {
        episodeDetailErrors["\(show)/\(episode)"]
    }

    func isLoadingDetail(show: String, episode: String) -> Bool {
        loadingEpisodeDetails.contains("\(show)/\(episode)")
    }

    func loadDetailIfNeeded(show: String, episode: String) async {
        let key = "\(show)/\(episode)"
        guard episodeDetails[key] == nil, !loadingEpisodeDetails.contains(key) else { return }
        await loadDetail(show: show, episode: episode)
    }

    func loadDetail(show: String, episode: String) async {
        let key = "\(show)/\(episode)"
        loadingEpisodeDetails.insert(key)
        episodeDetailErrors[key] = nil

        do {
            let dto = try await api.fetchEpisode(showAlias: show, episodeAlias: episode)
            if let detail = dto.asDetail() {
                episodeDetails[key] = detail
                if let context {
                    RadioNeighborhoodEngine(context: context).ingest(detail)
                    try? context.save()
                }
            } else {
                episodeDetailErrors[key] = "NTS didn't return anything for this episode."
            }
        } catch is CancellationError {
        } catch {
            episodeDetailErrors[key] = message(for: error)
        }
        loadingEpisodeDetails.remove(key)
    }

    // MARK: Search

    var hasActiveSearch: Bool { !activeQuery.isEmpty }

    /// Debounced so typing doesn't fire a request per keystroke.
    func updateSearch(query: String, scope: NTSSearchScope) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != activeQuery || scope != activeScope else { return }

        searchTask?.cancel()
        activeQuery = trimmed
        activeScope = scope

        guard trimmed.count >= 2 else {
            searchResults = Feed<NTSSearchResult>()
            return
        }

        searchResults = Feed<NTSSearchResult>(isLoading: true)
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSearch(query: trimmed, scope: scope, offset: 0)
        }
    }

    func loadMoreSearchResults() async {
        guard !searchResults.isLoading, searchResults.hasMore, !activeQuery.isEmpty else { return }
        await performSearch(query: activeQuery, scope: activeScope, offset: searchResults.items.count)
    }

    func retrySearch() async {
        guard !activeQuery.isEmpty else { return }
        await performSearch(query: activeQuery, scope: activeScope, offset: 0)
    }

    /// Repairs crate entries made by older builds, which saved only the live
    /// station and show title. Search episodes without disturbing the visible
    /// search screen, then choose the broadcast nearest the moment it was kept.
    func archivedEpisode(matching title: String, near savedAt: Date) async -> NTSEpisodeRef? {
        do {
            let response = try await api.search(query: title, scope: .episode, offset: 0)
            let titleKey = LibraryKey.normalize(title)
            let candidates = response.results.enumerated().compactMap { index, dto -> NTSSearchResult? in
                dto.asResult(index: index)
            }.filter {
                $0.kind == .episode && $0.showAlias != nil && $0.episodeAlias != nil
                    && LibraryKey.normalize($0.title) == titleKey
            }
            let best = candidates.min { lhs, rhs in
                distance(lhs.date, from: savedAt) < distance(rhs.date, from: savedAt)
            }
            guard let show = best?.showAlias, let episode = best?.episodeAlias else { return nil }
            return NTSEpisodeRef(show: show, episode: episode)
        } catch {
            return nil
        }
    }

    private func performSearch(query: String, scope: NTSSearchScope, offset: Int) async {
        searchResults.isLoading = true
        searchResults.error = nil

        do {
            let response = try await api.search(query: query, scope: scope, offset: offset)
            // The user may have typed on while this was in flight.
            guard query == activeQuery, scope == activeScope else { return }

            let mapped = response.results.enumerated().compactMap { position, dto in
                dto.asResult(index: offset + position)
            }
            if offset == 0 {
                searchResults.items = mapped
            } else {
                searchResults.items.append(contentsOf: dedupe(searchResults.items, mapped))
            }
            searchResults.total = response.metadata?.resultset?.count ?? searchResults.items.count
            searchResults.hasLoadedOnce = true
        } catch is CancellationError {
        } catch {
            guard query == activeQuery, scope == activeScope else { return }
            searchResults.error = message(for: error)
            searchResults.hasLoadedOnce = true
        }
        searchResults.isLoading = false
    }

    // MARK: Mixtapes

    func loadMixtapesIfNeeded() async {
        guard !mixtapes.hasLoadedOnce else { return }
        mixtapes.isLoading = true
        mixtapes.error = nil
        do {
            let page = try await api.fetchMixtapes()
            mixtapes.items = page.results.compactMap { $0.asMixtape() }
            mixtapes.total = mixtapes.items.count
            mixtapes.hasLoadedOnce = true
        } catch is CancellationError {
        } catch {
            mixtapes.error = message(for: error)
            mixtapes.hasLoadedOnce = true
        }
        mixtapes.isLoading = false
    }

    func mixtape(alias: String) -> NTSMixtape? {
        mixtapes.items.first { $0.alias == alias }
    }

    /// A mixtape is just another live stream as far as the player is concerned.
    func mediaItem(for mixtape: NTSMixtape) -> MediaItem {
        MediaItem(
            id: "nts.mixtape.\(mixtape.alias)",
            sourceID: NTSProvider.providerID,
            kind: .radioStation,
            title: mixtape.title,
            subtitle: mixtape.subtitle,
            detail: "NTS Mixtape",
            remoteArtworkURL: mixtape.artworkURL,
            playbackURL: mixtape.streamURL
        )
    }

    // MARK: Helpers

    /// The API pages by offset over a feed that keeps changing, so the same
    /// episode can arrive twice. Identity is the alias, not the position.
    private func dedupe<Item: Identifiable>(_ existing: [Item], _ incoming: [Item]) -> [Item] {
        var known = Set(existing.map(\.id))
        return incoming.filter { known.insert($0.id).inserted }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func distance(_ value: String?, from date: Date) -> TimeInterval {
        guard let value else { return .greatestFiniteMagnitude }
        let iso = ISO8601DateFormatter()
        if let parsed = iso.date(from: value) { return abs(parsed.timeIntervalSince(date)) }
        for format in ["yyyy-MM-dd", "d MMM yyyy", "dd.MM.yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let parsed = formatter.date(from: value) { return abs(parsed.timeIntervalSince(date)) }
        }
        return .greatestFiniteMagnitude
    }
}
